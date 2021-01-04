{ pkgs, ... }:
rec {
  wiringpi = pkgs.callPackage ./wiringpi.nix {};

  matrixio-xc3sprog = pkgs.callPackage ./matrixio-xc3sprog.nix { inherit wiringpi; };

  matrix-creator-hal = pkgs.callPackage ./matrix-creator-hal.nix { inherit wiringpi; };

  matrix-creator-init = pkgs.callPackage ./matrix-creator-init.nix { inherit wiringpi matrixio-xc3sprog matrix-creator-hal; };
}
