{ config, pkgs, lib, inputs, ... }:
let
  cfg = config.dotfiles.agentSandbox;
  json = pkgs.formats.json { };
  # Builds microsandbox images (make.sh image). It runs make.sh from the copy
  # of this repository in the Nix store (inputs.self, which includes the
  # private submodule), so it needs no checkout and builds the images defined
  # by the configuration that was switched to. The reference to the source
  # keeps that copy from being garbage collected.
  agentImage = pkgs.writeShellApplication {
    name = "agent-image";
    runtimeInputs = with pkgs; [ coreutils gnused gnutar git jq ];
    text = ''
      export DOTFILES_IMAGE_COMMAND=agent-image
      exec ${pkgs.bash}/bin/bash ${lib.escapeShellArg "${inputs.self}/make.sh"} image "$@"
    '';
  };
  # An IPv4 or IPv6 address, optionally with a prefix length.
  network = lib.types.strMatching "([0-9]{1,3}(\\.[0-9]{1,3}){3}(/[0-9]{1,2})?|[0-9a-fA-F.]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?)";
  # microsandbox requires IPv6 targets to be bracketed.
  networkRule = action: address: "${action}@${if lib.hasInfix ":" address then "[${address}]" else address}";
  # Explicit rules are evaluated before profile rules, and the first match wins,
  # so denies are listed first to override both allows and profiles.
  networkRules = map (networkRule "deny") cfg.deniedNetworks ++ map (networkRule "allow") cfg.allowedNetworks;
  # opencode is only needed on the host for `code-agent login`.
  opencode = if cfg.copilotTokenFile == null then "opencode" else "${pkgs.opencode}/bin/opencode";
  codeAgent = pkgs.writeShellApplication {
    name = "code-agent";
    runtimeInputs = with pkgs; [ coreutils gnused git jq ];
    text = lib.replaceStrings
      [ "@workspaceDirectory@" "@upstreamDirectory@" "@sandboxPrefix@" "@image@" "@cpus@" "@memory@" "@rootDisk@" "@networkProfiles@" "@networkRules@" "@cacheDirectory@" "@copilotTokenFile@" "@opencodeConfig@" "@opencode@" "@agentProfile@" "@agentImage@" ]
      (map lib.escapeShellArg [ cfg.workspaceDirectory cfg.upstreamDirectory cfg.sandboxPrefix cfg.image (toString cfg.cpus) cfg.memory cfg.rootDisk (lib.concatStringsSep "," cfg.networkProfiles) (lib.concatStringsSep "," networkRules) cfg.cacheDirectory
        (if cfg.copilotTokenFile == null then "" else cfg.copilotTokenFile)
        # `toJSON` drops string context. Appending an empty substring preserves
        # the flake-source reference without changing the JSON content.
        (builtins.toJSON cfg.opencodeConfig + builtins.substring 0 0 (builtins.toString inputs.self))
        opencode
        (if cfg.agentProfile == null then "" else cfg.agentProfile)
        "${agentImage}/bin/agent-image" ])
      (builtins.readFile ./scripts/code-agent);
  };
in with lib; {
  imports = [
    (mkRemovedOptionModule [ "dotfiles" "agentSandbox" "dotfilesDirectory" ]
      "code-agent builds project images with agent-image, which uses the copy of the dotfiles in the Nix store.")
  ];

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
        description = "Microsandbox image tag used by code-agent and agent-image.";
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
        default = [ "public" ];
        description = ''
          Microsandbox network profiles enabled for new sandboxes. `private` permits every private range the
          host can reach (LAN, Tailscale, VPNs); prefer `allowedNetworks` for specific destinations.
        '';
      };
      deniedNetworks = mkOption {
        type = types.listOf network;
        default = [ ];
        example = [ "172.120.0.0/16" "fd00::/8" ];
        description = ''
          Addresses or CIDRs that new sandboxes may not reach, on any port. Takes precedence over
          allowedNetworks and networkProfiles.
        '';
      };
      allowedNetworks = mkOption {
        type = types.listOf network;
        default = [ ];
        example = [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ];
        description = ''
          Addresses or CIDRs that new sandboxes may reach on any port, in addition to networkProfiles.
          Also permits private DNS answers in these ranges.
        '';
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
          Applied over the agent profile, and arrays replace rather than append: setting skills.paths
          here hides the profile's skills.
        '';
      };
      agentProfile = mkOption {
        type = types.nullOr (types.strMatching "[a-z0-9][a-z0-9_-]*");
        default = "code";
        description = ''
          Agent profile (dotfiles.agentProfiles in the agent image) used by new sandboxes. Sets
          OPENCODE_CONFIG to the profile's opencode.json, which adds the profile's skills and settings,
          and AGENT_PROFILE to its name. Attaching fails if the image lacks the profile. Null runs
          opencode with the image's global configuration only.
        '';
      };
    };
  };

  config = {
    warnings = optional (cfg.agentProfile != null && hasAttrByPath [ "skills" "paths" ] cfg.opencodeConfig)
      "dotfiles.agentSandbox.opencodeConfig sets skills.paths, which replaces the skills of agent profile '${cfg.agentProfile}'. Add the skills to the profile instead.";
    dotfiles.agentSandbox.opencodeConfig = {
      autoupdate = mkDefault false;
      share = mkDefault "disabled";
    };
    home.packages = with pkgs; lib.optionals cfg.enabled [
      codeAgent
      agentImage
    ];
  };
}
