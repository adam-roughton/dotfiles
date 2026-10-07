{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.agentSandbox;
  codeAgent = pkgs.writeShellApplication {
    name = "code-agent";
    runtimeInputs = with pkgs; [ coreutils gnused git jq ];
    text = builtins.readFile ./scripts/code-agent;
  };
in with lib; {
  options = {
    dotfiles.agentSandbox = {
      enabled = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  config = {
    home.packages = with pkgs; lib.optionals cfg.enabled [
      codeAgent
    ];
  };
}
