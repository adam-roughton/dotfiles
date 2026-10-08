{ inputs }:
import ../nixos-system.nix {
  inherit inputs;
  system = "x86_64-linux";
  overlay = ./overlay.nix;
  homeUser = "adamr";
  homeModule = ./home.nix;
  modules = [
    ./system.nix
    ./hardware.nix
  ];
}
