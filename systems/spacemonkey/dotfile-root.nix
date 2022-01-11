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
      /etc/nixos/hardware-configuration.nix
    ];

    nixpkgs.config.allowBroken = true;
    nixpkgs.config.allowUnfree = true;
  };
  
  extra = { nixos, ... }: {
    vm = (nixos { inherit system configuration; } // {
      virtualisation.memorySize = "2G";
      virtualisation.cores = 2;
    }).vm;
  };
}
