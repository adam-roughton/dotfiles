# Builds infra-agent with an example configuration covering every source type.
# Used by the tests and as a configuration reference:
#
#   nix build --impure --expr '(builtins.getFlake (toString ./.)).packages.${builtins.currentSystem}.infra-agent-example'
#
# (exposed as packages.<system>.infra-agent-example in flake.nix).
{ inputs, system }:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      ../../agent-sandbox
      ../.
      {
        home.username = "example";
        home.homeDirectory = "/home/example";
        home.stateVersion = "25.05";
        dotfiles.agentSandbox = {
          copilotTokenFile = "/home/example/development/agent/credentials/github-copilot-token";
          opencodeConfig.model = "github-copilot/claude-opus-5.5";
        };
        dotfiles.infraAgent = {
          enabled = true;
          environments.prod = {
            description = "production";
            vpns = {
              tailscale.check = "tailscale status --peers=false >/dev/null";
              fortinet.check = "ifconfig | grep -q ppp0";
            };
            dnsForwarders = {
              "eks.amazonaws.com" = "100.100.100.100";
              "privatelink.westeurope.azmk8s.io" = "10.40.0.4";
            };
            aws = {
              accounts = {
                prod = {
                  sourceProfile = "sso-prod";
                  roleArn = "arn:aws:iam::111111111111:role/infra-agent-readonly";
                  regions = [ "eu-west-1" "us-east-1" ];
                };
                shared.sourceProfile = "sso-shared-readonly";
                shared.regions = [ "eu-west-1" ];
              };
              defaultAccount = "prod";
            };
            azure = {
              tenantId = "00000000-0000-0000-0000-000000000000";
              subscriptions = [ "11111111-1111-1111-1111-111111111111" ];
            };
            kubernetes = {
              payments = {
                provider = "eks";
                server = "https://ABC123.gr7.eu-west-1.eks.amazonaws.com";
                certificateAuthorityData = "LS0tLS1CRUdJTi0tLS0tCg==";
                cidrs = [ "10.20.0.0/16" ];
                via = "tailscale";
              };
              orders = {
                provider = "aks";
                server = "https://orders-abc.privatelink.westeurope.azmk8s.io:443";
                certificateAuthorityData = "LS0tLS1CRUdJTi0tLS0tCg==";
                cidrs = [ "10.40.0.0/16" ];
                via = "fortinet";
              };
            };
            databases = {
              orders = {
                engine = "postgres";
                host = "orders-replica.cluster-ro-abc.eu-west-1.rds.amazonaws.com";
                port = 5432;
                database = "orders";
                user = "infra_agent_ro";
                auth = "rds-iam";
                cidrs = [ "10.20.64.0/20" ];
                via = "tailscale";
              };
              billing = {
                engine = "postgres";
                host = "billing.internal.example";
                port = 5432;
                database = "billing";
                user = "infra_agent_ro";
                passwordCommand = "pass show databases/billing-ro";
                cidrs = [ "10.40.8.0/24" ];
                via = "fortinet";
              };
            };
            datadog = {
              site = "datadoghq.eu";
              apiKeyCommand = "pass show datadog/api-key";
              appKeyCommand = "pass show datadog/app-key-readonly";
            };
          };
          environments.staging.aws.accounts.staging = {
            sourceProfile = "sso-staging";
            regions = [ "eu-west-1" ];
          };
          defaultEnvironment = "prod";
        };
      }
    ];
  };
  failed = map (a: a.message) (builtins.filter (a: !a.assertion) home.config.assertions);
in
if failed != [ ] then throw (builtins.concatStringsSep "\n" failed)
else pkgs.buildEnv {
  name = "infra-agent-example";
  paths = builtins.filter (p: builtins.elem (pkgs.lib.getName p) [ "infra-agent" "infra-credd" ]) home.config.home.packages;
  pathsToLink = [ "/bin" ];
}
