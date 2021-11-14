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
      python2 python37
      python37Packages.virtualenv pipenv python3Packages.black

      # rust
      rustc cargo carnix rustfmt

      # K8s
      aws-iam-authenticator
      kubetail

      mysql
      postgresql_10
      jsonnet
    ];
  };
}
