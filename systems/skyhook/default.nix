{ inputs }:
import ../nixos-system.nix {
  inherit inputs;
  name = "skyhook";
  system = "x86_64-linux";
  overlay = ./overlay.nix;
  homeUser = "adamr";
  homeModule = ./home.nix;
  # Generated on the machine; see systems/nixos-system.nix.
  hardwareConfiguration = ./hardware-configuration.nix;
  modules = [
    ./system.nix
    ./hardware.nix
  ];
}
