# Generates everything one infra-agent environment needs from its declaration:
#
#   broker  the directory mounted read-only at /etc/infra-broker in the broker
#           VM (gateway, MCP server, kubeconfig and DBHub configuration)
#   credd   infra-credd's configuration (how to mint each credential on the host)
#   cli     the host-side settings infra-agent reads (network rules, secrets,
#           preflight checks)
#
# Every network destination the broker may reach is derived from the declared
# accounts, clusters, databases and services, so the rules cannot drift from
# what the tools use.
{ pkgs, lib, name, env, port, dnsPort, brokerPrefix }:
let
  json = pkgs.formats.json { };
  toml = pkgs.formats.toml { };
  inherit (lib) mapAttrs mapAttrsToList attrNames attrValues concatMap optional optionals optionalAttrs unique;

  creddUrl = "http://127.0.0.1:9100";
  etc = "/etc/infra-broker";

  isIp = host: builtins.match "[0-9.]+|.*:.*" host != null;
  bracket = target: if lib.hasInfix ":" target then "[${target}]" else target;
  allow = target: targetPort: "allow@${bracket target}:tcp:${toString targetPort}";

  # A private target is reached by address (CIDR rules). Its hostname is also
  # allowed so the broker may resolve it; microsandbox rejects private DNS
  # answers outside the allowed CIDRs.
  privateRules = target:
    map (cidr: allow cidr target.port) target.cidrs
    ++ optional (!isIp target.host) (allow target.host target.port);

  # ---- AWS -------------------------------------------------------------------
  aws = env.aws;
  awsAccounts = if aws == null then { } else aws.accounts;
  awsDefaultAccount =
    if aws == null then null
    else if aws.defaultAccount != null then aws.defaultAccount
    else lib.head (lib.sort lib.lessThan (attrNames awsAccounts));
  awsDefaultRegion = if aws == null then null else lib.head awsAccounts.${awsDefaultAccount}.regions;
  # botocore endpoint prefixes that differ from the service name, and global endpoints.
  awsPrefixes = {
    cloudwatch = "monitoring"; elbv2 = "elasticloadbalancing"; elb = "elasticloadbalancing";
    ecr = "api.ecr"; stepfunctions = "states"; opensearch = "es";
    resourcegroupstaggingapi = "tagging"; "application-autoscaling" = "application-autoscaling";
  };
  awsGlobal = {
    iam = "iam.amazonaws.com"; route53 = "route53.amazonaws.com"; cloudfront = "cloudfront.amazonaws.com";
    health = "health.us-east-1.amazonaws.com"; organizations = "organizations.us-east-1.amazonaws.com";
  };
  awsServices = if aws == null then [ ] else unique (aws.services ++ [ "sts" ]);
  awsHosts = optionals (aws != null) (unique (
    concatMap (account: concatMap (region: map (service:
      awsGlobal.${service} or "${awsPrefixes.${service} or service}.${region}.amazonaws.com") awsServices)
      account.regions) (attrValues awsAccounts)
    ++ aws.extraHosts));

  # ---- Azure -----------------------------------------------------------------
  azure = env.azure;
  azureHosts = optionals (azure != null) ([ "management.azure.com" "api.loganalytics.io" ] ++ azure.extraHosts);
  entraDatabases = lib.filterAttrs (_: db: db.auth == "entra") env.databases;
  azureResources = optionals (azure != null) (unique (azure.tokenResources
    ++ optional (entraDatabases != { }) "https://database.windows.net/"));

  # ---- Kubernetes --------------------------------------------------------------
  clusters = mapAttrs (clusterName: cluster:
    let
      parsed = builtins.match "https://([^/:]+)(:([0-9]+))?(/.*)?" cluster.server;
      host = if parsed == null then throw "dotfiles.infraAgent.environments.${name}.kubernetes.${clusterName}.server must be https://HOST[:PORT][/PATH]" else lib.head parsed;
    in cluster // {
      inherit host;
      port = if lib.elemAt parsed 2 == null then 443 else lib.toInt (lib.elemAt parsed 2);
      account = if cluster.account != null then cluster.account else awsDefaultAccount;
      region =
        if cluster.region != null then cluster.region
        else if cluster.provider == "eks" && awsDefaultAccount != null then lib.head awsAccounts.${awsDefaultAccount}.regions
        else null;
    }) env.kubernetes;
  clusterNames = lib.sort lib.lessThan (attrNames clusters);

  kubeconfig = json.generate "kubeconfig-${name}.json" {
    apiVersion = "v1";
    kind = "Config";
    current-context = if clusterNames == [ ] then "" else lib.head clusterNames;
    clusters = mapAttrsToList (clusterName: c: {
      name = clusterName;
      cluster = { server = c.server; certificate-authority-data = c.certificateAuthorityData; }
        // optionalAttrs (c.tlsServerName != null) { tls-server-name = c.tlsServerName; };
    }) clusters;
    users = mapAttrsToList (clusterName: _: {
      name = clusterName;
      user.exec = {
        apiVersion = "client.authentication.k8s.io/v1beta1";
        command = "infra-broker-credential";
        args = [ "k8s" clusterName ];
        interactiveMode = "Never";
      };
    }) clusters;
    contexts = mapAttrsToList (clusterName: c: {
      name = clusterName;
      context = { cluster = clusterName; user = clusterName; } // optionalAttrs (c.namespace != null) { inherit (c) namespace; };
    }) clusters;
  };

  kubernetesServerConfig = toml.generate "kubernetes-mcp-server-${name}.toml" {
    read_only = true;
    disable_destructive = true;
    toolsets = [ "core" ];
    kubeconfig = "${etc}/kubeconfig.json";
    # configuration_view returns the kubeconfig, including credentials.
    disabled_tools = [ "configuration_view" ];
    denied_resources = env.kubernetesDeniedResources;
  };

  # ---- databases (DBHub) -------------------------------------------------------
  databases = mapAttrs (_: db: db // {
    account = if db.account != null then db.account else awsDefaultAccount;
    region = if db.region != null then db.region else awsDefaultRegion;
  }) env.databases;
  passwordVariable = source: "INFRA_DB_${lib.toUpper source}_PASSWORD";
  passwordSources = attrNames (lib.filterAttrs (_: db: db.auth == "password") databases);

  dbhubConfig = toml.generate "dbhub-${name}.toml" {
    sources = mapAttrsToList (source: db:
      {
        id = source;
        type = db.engine;
        inherit (db) host port database user;
        lazy = true;
        connection_timeout = 30;
        query_timeout = db.queryTimeout;
      }
      // optionalAttrs (db.auth == "password") { password = "\${${passwordVariable source}}"; }
      // optionalAttrs (db.auth == "rds-iam") { aws_iam_auth = true; aws_region = db.region; aws_profile = db.account; }
      // optionalAttrs (db.auth == "entra") { authentication = "azure-active-directory-access-token"; }
      // optionalAttrs (db.engine == "postgres" && db.sslmode != null) { inherit (db) sslmode; }
      // db.extraSettings) databases;
    tools = concatMap (source: [
      { name = "execute_sql"; inherit source; readonly = true; max_rows = databases.${source}.maxRows; }
      { name = "search_objects"; inherit source; }
    ]) (attrNames databases);
  };

  # AWS profiles for tools that need an explicit account (DBHub's aws_profile).
  awsConfig = pkgs.writeText "aws-config-${name}" (lib.concatStrings (mapAttrsToList (account: settings: ''
    [profile ${account}]
    credential_process = infra-broker-credential aws-process ${account}
    region = ${lib.head settings.regions}

  '') awsAccounts));

  awsServerConfig = json.generate "aws-${name}.json" ({
    accounts = mapAttrs (_: a: { inherit (a) regions description; }) awsAccounts;
    defaultAccount = awsDefaultAccount;
    services = awsServices;
    maxResultBytes = env.maxResponseBytes;
  } // optionalAttrs (aws != null && aws.denyOperations != null) { inherit (aws) denyOperations; });

  # ---- Datadog -----------------------------------------------------------------
  datadog = env.datadog;
  datadogHost = "mcp.${datadog.site}";
  datadogSecrets = optionals (datadog != null) [
    { name = "INFRA_DD_API_KEY"; command = datadog.apiKeyCommand; hosts = [ datadogHost ]; }
    { name = "INFRA_DD_APP_KEY"; command = datadog.appKeyCommand; hosts = [ datadogHost ]; }
  ];

  # ---- gateway -----------------------------------------------------------------
  servers =
    optionalAttrs (clusters != { }) {
      k8s = {
        command = "kubernetes-mcp-server";
        args = [ "--config" "${etc}/kubernetes-mcp-server.toml" ];
        allowTools = [
          "events_list" "namespaces_list" "nodes_log" "nodes_stats_summary" "nodes_top"
          "pods_get" "pods_list" "pods_list_in_namespace" "pods_log" "pods_top"
          "resources_get" "resources_list"
        ];
      };
    }
    // optionalAttrs (aws != null) {
      aws = {
        command = "infra-aws-mcp";
        args = [ "--config" "${etc}/aws.json" ];
        allowTools = [ "accounts" "whoami" "read" "logs_insights" ];
      };
    }
    // optionalAttrs (azure != null) {
      azure = {
        command = "azure-mcp";
        args = [ "server" "start" "--transport" "stdio" "--read-only" "--mode" "all" ]
          ++ concatMap (namespace: [ "--namespace" namespace ]) azure.namespaces;
        env.DOTNET_BUNDLE_EXTRACT_BASE_DIR = "/tmp/azure-mcp-bundle";
        allowTools = map (namespace: "${namespace}_*") azure.namespaces;
        denyTools = [ "*_create*" "*_update*" "*_delete*" "*_set*" "*appsettings*" "*-learning-resource" ];
        initTimeoutSeconds = 120;
      };
    }
    // optionalAttrs (databases != { }) {
      db = {
        command = "infra-broker-credential";
        args = [ "exec-with-db-passwords" ]
          ++ map (source: "${source}=${passwordVariable source}") passwordSources
          ++ [ "--" "dbhub" "--transport" "stdio" "--config" "${etc}/dbhub.toml" ];
        # DBHub loads .env from its working directory; use an empty one.
        cwd = "/tmp/work";
        allowTools = [ "execute_sql" "execute_sql_*" "search_objects" "search_objects_*" ];
      };
    }
    // optionalAttrs (datadog != null) {
      datadog = {
        url = "https://${datadogHost}/v1/mcp?toolsets=${lib.concatStringsSep "," datadog.toolsets}"
          + lib.optionalString (datadog.omitTools != [ ]) "&omit_tools=${lib.concatStringsSep "," datadog.omitTools}";
        # Placeholders: microsandbox substitutes the real keys for this host only.
        headers = { DD_API_KEY = "{env:INFRA_DD_API_KEY}"; DD_APPLICATION_KEY = "{env:INFRA_DD_APP_KEY}"; };
        allowTools = [ "search_*" "get_*" "aggregate_*" "analyze_*" ];
        denyTools = [ "create_*" "edit_*" "update_*" "delete_*" ];
      };
    }
    // env.extraServers;

  gatewayConfig = json.generate "gateway-${name}.json" {
    environment = name;
    instructions = "Read-only tools for the '${name}' environment${lib.optionalString (env.description != "") " (${env.description})"}. "
      + "Tool names are <source>_<tool>: ${lib.concatStringsSep ", " (attrNames servers)}. Every call is audited. "
      + "Results can contain customer data; keep them inside this incident.";
    tokensDirectory = "/run/infra/tokens";
    logDirectory = "/tmp/logs";
    maxResponseBytes = env.maxResponseBytes;
    listen = { host = "0.0.0.0"; port = 8080; };
    allowedHosts = [ "host.microsandbox.internal" "localhost" "127.0.0.1" ];
    denyTools = [ "*secret*" "*password*" "*credential*" "*configuration_view*" "*pods_exec*" "*pods_run*" ] ++ env.denyTools;
    env = {
      KUBECONFIG = "${etc}/kubeconfig.json";
      AWS_CONFIG_FILE = "${etc}/aws-config";
      INFRA_CREDD_URL = creddUrl;
    } // optionalAttrs (aws != null) {
      AWS_CONTAINER_CREDENTIALS_FULL_URI = "${creddUrl}/aws/${awsDefaultAccount}";
      AWS_REGION = awsDefaultRegion;
    } // optionalAttrs (azure != null) {
      AZURE_TOKEN_CREDENTIALS = "ManagedIdentityCredential";
      AZURE_SUBSCRIPTION_ID = lib.head azure.subscriptions;
      AZURE_TENANT_ID = azure.tenantId;
    };
    inherit servers;
  };

  doctorConfig = json.generate "doctor-${name}.json" {
    awsAccounts = attrNames awsAccounts;
    azureResources = lib.take 1 azureResources;
    kubernetesClusters = clusterNames;
    targets = mapAttrsToList (n: c: { name = "k8s ${n}"; inherit (c) host port; }) clusters
      ++ mapAttrsToList (n: d: { name = "db ${n}"; inherit (d) host port; }) databases;
  };

  # Copies, not symlinks: the directory is mounted into the broker VM, where
  # the host's store paths do not exist.
  broker = pkgs.runCommand "infra-broker-config-${name}" { } ''
    mkdir -p $out
    cp ${gatewayConfig} $out/gateway.json
    cp ${kubeconfig} $out/kubeconfig.json
    cp ${kubernetesServerConfig} $out/kubernetes-mcp-server.toml
    cp ${dbhubConfig} $out/dbhub.toml
    cp ${awsServerConfig} $out/aws.json
    cp ${awsConfig} $out/aws-config
    cp ${doctorConfig} $out/doctor.json
  '';

  # ---- infra-credd ---------------------------------------------------------------
  credd = json.generate "infra-credd-${name}.json" {
    environment = name;
    refreshMarginSeconds = 300;
    aws.accounts = mapAttrs (account: a: {
      inherit (a) sourceProfile roleArn sourceIdentity durationSeconds;
      sessionName = "infra-agent-${name}-${account}";
      sessionPolicy = if a.roleArn == null then null else a.sessionPolicy;
      region = lib.head a.regions;
    }) awsAccounts;
    azure = if azure == null then null else { inherit (azure) tenantId; resources = azureResources; };
    kubernetes = mapAttrs (clusterName: c: {
      inherit (c) provider account region tenantId command;
      clusterName = if c.clusterName != null then c.clusterName else clusterName;
    }) clusters;
    databases = mapAttrs (_: db: { inherit (db) passwordCommand user; })
      (lib.filterAttrs (_: db: db.auth == "password") databases);
  };

  # ---- host CLI ------------------------------------------------------------------
  privateTargets =
    mapAttrsToList (n: c: { name = "k8s ${n}"; inherit (c) host port cidrs via; }) clusters
    ++ mapAttrsToList (n: d: { name = "db ${n}"; inherit (d) host port cidrs via; }) databases;
  publicHosts = unique (awsHosts ++ azureHosts ++ optional (datadog != null) datadogHost ++ env.extraAllowedHosts);
  netRules = unique (map (host: allow host 443) publicHosts ++ concatMap privateRules privateTargets);
  # Kubernetes API servers verify against their own CA, which the kubeconfig
  # pins; microsandbox must not re-sign them.
  tlsBypass = unique (lib.filter (host: !isIp host) (map (c: c.host) (attrValues clusters)));

  cli = {
    inherit port dnsPort netRules tlsBypass;
    description = env.description;
    brokerSandbox = "${brokerPrefix}-${name}";
    brokerConfig = "${broker}";
    creddConfig = "${credd}";
    tlsUpstreamCaCerts = map toString env.tlsUpstreamCaCerts;
    dnsForwarders = env.dnsForwarders;
    secrets = datadogSecrets;
    servers = attrNames servers;
    preflight = {
      awsProfiles = unique (map (a: a.sourceProfile) (attrValues awsAccounts));
      azureTenant = if azure == null then null else azure.tenantId;
      vpns = mapAttrs (_: vpn: vpn.check) env.vpns;
      targets = map (t: { inherit (t) name host port via; }) privateTargets;
    };
  };
in
{
  inherit broker credd netRules;
  cli = cli // {
    # Recreate the broker whenever anything it was created with changes.
    configHash = builtins.hashString "sha256" (builtins.toJSON cli);
  };
}
