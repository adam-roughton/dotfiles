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
    paths = [ pkgs.bashInteractive pkgs.zsh ] ++ home.config.home.packages;
    pathsToLink = [ "/bin" "/sbin" "/lib" "/share" ];
  };
in
pkgs.dockerTools.streamLayeredImage {
  name = "dotfiles-agent";
  tag = "latest";
  contents = [ contents ];
  # Install the Home Manager dotfiles (store symlinks, as Home Manager itself
  # would) and the profile they refer to, so the shell matches the
  # workstations. Activation hooks are not run.
  extraCommands = ''
    mkdir -p root workspace
    cp ${./AGENTS.md} AGENTS.md
    cp -rP ${home.config.home-files}/. root/
    chmod -R u+w root
    ln -s ${home.config.home.path} root/.nix-profile
  '';
  config = {
    Cmd = [ "${pkgs.zsh}/bin/zsh" ];
    Env = [
      "HOME=/root"
      "PATH=/bin:/sbin"
      "SHELL=${pkgs.zsh}/bin/zsh"
      "USER=root"
    ];
    WorkingDir = "/workspace";
  };
}
