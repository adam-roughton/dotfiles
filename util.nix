{ pkgs, ... }:
let
  secretReader = pkgs.writeShellScript "secretReader.sh" ''
  echo "\"$(pass "personal/nix/$1")\""
  '';

  readSecret = secretName: builtins.exec [ secretReader secretName ];
in { inherit readSecret; }
