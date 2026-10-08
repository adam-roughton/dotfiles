# The microsandbox agent image for `system`. This is a script that writes the
# image to stdout as an uncompressed tar (which is what `msb load` expects).
# Unlike buildLayeredImage it does not keep a full copy of the image in the
# Nix store.
{ inputs, system }:
let
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
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
in
pkgs.dockerTools.streamLayeredImage {
  name = "dotfiles-agent";
  tag = "latest";
  contents = [ contents ];
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
