{ config, pkgs, ... }:
{
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

      (writeShellApplication {
        name = "handover-setup";
        runtimeInputs = [ coreutils gnused git ];
        text = builtins.readFile ./dev/scripts/handover-setup;
      })
      (writeShellApplication {
        name = "handover-sync";
        runtimeInputs = [ coreutils gnused git ];
        text = builtins.readFile ./dev/scripts/handover-sync;
      })
    ];
  };
}
