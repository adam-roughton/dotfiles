# Evaluates a project's shell.nix for a project agent image (see
# legacyPackages.<system>.agent-project in flake.nix). `<nixpkgs>` resolves to
# the image's nixpkgs, also in project files that shell.nix imports, so the
# shell shares store paths (and therefore image layers) with the base image
# instead of following the evaluating host's NIX_PATH. A shell.nix that is a
# function receives `pkgs` and `lib` for arguments it declares.
{ pkgs, shellFile }:
let
  inherit (pkgs) lib;
  scope = {
    __nixPath = [ { prefix = "nixpkgs"; path = pkgs.path; } ] ++ builtins.nixPath;
    # Store paths (nixpkgs itself) use the normal, cached import; only project
    # files need the overridden lookup path.
    import = path:
      if lib.hasPrefix "${builtins.storeDir}/" (toString path)
      then builtins.import path
      else builtins.scopedImport scope path;
  };
  value = builtins.scopedImport scope shellFile;
  shell =
    if builtins.isFunction value
    then value (builtins.intersectAttrs (builtins.functionArgs value) { inherit pkgs lib; })
    else value;
in
if lib.isDerivation shell then shell
else throw "${toString shellFile} must evaluate to a derivation (for example pkgs.mkShell { ... })"
