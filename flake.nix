{
    description = "The root flake for all of my system dotfiles.";
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    };
    outputs = { self nixpkgs systemName }: 
    let
        lib = import <nixpkgs/lib>;
        systemBasePath =
            let p = ./. + "/systems/${systemName}";
            in (assert builtins.pathExists p || abort "no system named ${p}"; p);

        systemRoot = import (systemBasePath + "/dotfile-root.nix");
        nixos = import "${(import ./nix/sources.nix).nixpkgs}/nixos";
        invoke = targetAttr: builtins.getAttr targetAttr (systemRoot.extra {
            inherit nixos;
        });
        vm = invoke "vm";
        diskImage = invoke "diskImage";
        firmware = invoke "firmware";
    in nixos { 
        configuration = systemRoot.configuration;
        system = systemRoot.system;
    } // { inherit vm diskImage firmware; };
}
