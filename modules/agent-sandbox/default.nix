{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.agentSandbox;
  handoverSetup = pkgs.writeShellApplication {
    name = "handover-setup";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./scripts/handover-setup;
  };
  handoverSync = pkgs.writeShellApplication {
    name = "handover-sync";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./scripts/handover-sync;
  };
  handoverStart = pkgs.writeShellApplication {
    name = "handover-start";
    runtimeInputs = with pkgs; [ coreutils gnused git handoverSetup ];
    text = builtins.readFile ./scripts/handover-start;
  };
  handoverCleanup = pkgs.writeShellApplication {
    name = "handover-cleanup";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./scripts/handover-cleanup;
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
      handoverSetup
      handoverSync
      handoverStart
      handoverCleanup
    ];
  };
}
