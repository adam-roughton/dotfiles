{ config, pkgs, lib, ... }:

with lib;

let
  sources = import ../nix/sources.nix;
  lab-env = import sources.lab-env {};
  lab-env-spark = lab-env.mkSparkDist {
     sparkVersion = "2.4.5";
     scalaVersion = "2.12.8";
     hadoopVersion = "3.1.2";
     hadoopProfile = "hadoop-3.1";
     dependencies-sha256 = "0ysh5iv983i2crj9scfvlgjc66zd13zam8k0w3iwh943fzgrr6jm";
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

      lab-env-spark
      (lab-env.buildJupyterLab {
        spark = lab-env-spark;
      })
      
    ];
  };
}
