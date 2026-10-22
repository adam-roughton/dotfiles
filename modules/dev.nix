{ config, pkgs, ... }:
let
  # Fabric, which azure-cli requires, is marked broken and incompatible with
  # invoke 3.x. Remove this once nixpkgs updates Azure CLI's dependencies.
  azure-cli = pkgs.azure-cli.override {
    python3 = pkgs.python313.override {
      packageOverrides = self: super: {
        fabric = super.fabric.overridePythonAttrs (old: {
          meta = old.meta // { broken = false; };
        });

        invoke = super.buildPythonPackage rec {
          pname = "invoke";
          version = "2.2.1";
          format = "setuptools";

          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-UVv0m0pIkyt5sCRZA0jaIvOcSULf+ZGtH7i4uuob5wc=";
          };

          postPatch = ''
            sed -e 's|/bin/bash|${pkgs.bash}/bin/bash|g' -i invoke/config.py
          '';

          doCheck = false;
          pythonImportsCheck = [ "invoke" ];

          postInstall = pkgs.lib.optionalString (pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform) ''
            mkdir -p $out/share/{bash-completion/completions,fish/vendor_completions.d,zsh/site-functions}
            $out/bin/inv --print-completion-script=zsh >$out/share/zsh/site-functions/_inv
            $out/bin/inv --print-completion-script=bash >$out/share/bash-completion/completions/inv.bash
            $out/bin/inv --print-completion-script=fish >$out/share/fish/vendor_completions.d/inv.fish
          '';
        };
      };
    };
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
