let
  sources = import ../../nix/sources.nix;
in
rec {
  system = "x86_64-linux";
  
  configuration = {

    imports = [
      ./system.nix
      ./hardware.nix
      "${sources.home-manager}/nixos"
    ];

    nixpkgs.config.allowBroken = true;
    nixpkgs.config.allowUnfree = true;
    
    nixpkgs.overlays = [
      (import ./overlay.nix)
    ];
  };
  
  extra = { nixos, ... }: {
    vm = (nixos { inherit system configuration; } // {
      virtualisation.memorySize = "2G";
      virtualisation.cores = 2;
    }).vm;
    
    diskImage = (nixos {
      inherit system;
      configuration = (configuration // {
        imports = [
          "${sources.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-base.nix"
          "${sources.nixpkgs}/nixos/modules/installer/scan/detected.nix"
          "${sources.nixpkgs}/nixos/modules/installer/scan/not-detected.nix"
          "${sources.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
        ];
      });
    }).config.system.build.isoImage;
  };
}
