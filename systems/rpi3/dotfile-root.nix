let 
  sources = import ../../nix/sources.nix;
in
{
  system = "aarch64-linux";

  config = {
    require = [
      ./system.nix
      ./hardware.nix
      "${sources.home-manager}/nixos"
    ];

    nixpkgs.overlays = [
      (import ./overlay.nix)
    ];

    nixpkgs.config.allowBroken = true;
    nixpkgs.config.allowUnfree = true;
  };
  
  extra = { config, pkgs, ... }: rec {

    vm = ((pkgs.nixos config) // {
      virtualisation.memorySize = "900M";
      virtualisation.cores = 1;
    }).config.vm;
    
    diskImage = (pkgs.nixos ({
      imports = [
        "${sources.nixpkgs}/nixos/modules/installer/scan/detected.nix"
        "${sources.nixpkgs}/nixos/modules/installer/scan/not-detected.nix"
        "${sources.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
        "${sources.nixpkgs}/nixos/modules/installer/cd-dvd/sd-image.nix"
      ];
    } // config)).config.system.build.sdImage;
  };

}
