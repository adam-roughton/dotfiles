{ config, lib, pkgs, ... }:

with lib;

let cfg = config.programs.agent-sandbox;
in {
  options.programs.agent-sandbox = {
    enable = mkEnableOption "pi + srt agent sandboxing";
    allowedDomains = mkOption {
      type = types.listOf types.str;
      default = [
        "api.anthropic.com"
        "github.com"
        "api.github.com"
        "copilot-proxy.githubusercontent.com"
        "origin-tracker.githubusercontent.com"
        "*.githubcopilot.com"
        "*.business.githubcopilot.com"
      ];
    };
    worktreesDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/agent-worktrees";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.pi-coding-agent
      pkgs._1password-cli
      (pkgs.callPackage ../packages/sandbox-runtime.nix { })
      (pkgs.callPackage ../packages/agent-worktree { })
    ];

    home.sessionVariables = {
      AGENT_WORKTREES_DIR = cfg.worktreesDir;
      AGENT_ALLOWED_DOMAINS = builtins.toJSON cfg.allowedDomains;
    };
  };
}
