{ user, pkgs, lib, ... }:
{
  imports = [ 
    ../../modules/shell
    ../../modules/vim
    ../../modules/fonts
  ];
  
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    sshKeys = [ user.gpgSshKeygrip.rpi3 ];
    extraConfig = ''
      pinentry-program ${pkgs.pinentry}/bin/pinentry
    '';
  };
  
  manual.manpages.enable = true;
  news.display = "silent";

  # Force home-manager to use pinned nixpkgs
  _module.args.pkgs = pkgs.lib.mkForce pkgs;

}
