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
      python3
      python3Packages.virtualenv pipenv python3Packages.black

      # rust
      rustc cargo rustfmt

      # K8s
      aws-iam-authenticator
      kubetail

      mysql
      postgresql
      jsonnet
    ];
  };
}
