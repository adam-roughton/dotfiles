{ systemName }:
let
  nixpkgs = (import ./nix/sources.nix).nixpkgs;

  systemBasePath =
    let p = ./. + "/systems/${systemName}";
    in (assert builtins.pathExists p || abort "no system named ${p}"; p);

  systemRoot = import (systemBasePath + "/dotfile-root.nix");
  
  pkgs = import nixpkgs { 
    system = systemRoot.system;
  };
  
  nixos = import "${(import ./nix/sources.nix).nixpkgs}/nixos" { 
      configuration = systemRoot.config;
      system = systemRoot.system;
  };

  invoke = targetAttr: builtins.getAttr targetAttr (systemRoot.extra {
    inherit pkgs;
    config = systemRoot.config;
  });

  vm = invoke "vm";
  diskImage = invoke "diskImage";

in nixos // { inherit vm diskImage; }
