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
      openjdk8 sbt scala

      # sh
      haskellPackages.ShellCheck

      # python
      python311
      python311Packages.virtualenv pipenv uv hatch

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
