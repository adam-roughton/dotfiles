{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.agentSandbox;
  json = pkgs.formats.json { };
  # opencode is only needed on the host for `code-agent login`.
  opencode = if cfg.copilotTokenFile == null then "opencode" else "${pkgs.opencode}/bin/opencode";
  codeAgent = pkgs.writeShellApplication {
    name = "code-agent";
    runtimeInputs = with pkgs; [ coreutils gnused git jq ];
    text = lib.replaceStrings
      [ "@workspaceDirectory@" "@upstreamDirectory@" "@sandboxPrefix@" "@image@" "@cpus@" "@memory@" "@rootDisk@" "@networkProfiles@" "@cacheDirectory@" "@copilotTokenFile@" "@opencodeConfig@" "@opencode@" ]
      (map lib.escapeShellArg [ cfg.workspaceDirectory cfg.upstreamDirectory cfg.sandboxPrefix cfg.image (toString cfg.cpus) cfg.memory cfg.rootDisk (concatStringsSep "," cfg.networkProfiles) cfg.cacheDirectory
        (if cfg.copilotTokenFile == null then "" else cfg.copilotTokenFile) (builtins.toJSON cfg.opencodeConfig) opencode ])
      (builtins.readFile ./scripts/code-agent);
  };
in with lib; {
  options = {
    dotfiles.agentSandbox = {
      enabled = mkOption {
        type = types.bool;
        default = false;
        description = "Install the code-agent sandbox lifecycle command.";
      };
      workspaceDirectory = mkOption {
        type = types.strMatching "/[^\n:]*";
        default = "${config.home.homeDirectory}/development/agent/workspaces";
        defaultText = literalExpression ''"''${config.home.homeDirectory}/development/agent/workspaces"'';
        description = "Absolute host directory for writable task workspaces.";
      };
      upstreamDirectory = mkOption {
        type = types.strMatching "/[^\n:]*";
        default = "${config.home.homeDirectory}/development/agent/upstream-ro";
        defaultText = literalExpression ''"''${config.home.homeDirectory}/development/agent/upstream-ro"'';
        description = "Absolute host directory for read-only bare upstream repositories.";
      };
      sandboxPrefix = mkOption {
        type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*";
        default = "code-agent";
        description = "Prefix for repository-scoped sandbox names.";
      };
      cacheDirectory = mkOption {
        type = types.strMatching "/[^\n:]*";
        default = "${config.home.homeDirectory}/development/agent/package-cache";
        defaultText = literalExpression ''"''${config.home.homeDirectory}/development/agent/package-cache"'';
        description = "Dedicated shared writable package cache for agent sandboxes. Must not overlap repositories, workspace, or upstream directories. Retained by task cleanup.";
      };
      image = mkOption {
        type = types.nonEmptyStr;
        default = "dotfiles-agent:latest";
        description = "Microsandbox image tag used by code-agent and make.sh image.";
      };
      cpus = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Number of CPUs allocated to new sandboxes.";
      };
      memory = mkOption {
        type = types.strMatching "[1-9][0-9]*[KMG]?";
        default = "8G";
        description = "Memory allocated to new sandboxes, using microsandbox size syntax (for example 8G or 512M).";
      };
      rootDisk = mkOption {
        type = types.strMatching "[1-9][0-9]*[KMG]?";
        default = "12G";
        description = "Writable root disk allocated to new sandboxes, using microsandbox size syntax (for example 12G or 512M).";
      };
      networkProfiles = mkOption {
        type = types.listOf (types.enum [ "public" "private" "host" ]);
        default = [ "public" "private" ];
        description = "Microsandbox network profiles enabled for new sandboxes. Private access permits Tailscale and other host-reachable private networks.";
      };
      copilotTokenFile = mkOption {
        type = types.nullOr (types.strMatching "/[^\n:]*");
        default = null;
        example = literalExpression ''"''${config.home.homeDirectory}/development/agent/credentials/github-copilot-token"'';
        description = ''
          Absolute host path of the GitHub Copilot token used by opencode in new sandboxes, written by
          `code-agent login`. The token stays on the host: sandboxes receive a placeholder that microsandbox
          replaces in requests to api.githubcopilot.com. Enabling this turns on microsandbox TLS interception
          for the sandbox's HTTPS traffic. Null disables the Copilot secret.
        '';
      };
      opencodeConfig = mkOption {
        type = json.type;
        default = { };
        defaultText = literalExpression ''{ autoupdate = false; share = "disabled"; }'';
        example = literalExpression ''{ model = "github-copilot/claude-opus-5.5"; }'';
        description = ''
          opencode configuration passed to new sandboxes as OPENCODE_CONFIG_CONTENT. Merged with the
          defaults, which disable self-updates and session sharing; override them explicitly if needed.
        '';
      };
    };
  };

  config = {
    dotfiles.agentSandbox.opencodeConfig = {
      autoupdate = mkDefault false;
      share = mkDefault "disabled";
    };
    home.packages = with pkgs; lib.optionals cfg.enabled [
      codeAgent
    ];
  };
}
