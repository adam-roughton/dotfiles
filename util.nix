{ pkgs, ... }:
let
  readSecret = secretName:
    let
      envName = "NIX_DOTFILES_SECRET_${builtins.replaceStrings [ "/" "-" ] [ "_" "_" ] secretName}";
      value = builtins.getEnv envName;
    in
      if value == "" then null else value;
in { inherit readSecret; }
