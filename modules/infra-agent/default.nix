# infra-agent: production triage agents with no credentials and no route to
# infrastructure. See README "Infra Agent" for the design.
#
#   agent VM (per incident)  opencode; egress only to the LLM host and to the
#                            broker's published port on the host
#   broker VM (per env)      MCP gateway + read-only MCP servers; egress only to
#                            the declared APIs, clusters and databases
#   infra-credd (host)       mints short-lived credentials for the broker from
#                            the host's own CLI sessions, over a vsock route
{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.infraAgent;
  json = pkgs.formats.json { };
  inherit (lib) mkOption types literalExpression;

  # An IPv4 or IPv6 address, optionally with a prefix length (as agent-sandbox).
  network = types.strMatching "([0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?|[0-9a-fA-F.]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?)";
  hostname = types.strMatching "[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?";
  absolutePath = types.strMatching "/[^\n:]*";
  size = types.strMatching "[1-9][0-9]*[KMG]?";

  privateTargetOptions = {
    cidrs = mkOption {
      type = types.nonEmptyListOf network;
      example = [ "10.20.0.0/16" ];
      description = "Addresses the target resolves to. The broker may connect to them on the target's port only.";
    };
    via = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "tailscale";
      description = "Name of the entry in `vpns` that routes to this target (reported by preflight checks).";
    };
  };

  awsAccountModule = types.submodule {
    options = {
      sourceProfile = mkOption {
        type = types.str;
        example = "sso-prod-readonly";
        description = "Host AWS CLI profile (usually an IAM Identity Center session) that credentials are minted from.";
      };
      roleArn = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "arn:aws:iam::123456789012:role/infra-agent-readonly";
        description = ''
          Role assumed from sourceProfile for the broker, with sessionPolicy and sourceIdentity. Null uses the
          profile's own short-lived credentials (aws configure export-credentials), which cannot be narrowed
          further; use a read-only permission set then.
        '';
      };
      regions = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [ "eu-west-1" ];
        description = "Regions the broker may call. The first is the default.";
      };
      sourceIdentity = mkOption {
        type = types.nullOr types.str;
        default = "infra-agent";
        description = "sts:SourceIdentity set on assumed-role sessions, so CloudTrail separates agent calls from yours.";
      };
      durationSeconds = mkOption {
        type = types.ints.between 900 43200;
        default = 3600;
        description = "Lifetime of assumed-role sessions (role chaining limits this to one hour).";
      };
      sessionPolicy = mkOption {
        type = types.nullOr json.type;
        default = {
          Version = "2012-10-17";
          Statement = [
            { Effect = "Allow"; Action = "*"; Resource = "*"; }
            {
              Effect = "Deny";
              Resource = "*";
              Action = [
                "secretsmanager:GetSecretValue" "secretsmanager:BatchGetSecretValue" "ssm:GetParameter*"
                "kms:Decrypt" "kms:GenerateDataKey*" "s3:GetObject*" "lambda:GetFunction" "lambda:InvokeFunction"
                "ec2:GetPasswordData" "ecr:GetAuthorizationToken" "ecr:GetDownloadUrlForLayer"
                "ssm:StartSession" "ssm:SendCommand" "ecs:ExecuteCommand"
                "sts:AssumeRole*" "sts:GetSessionToken" "sts:GetFederationToken"
              ];
            }
          ];
        };
        description = ''
          Session policy attached when assuming roleArn. It can only narrow the role's permissions; the default
          denies reads of secret values and remote execution.
        '';
      };
      description = mkOption { type = types.str; default = ""; description = "Shown to the agent."; };
    };
  };

  awsModule = types.submodule {
    options = {
      accounts = mkOption {
        type = types.attrsOf awsAccountModule;
        description = "AWS accounts, keyed by a short name the agent uses (lowercase letters, digits, '-').";
      };
      defaultAccount = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Account used when a tool call names none (and by the default AWS credential chain). Defaults to the first by name.";
      };
      services = mkOption {
        type = types.listOf types.str;
        default = [ "ec2" "ecs" "eks" "rds" "elbv2" "autoscaling" "cloudwatch" "logs" "lambda" "cloudtrail" "sqs" "elasticache" ];
        description = "boto3 service names the AWS tools may call. Each adds its regional API hostname to the broker's network rules.";
      };
      denyOperations = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [ "secretsmanager:GetSecretValue" "ecs:DescribeTaskDefinition" ];
        description = "service:Operation entries the AWS tools refuse (null: the built-in list of secret-returning reads).";
      };
      extraHosts = mkOption {
        type = types.listOf hostname;
        default = [ ];
        description = "Additional AWS API hostnames to allow on port 443, for services with unusual endpoints.";
      };
    };
  };

  azureModule = types.submodule {
    options = {
      tenantId = mkOption { type = types.str; description = "Entra tenant tokens are minted for."; };
      subscriptions = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "Subscription IDs; the first is Azure MCP's default.";
      };
      namespaces = mkOption {
        type = types.listOf types.str;
        default = [ "monitor" "resourcehealth" "aks" "group" "subscription" ];
        description = ''
          Azure MCP namespaces to load (read-only mode). Avoid keyvault and appservice, whose read-only tools
          return secrets. Namespaces that call other services need their hosts in extraHosts.
        '';
      };
      tokenResources = mkOption {
        type = types.listOf types.str;
        default = [ "https://management.azure.com/" "https://api.loganalytics.io" ];
        description = "Token audiences infra-credd will mint for the broker. Any other audience is refused.";
      };
      extraHosts = mkOption {
        type = types.listOf hostname;
        default = [ ];
        example = [ "mycluster.westeurope.kusto.windows.net" ];
        description = "Additional Azure hostnames to allow on port 443.";
      };
    };
  };

  clusterModule = types.submodule ({ name, ... }: {
    options = privateTargetOptions // {
      provider = mkOption {
        type = types.enum [ "eks" "aks" "command" ];
        description = "How infra-credd mints the cluster token: aws eks get-token, an Entra token for AKS, or `command`.";
      };
      server = mkOption {
        type = types.strMatching "https://.*";
        example = "https://ABC123.gr7.eu-west-1.eks.amazonaws.com";
        description = "API server URL. Use the hostname, not an IP, so TLS to it can bypass microsandbox interception.";
      };
      certificateAuthorityData = mkOption {
        type = types.str;
        description = "Base64-encoded cluster CA certificate (certificate-authority-data in a kubeconfig).";
      };
      tlsServerName = mkOption { type = types.nullOr types.str; default = null; description = "kubeconfig tls-server-name."; };
      namespace = mkOption { type = types.nullOr types.str; default = null; description = "Default namespace."; };
      account = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "EKS: AWS account (aws.accounts) whose credentials authenticate to the cluster. Defaults to the default account.";
      };
      clusterName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "EKS: cluster name in AWS, when it differs from this entry's name (${name}).";
      };
      region = mkOption { type = types.nullOr types.str; default = null; description = "EKS: region (default: the account's first)."; };
      tenantId = mkOption { type = types.nullOr types.str; default = null; description = "AKS: tenant (default: azure.tenantId)."; };
      command = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "command: host command printing an ExecCredential JSON with status.token and status.expirationTimestamp.";
      };
    };
  });

  databaseModule = types.submodule ({ name, ... }: {
    options = privateTargetOptions // {
      engine = mkOption { type = types.enum [ "postgres" "mysql" "mariadb" "sqlserver" ]; description = "Database engine."; };
      host = mkOption { type = hostname; description = "Database hostname (or address)."; };
      port = mkOption { type = types.port; description = "Database port."; };
      database = mkOption { type = types.str; description = "Database name."; };
      user = mkOption { type = types.str; example = "infra_agent_ro"; description = "Read-only database user."; };
      auth = mkOption {
        type = types.enum [ "password" "rds-iam" "entra" ];
        default = "password";
        description = ''
          password: passwordCommand runs on the host when the broker starts DBHub. rds-iam: DBHub signs RDS IAM
          tokens with the account's credentials. entra: Entra token (SQL Server only).
        '';
      };
      passwordCommand = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pass show databases/orders-ro";
        description = "Host shell command printing the password (auth = password).";
      };
      account = mkOption { type = types.nullOr types.str; default = null; description = "rds-iam: AWS account (default: the default account)."; };
      region = mkOption { type = types.nullOr types.str; default = null; description = "rds-iam: region (default: the default account's first)."; };
      sslmode = mkOption {
        type = types.nullOr (types.enum [ "disable" "require" "verify-ca" "verify-full" ]);
        default = "require";
        description = "PostgreSQL sslmode.";
      };
      maxRows = mkOption { type = types.ints.positive; default = 1000; description = "Row limit for execute_sql."; };
      queryTimeout = mkOption { type = types.ints.positive; default = 30; description = "Query timeout in seconds."; };
      extraSettings = mkOption {
        type = (pkgs.formats.toml { }).type;
        default = { };
        description = "Extra DBHub [[sources]] settings for ${name} (see DBHub's TOML reference).";
      };
    };
  });

  datadogModule = types.submodule {
    options = {
      site = mkOption { type = types.str; default = "datadoghq.com"; example = "datadoghq.eu"; description = "Datadog site."; };
      apiKeyCommand = mkOption { type = types.str; example = "pass show datadog/api-key"; description = "Host command printing the API key."; };
      appKeyCommand = mkOption {
        type = types.str;
        example = "pass show datadog/app-key-readonly";
        description = "Host command printing an application key, ideally scoped to read-only (no mcp_write).";
      };
      toolsets = mkOption { type = types.listOf types.str; default = [ "core" ]; description = "Datadog MCP toolsets."; };
      omitTools = mkOption {
        type = types.listOf types.str;
        default = [ "create_datadog_notebook" "edit_datadog_notebook" ];
        description = "Datadog MCP tools to omit (the core toolset's write tools by default).";
      };
    };
  };

  environmentModule = types.submodule ({ name, ... }: {
    options = {
      description = mkOption { type = types.str; default = ""; description = "Shown to the agent and in status output."; };
      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Host loopback port for this environment's broker (default: 47300 + 2 × its index by name).";
      };
      vpns = mkOption {
        type = types.attrsOf (types.submodule {
          options.check = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "tailscale status --peers=false >/dev/null";
            description = "Host command that succeeds when the VPN is connected.";
          };
        });
        default = { };
        description = "VPNs that private targets are reached through (for preflight reports).";
      };
      dnsForwarders = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { "eks.amazonaws.com" = "100.100.100.100"; "privatelink.westeurope.azmk8s.io" = "10.40.0.4"; };
        description = ''
          Split DNS for the broker: domain → resolver address. When set, infra-agent runs dnsmasq on host
          loopback for this environment and the broker resolves through it; other names use the host resolver.
        '';
      };
      tlsUpstreamCaCerts = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Extra CAs microsandbox trusts for upstream HTTPS, e.g. a VPN's TLS-inspection CA.";
      };
      aws = mkOption { type = types.nullOr awsModule; default = null; description = "AWS access for ${name}."; };
      azure = mkOption { type = types.nullOr azureModule; default = null; description = "Azure access for ${name}."; };
      kubernetes = mkOption { type = types.attrsOf clusterModule; default = { }; description = "Kubernetes clusters, keyed by context name."; };
      kubernetesDeniedResources = mkOption {
        type = types.listOf (types.attrsOf types.str);
        default = [ { group = ""; version = "v1"; kind = "Secret"; } ];
        description = "kubernetes-mcp-server denied_resources (Secrets by default).";
      };
      databases = mkOption { type = types.attrsOf databaseModule; default = { }; description = "DBHub sources, keyed by id (lowercase letters, digits, '_')."; };
      datadog = mkOption { type = types.nullOr datadogModule; default = null; description = "Datadog's MCP server."; };
      extraServers = mkOption {
        type = types.attrsOf json.type;
        default = { };
        description = "Additional gateway upstreams (command/args/env or url/headers, plus allowTools). Their hosts need extraAllowedHosts.";
      };
      extraAllowedHosts = mkOption { type = types.listOf hostname; default = [ ]; description = "Extra hostnames the broker may reach on 443."; };
      denyTools = mkOption { type = types.listOf types.str; default = [ ]; description = "Extra glob patterns of namespaced tool names to hide."; };
      maxResponseBytes = mkOption { type = types.ints.positive; default = 200000; description = "Tool result size cap."; };
    };
  });

  names = lib.sort lib.lessThan (lib.attrNames cfg.environments);
  ports = lib.listToAttrs (lib.imap0 (index: name: {
    inherit name;
    value = if cfg.environments.${name}.port != null then cfg.environments.${name}.port else 47300 + 2 * index;
  }) names);
  environments = lib.mapAttrs (name: env: import ./environment.nix {
    inherit pkgs lib name env;
    port = ports.${name};
    dnsPort = if env.dnsForwarders == { } then null else ports.${name} + 1;
    brokerPrefix = cfg.broker.sandboxPrefix;
  }) cfg.environments;

  cliConfig = json.generate "infra-agent.json" {
    stateDirectory = cfg.stateDirectory;
    sandboxPrefix = cfg.sandboxPrefix;
    defaultEnvironment = if cfg.defaultEnvironment != null then cfg.defaultEnvironment
      else if lib.length names == 1 then lib.head names else null;
    llmHosts = cfg.llmHosts;
    copilotTokenFile = if cfg.copilotTokenFile == null then "" else cfg.copilotTokenFile;
    agent = {
      inherit (cfg.agent) image cpus memory rootDisk profile;
      opencodeConfig = cfg.agent.opencodeConfig;
    };
    broker = { inherit (cfg.broker) image cpus memory rootDisk; };
    environments = lib.mapAttrs (_: e: e.cli) environments;
  };

  credd = pkgs.runCommand "infra-credd" { } ''
    mkdir -p $out/bin
    { echo "#!${pkgs.python3}/bin/python3"; tail -n +2 ${./credd/infra_credd.py}; } > $out/bin/infra-credd
    chmod +x $out/bin/infra-credd
  '';

  infraAgent = pkgs.writeShellApplication {
    name = "infra-agent";
    runtimeInputs = with pkgs; [ coreutils findutils gnused gnugrep jq curl ];
    text = lib.replaceStrings [ "@config@" "@credd@" "@dnsmasq@" ]
      (map lib.escapeShellArg [ "${cliConfig}" "${credd}/bin/infra-credd" "${pkgs.dnsmasq}/bin/dnsmasq" ])
      (builtins.readFile ./scripts/infra-agent);
  };

  # ---- validation (Home Manager assertions are checked on the host) ----------
  checks = lib.concatLists (lib.mapAttrsToList (name: env:
    let
      awsAccounts = if env.aws == null then { } else env.aws.accounts;
      where = "dotfiles.infraAgent.environments.${name}";
    in
    [
      { assertion = builtins.match "[a-z][a-z0-9-]*" name != null; message = "${where}: environment names use lowercase letters, digits and '-'."; }
      { assertion = env.aws == null || awsAccounts != { }; message = "${where}.aws.accounts must not be empty."; }
      { assertion = env.aws == null || env.aws.defaultAccount == null || awsAccounts ? ${env.aws.defaultAccount}; message = "${where}.aws.defaultAccount is not in aws.accounts."; }
    ]
    ++ lib.mapAttrsToList (account: _: { assertion = builtins.match "[a-z][a-z0-9-]*" account != null; message = "${where}.aws.accounts.${account}: use lowercase letters, digits and '-'."; }) awsAccounts
    ++ lib.concatLists (lib.mapAttrsToList (cluster: c: [
      { assertion = builtins.match "[a-z0-9][a-z0-9-]*" cluster != null; message = "${where}.kubernetes.${cluster}: use lowercase letters, digits and '-'."; }
      { assertion = c.provider != "eks" || (env.aws != null && (c.account == null || awsAccounts ? ${c.account})); message = "${where}.kubernetes.${cluster}: EKS clusters need aws configured and account in aws.accounts."; }
      { assertion = c.provider != "aks" || env.azure != null || c.tenantId != null; message = "${where}.kubernetes.${cluster}: AKS clusters need azure or tenantId."; }
      { assertion = c.provider != "command" || c.command != [ ]; message = "${where}.kubernetes.${cluster}: provider command needs command."; }
      { assertion = c.via == null || env.vpns ? ${c.via}; message = "${where}.kubernetes.${cluster}.via is not in vpns."; }
    ]) env.kubernetes)
    ++ lib.concatLists (lib.mapAttrsToList (source: db: [
      { assertion = builtins.match "[a-z][a-z0-9_]*" source != null; message = "${where}.databases.${source}: use lowercase letters, digits and '_'."; }
      { assertion = db.auth != "password" || db.passwordCommand != null; message = "${where}.databases.${source}: auth = password needs passwordCommand."; }
      { assertion = db.auth != "rds-iam" || (env.aws != null && (db.account == null || awsAccounts ? ${db.account})); message = "${where}.databases.${source}: rds-iam needs aws configured and account in aws.accounts."; }
      { assertion = db.auth != "entra" || (db.engine == "sqlserver" && env.azure != null); message = "${where}.databases.${source}: entra auth is supported for sqlserver with azure configured."; }
      { assertion = db.via == null || env.vpns ? ${db.via}; message = "${where}.databases.${source}.via is not in vpns."; }
    ]) env.databases)
    ++ lib.mapAttrsToList (server: _: { assertion = builtins.match "[a-z][a-z0-9]*" server != null; message = "${where}.extraServers.${server}: use lowercase letters and digits."; }) env.extraServers
  ) cfg.environments);
in
{
  options.dotfiles.infraAgent = {
    enabled = mkOption { type = types.bool; default = false; description = "Install the infra-agent command (alias ia)."; };
    stateDirectory = mkOption {
      type = absolutePath;
      default = "${config.home.homeDirectory}/development/agent/infra";
      defaultText = literalExpression ''"''${config.home.homeDirectory}/development/agent/infra"'';
      description = ''
        Incident workspaces (which hold customer data) and broker state. Keep it on an encrypted disk and out of
        synced or backed-up folders.
      '';
    };
    sandboxPrefix = mkOption { type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*"; default = "infra-agent"; description = "Prefix of incident sandbox names."; };
    defaultEnvironment = mkOption { type = types.nullOr types.str; default = null; description = "Environment used without --env (default: the only one)."; };
    llmHosts = mkOption {
      type = types.listOf hostname;
      default = [ "api.githubcopilot.com" ];
      description = "The only hosts (port 443) the agent VM may reach besides the broker.";
    };
    copilotTokenFile = mkOption {
      type = types.nullOr absolutePath;
      default = config.dotfiles.agentSandbox.copilotTokenFile or null;
      defaultText = literalExpression "config.dotfiles.agentSandbox.copilotTokenFile";
      description = "GitHub Copilot token (written by code-agent login), substituted by microsandbox for api.githubcopilot.com.";
    };
    agent = {
      image = mkOption { type = types.nonEmptyStr; default = "dotfiles-agent:latest"; description = "Agent image (the code-agent image)."; };
      cpus = mkOption { type = types.ints.positive; default = 4; description = "Agent VM CPUs."; };
      memory = mkOption { type = size; default = "8G"; description = "Agent VM memory."; };
      rootDisk = mkOption { type = size; default = "12G"; description = "Agent VM root disk."; };
      profile = mkOption { type = types.strMatching "[a-z0-9][a-z0-9_-]*"; default = "infra"; description = "Agent profile in the image."; };
      opencodeConfig = mkOption {
        type = json.type;
        default = { };
        description = "opencode settings for new agent VMs (OPENCODE_CONFIG_CONTENT), e.g. the model.";
      };
    };
    broker = {
      image = mkOption { type = types.nonEmptyStr; default = "dotfiles-infra-broker:latest"; description = "Broker image (make.sh image broker)."; };
      sandboxPrefix = mkOption { type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*"; default = "infra-broker"; description = "Prefix of broker sandbox names."; };
      cpus = mkOption { type = types.ints.positive; default = 2; description = "Broker VM CPUs."; };
      memory = mkOption { type = size; default = "4G"; description = "Broker VM memory."; };
      rootDisk = mkOption { type = size; default = "8G"; description = "Broker VM root disk."; };
    };
    environments = mkOption {
      type = types.attrsOf environmentModule;
      default = { };
      description = "Environments (one broker VM each), keyed by name, e.g. prod and staging.";
    };
  };

  config = lib.mkIf cfg.enabled {
    assertions = checks ++ [
      { assertion = cfg.environments != { }; message = "dotfiles.infraAgent.environments must define at least one environment."; }
      { assertion = cfg.defaultEnvironment == null || cfg.environments ? ${cfg.defaultEnvironment}; message = "dotfiles.infraAgent.defaultEnvironment is not in environments."; }
      {
        assertion = lib.length (lib.unique (lib.concatMap (n: [ ports.${n} (ports.${n} + 1) ]) names)) == 2 * lib.length names;
        message = "dotfiles.infraAgent.environments: broker ports (and port + 1 for DNS) must not overlap.";
      }
    ];
    dotfiles.infraAgent.agent.opencodeConfig = {
      autoupdate = lib.mkDefault false;
      share = lib.mkDefault "disabled";
    } // lib.optionalAttrs ((config.dotfiles.agentSandbox.opencodeConfig or { }) ? model) {
      # Same default model as code-agent.
      model = lib.mkDefault config.dotfiles.agentSandbox.opencodeConfig.model;
    };
    home.packages = [ infraAgent credd ];
  };
}
