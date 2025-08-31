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
    ../../private/systems/superposition/home.nix 
  ];

  programs.zsh.enable = true;

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

  home.sessionVariables = {
    DOCKER_HOST="unix://${home.homeDirectory}/.colima/default/docker.sock";
  };

  home.file.".odbc/odbcinst.ini".text = 
    let
      iniDescription = pkg: ''
        [${pkg.fancyName}]
        Description = ${pkg.meta.description}
        Driver = ${pkg}/${pkg.driver}
      '';
    in lib.concatMapStringsSep "\n" iniDescription (with pkgs; [ unixODBCDrivers.msodbcsql18 ]);

  programs.home-manager.enable = true;
}
