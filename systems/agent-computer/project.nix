# Project agent images: the agent image plus a project's shell.nix environment.
# Built by `make.sh image project` (`agent-image project`), which passes the inputs below in
# environment variables, so these attributes only evaluate with --impure:
#   AGENT_PROJECT_SHELL       absolute path of the project's shell.nix
#   AGENT_PROJECT_BASE_IMAGE  configured base image reference (NAME:TAG)
#   AGENT_PROJECT_IMAGE       project image reference (NAME:TAG) for `image`
#   AGENT_PROJECT_ENV         `nix print-dev-env --profile` store path, for `image`
#   AGENT_PROJECT_ENV_SCRIPT  file holding the `nix print-dev-env` output, for `image`
{ inputs, system }:
let
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  getEnv = name:
    let value = builtins.getEnv name; in
    if value != "" then value
    else throw "${name} is not set; build project images with `agent-image project` or `make.sh image project` (evaluation needs --impure)";
  absolutePath = name:
    let value = getEnv name; in
    if builtins.substring 0 1 value == "/" then /. + value
    else throw "${name} must be an absolute path, not ${value}";
  baseImage = import ./. { inherit inputs system pkgs; };
  shell = import ./project-shell.nix {
    inherit pkgs;
    shellFile = absolutePath "AGENT_PROJECT_SHELL";
  };
in {
  inherit shell;
  # Identifies a project image by the configured base image plus the
  # derivations it is made from. make.sh puts it in the image tag, so a project
  # image is rebuilt only when one of them changes. Evaluating it builds
  # nothing.
  key = builtins.substring 0 16 (builtins.hashString "sha256"
    (builtins.unsafeDiscardStringContext "agent-project-v1 ${getEnv "AGENT_PROJECT_BASE_IMAGE"} ${baseImage.drvPath} ${shell.drvPath}"));
  image = import ./. {
    inherit inputs system pkgs;
    project = {
      ref = getEnv "AGENT_PROJECT_IMAGE";
      env = builtins.storePath (getEnv "AGENT_PROJECT_ENV");
      # print-dev-env sets $out (and other outputs) to ./outputs/<name> in
      # the directory it ran in (the script's); use the sandbox's workspace,
      # as `nix develop` run there would.
      script =
        let scriptFile = absolutePath "AGENT_PROJECT_ENV_SCRIPT"; in
        builtins.replaceStrings
          [ "='${dirOf (toString scriptFile)}/outputs/" ] [ "='/workspace/outputs/" ]
          (builtins.readFile scriptFile);
    };
  };
}
