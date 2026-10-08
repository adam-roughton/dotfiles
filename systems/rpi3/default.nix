{ inputs }:
import ../nixos-system.nix {
  inherit inputs;
  system = "aarch64-linux";
  overlay = ./overlay.nix;
  homeUser = "adam";
  homeModule = ./home.nix;
  modules = [
    ./system.nix
    ./hardware.nix
  ];
}
