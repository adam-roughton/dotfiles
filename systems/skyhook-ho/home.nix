{ pkgs, lib, system, ... }@args:
let 
  user = import ../../user.nix;
in
{
  imports = [ 
    ../../modules/shell
    ../../modules/vim
    ../../modules/fonts
    ../../modules/apps.nix
    ../../modules/dev.nix
    ../../modules/vscode
    ../../private/systems/skyhook-ho/home.nix 
  ];

  home.packages = with pkgs; [
    gparted
    (runCommand "scripts" { src = ./scripts; } ''
      mkdir -p $out/bin
      cp $src/* $out/bin
      chmod +x $out/bin/*
    '')
    hplip
  ];
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    sshKeys = [ user.gpgSshKeygrip.skyhook ];
    pinentry.package = pkgs.pinentry-gnome3;
  };
  
  manual.manpages.enable = true;
  news.display = "silent";

  home.username = "adamr";
  home.homeDirectory = "/home/adamr";
  home.stateVersion = "22.05";

  home.file.".odbc/odbcinst.ini".text = 
    let
      iniDescription = pkg: ''
        [${pkg.fancyName}]
        Description = ${pkg.meta.description}
        Driver = ${pkg}/${pkg.driver}
      '';
    in lib.concatMapStringsSep "\n" iniDescription (with pkgs; [ unixODBCDrivers.msodbcsql18 ]);

  # Work with Ubuntu
  targets.genericLinux.enable = true;
  
  programs.home-manager.enable = true;
}
