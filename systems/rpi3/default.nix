{ inputs }:
import ../nixos-system.nix {
  inherit inputs;
  name = "rpi3";
  system = "aarch64-linux";
  overlay = ./overlay.nix;
  homeUser = "adam";
  homeModule = ./home.nix;
  # The SD card layout (sd-image.nix via hardware.nix) defines the filesystems.
  hardwareConfiguration = null;
  modules = [
    ./system.nix
    ./hardware.nix
    ./firmware.nix
  ];
}
