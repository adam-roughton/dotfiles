let 
  sources = import ../../nix/sources.nix;
in rec {
  system = "aarch64-linux";
  crossSystem = "aarch64-unknown-linux-gnu";

  configuration = {
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
  
  extra = { nixos, ... }: {

    vm = (nixos rec { inherit system configuration; } // {
      virtualisation.memorySize = "900M";
      virtualisation.cores = 1;
    }).config.vm;

    diskImage = (nixos {
      inherit system;
      configuration = (configuration // {
        imports = [
          "${sources.nixpkgs}/nixos/modules/installer/scan/detected.nix"
          "${sources.nixpkgs}/nixos/modules/installer/scan/not-detected.nix"
          "${sources.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
          "${sources.nixpkgs}/nixos/modules/installer/sd-card/sd-image.nix"
          ./image.nix
        ];
      });
    }).config.system.build.sdImage;

    firmware = (nixos {
      inherit system;
      configuration = (configuration // {
        imports = [
          ./firmware.nix
        ];
      });
    }).config.system.build.firmware;
     
  };

}
