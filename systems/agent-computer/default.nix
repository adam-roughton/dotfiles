# The microsandbox agent image for `system`. This is a script that writes the
# image to stdout as an uncompressed tar (which is what `msb load` expects).
# Unlike buildLayeredImage it does not keep a full copy of the image in the
# Nix store.
#
# `project` adds a project's development environment (see project.nix):
#   ref    image reference written into the archive (msb load registers it)
#   env    `nix print-dev-env --profile` store path; its closure is the
#          environment's packages
#   script the `nix print-dev-env` output, sourced by code-agent on attach
{
  inputs,
  system,
  pkgs ? import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  },
  project ? null,
}:
let
  inherit (pkgs) lib;
  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ ./home.nix ];
  };
  contents = pkgs.buildEnv {
    name = "dotfiles-agent-image-contents";
    # msb passes the host's TERM through, and ncurses' own database lacks
    # xterm-kitty, so ship kitty's terminfo entry.
    paths = [ pkgs.bashInteractive pkgs.zsh pkgs.kitty.terminfo ] ++ home.config.home.packages;
    pathsToLink = [ "/bin" "/sbin" "/lib" "/share" ];
  };
  projectRef = lib.match "(.+):([^:/]+)" project.ref;
  projectScript = pkgs.writeText "agent-project-env.sh" project.script;
in
assert project == null || projectRef != null
  || throw "project image reference must be NAME:TAG, not ${project.ref}";
pkgs.dockerTools.streamLayeredImage {
  name = if project == null then "dotfiles-agent" else lib.elemAt projectRef 0;
  tag = if project == null then "latest" else lib.elemAt projectRef 1;
  contents = [ contents ];
  # One layer per store path: with more layers allowed than there are store
  # paths, dockerTools gives every path its own layer. msb stores layers once
  # by content, and a store path's layer is identical in every image, so
  # project images share all of the base image's layers and only add their
  # own packages. (With the default limit of 100 the remaining paths are
  # grouped, and those groups change whenever the closure does.) msb merges
  # the layers into one filesystem, so Docker's 127-layer limit does not
  # apply.
  maxLayers = 10000;
  # Install the Home Manager dotfiles (store symlinks, as Home Manager itself
  # would) and the profile they refer to, so the shell matches the
  # workstations. Activation hooks are not run. dockerTools does not provide
  # account databases, so create the sandbox user's NSS entries explicitly.
  extraCommands = ''
    mkdir -p etc home/adamr workspace
    printf 'root:x:0:0:root:/root:${pkgs.zsh}/bin/zsh\nadamr:x:1000:1000:Adam Roughton:/home/adamr:${pkgs.zsh}/bin/zsh\n' > etc/passwd
    printf 'root:x:0:\nadamr:x:1000:\n' > etc/group
    cp ${./AGENTS.md} AGENTS.md
    cp -rP ${home.config.home-files}/. home/adamr/
    chmod -R u+w home/adamr
    ln -s ${home.config.home.path} home/adamr/.nix-profile
  '' + lib.optionalString (project != null) ''
    # code-agent sources env.sh before starting the agent. The profile link
    # puts the environment's closure into the image.
    mkdir -p etc/agent-project
    cp ${projectScript} etc/agent-project/env.sh
    ln -s ${project.env} etc/agent-project/profile
  '';
  # extraCommands runs as the unprivileged build user, so ownership changes
  # must happen under fakeroot, which also records them in the layer tarball.
  fakeRootCommands = ''
    chown -R 1000:1000 home/adamr workspace
  '';
  config = {
    Cmd = [ "${pkgs.zsh}/bin/zsh" ];
    Env = [
      "HOME=/home/adamr"
      "PATH=/bin:/sbin"
      "SHELL=${pkgs.zsh}/bin/zsh"
      # The trailing empty entry keeps ncurses' built-in database as a fallback.
      "TERMINFO_DIRS=/share/terminfo:"
      "USER=adamr"
    ];
    User = "1000:1000";
    WorkingDir = "/workspace";
  };
}
