{ pkgs, lib, ... }:
let
  # One headless JDK shared by every JVM tool. Each tool otherwise wraps its own full
  # (GTK/X11) JDK, so the image would carry several JDKs.
  jdk = pkgs.jdk17_headless;
in {
  imports = [
    ../../modules/shell
    ../../modules/vim
  ];

  home.username = "root";
  home.homeDirectory = "/root";
  home.stateVersion = "25.05";

  # Same zsh configuration as the workstations, without the workstation-only tools.
  dotfiles.shell.workstation = false;

  # vim-full defaults to a GTK3 GUI with X11/Wayland and Ruby support on Linux.
  dotfiles.vim.package = pkgs.vim-full.override {
    guiSupport = "none";
    waylandSupport = false;
    rubySupport = false;
  };

  # The image only receives packages and dotfiles; the Home Manager manual page is not
  # in the binary cache and would be built (with its doc toolchain) on every update.
  manual.manpages.enable = false;

  # Commit as the host user, but without host-only credentials: there is no GPG key in
  # the sandbox, and rewriting GitHub HTTPS URLs to SSH would break clones.
  programs.git = {
    signing.signByDefault = lib.mkForce false;
    settings.url = lib.mkForce { };
  };

  programs.java = {
    enable = true;
    package = jdk;
  };

  home.packages = with pkgs; [
    # agents
    opencode
    pi-coding-agent

    # base userland (the image has no OS underneath Home Manager's packages)
    coreutils gnugrep gnused gawk diffutils patch
    gnutar gzip xz bzip2 less which

    # c
    gcc gnumake

    # python
    python3 uv

    # node
    nodejs

    # rust
    rustc cargo rustfmt

    # jvm / scala
    (gradle.override { java = jdk; })
    (sbt.override { jre = jdk; })
    (scala.override { jre = jdk; })

    # sh
    shellcheck

    # config / data
    jsonnet

    # database clients
    postgresql
    mariadb.client

    # cloud
    awscli2
    azure-cli

    # kubernetes
    kubectl
    kubelogin
    aws-iam-authenticator
    kubetail
  ];

  home.file."AGENTS.md".source = ./AGENTS.md;

  programs.zsh.enable = true;
  programs.bash.enable = true;
}
