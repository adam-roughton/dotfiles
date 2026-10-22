{ config, pkgs, ... }:
let
  # Fabric, which azure-cli requires, is marked broken with invoke >= 3
  # (https://github.com/fabric/fabric/issues/2376), so pin invoke 2.x for
  # azure-cli. Remove this once nixpkgs updates Fabric for invoke 3.x.
  azurePythonOverrides = self: super: {
    invoke = super.invoke.overridePythonAttrs (old: rec {
      version = "2.2.1";
      src = pkgs.fetchPypi {
        pname = "invoke";
        inherit version;
        hash = "sha256-UVv0m0pIkyt5sCRZA0jaIvOcSULf+ZGtH7i4uuob5wc=";
      };
    });
  };

  # azure-cli builds its package set with `python3.override { packageOverrides
  # = ...; }`, which replaces rather than composes with any packageOverrides
  # already applied to the python3 we pass in. Wrap `override` so that our
  # overrides are composed on top of azure-cli's own.
  azurePython = pkgs.python313 // {
    override = args: pkgs.python313.override (args // {
      packageOverrides = pkgs.lib.composeExtensions
        (args.packageOverrides or (_: _: { }))
        azurePythonOverrides;
    });
  };

  azure-cli = pkgs.azure-cli.override { python3 = azurePython; };
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
