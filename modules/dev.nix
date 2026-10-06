{ config, pkgs, ... }:
let
  handoverSetup = pkgs.writeShellApplication {
    name = "handover-setup";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./dev/scripts/handover-setup;
  };
  handoverSync = pkgs.writeShellApplication {
    name = "handover-sync";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./dev/scripts/handover-sync;
  };
  handoverStart = pkgs.writeShellApplication {
    name = "handover-start";
    runtimeInputs = with pkgs; [ coreutils gnused git handoverSetup ];
    text = builtins.readFile ./dev/scripts/handover-start;
  };
  handoverCleanup = pkgs.writeShellApplication {
    name = "handover-cleanup";
    runtimeInputs = with pkgs; [ coreutils gnused git ];
    text = builtins.readFile ./dev/scripts/handover-cleanup;
  };
in {
  config = {
    home.packages = with pkgs; [

      # dev tools
      plantuml

      # c
      gcc gnumake

      # jvm
      gradle 

      # scala
      jdk17 sbt scala

      # sh
      haskellPackages.ShellCheck

      # python
      python3
      python3Packages.virtualenv pipenv uv hatch

      # rust
      rustc cargo rustfmt

      # kubernetes
      aws-iam-authenticator
      kubetail
      azure-cli
      kubelogin

      mariadb
      postgresql
      jsonnet

      handoverSetup
      handoverSync
      handoverStart
      handoverCleanup
    ];
  };
}
