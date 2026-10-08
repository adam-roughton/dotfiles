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

      # sh (static binary; haskellPackages.ShellCheck would pull in all of GHC)
      shellcheck

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
    ];
  };
}
