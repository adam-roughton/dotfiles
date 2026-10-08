{ pkgs, lib, system, ... }@args:
let 
  user = import ../../user.nix;
in rec{
  imports = [ 
    ../../modules/shell
    ../../modules/vim
    ../../modules/fonts
    ../../modules/dev.nix
    ../../modules/vscode
    ../../modules/agent-sandbox
  ] ++ lib.optional (builtins.pathExists ../../private/systems/superposition/home.nix)
    ../../private/systems/superposition/home.nix;

  programs.zsh = {
    enable = true;
    initContent = ''
    export DOCKER_HOST="unix://${home.homeDirectory}/.colima/default/docker.sock";
    export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
    '';
  };

  home.packages = with pkgs; [
    (runCommand "scripts" { src = ./scripts; } ''
      mkdir -p $out/bin
      cp $src/* $out/bin
      chmod +x $out/bin/*
    '')
  ];
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    sshKeys = [ user.gpgSshKeygrip.superposition ];
    pinentry.package = pkgs.pinentry_mac;
  };
  
  manual.manpages.enable = true;
  news.display = "silent";

  home.username = "Adam.Roughton";
  home.homeDirectory = "/Users/Adam.Roughton";
  home.stateVersion = "25.05";

  home.file.".odbc/odbcinst.ini".text = 
    let
      iniDescription = pkg: ''
        [${pkg.fancyName}]
        Description = ${pkg.meta.description}
        Driver = ${pkg}/${pkg.driver}
      '';
    in lib.concatMapStringsSep "\n" iniDescription (with pkgs; [ unixodbcDrivers.msodbcsql18 ]);

  programs.home-manager.enable = true;
  
  dotfiles.agentSandbox = {
    enabled = true;
    copilotTokenFile = "${home.homeDirectory}/development/agent/credentials/github-copilot-token";
  };


}
