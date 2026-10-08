# Raspberry Pi firmware partition: GPU boot code, device trees and overlays,
# U-Boot, and config.txt. The SD image (`make.sh disk-image rpi3`) and
# `make.sh firmware rpi3` both use the nixos-hardware install script, so they
# write identical files.
{ config, lib, pkgs, ... }:
{
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # Merged with the nixos-hardware defaults (which already enable the
  # vc4-kms-v3d overlay, kernel=u-boot.bin and arm_64bit). Rendered as
  # config.txt; booleans become 1/0.
  hardware.raspberry-pi.configtxt.settings.all = {
    avoid_warnings = true;
    force_turbo = true;
    start_x = true;
    # Replaces the default list, so audio=on is repeated here.
    dtparam = [ "audio=on" "i2c_arm=on" "i2c1=on" ];
    # enable_uart stays at the nixos-hardware default (1): U-Boot on the Pi 3
    # needs the UART enabled to boot, whether or not it is used.
  };

  system.build.firmware = pkgs.runCommand "rpi3-firmware" { } ''
    mkdir firmware
    ${config.sdImage.populateFirmwareCommands}
    cp -r firmware $out
  '';
}
