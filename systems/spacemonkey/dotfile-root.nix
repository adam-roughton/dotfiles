let
  sources = import ../../nix/sources.nix;
in
{
  system = "x86_64-linux";
  
  config = {

    imports = [
      ./system.nix
      ./hardware.nix
      "${sources.home-manager}/nixos"
      /etc/nixos/hardware-configuration.nix
    ];

    nixpkgs.config.allowBroken = true;
    nixpkgs.config.allowUnfree = true;
  };
  
  extra = { config, pkgs, nixos, ... }: {
    vm = (nixos // {
      virtualisation.memorySize = "2G";
      virtualisation.cores = 2;
    }).vm;
  };
}
