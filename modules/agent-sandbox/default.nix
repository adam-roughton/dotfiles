{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.agentSandbox;
  codeAgent = pkgs.writeShellApplication {
    name = "code-agent";
    runtimeInputs = with pkgs; [ coreutils gnused git jq ];
    text = lib.replaceStrings
      [ "@workspaceDirectory@" "@upstreamDirectory@" "@sandboxPrefix@" "@image@" "@cpus@" "@memory@" "@cacheDirectory@" ]
      (map lib.escapeShellArg [ cfg.workspaceDirectory cfg.upstreamDirectory cfg.sandboxPrefix cfg.image (toString cfg.cpus) cfg.memory cfg.cacheDirectory ])
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
    };
  };

  config = {
    home.packages = with pkgs; lib.optionals cfg.enabled [
      codeAgent
    ];
  };
}
