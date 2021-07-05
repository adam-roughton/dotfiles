{ pkgs, ... }:
let
  aws-console = pkgs.callPackage ./aws-console.nix {};
in

with pkgs;

mkShell {
  buildInputs = [ aws-console ];
}
