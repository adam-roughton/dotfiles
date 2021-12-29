{ config, pkgs, ... }:
let
  configTxtFile = pkgs.writeText "config.txt" config.boot.loader.raspberryPi.firmwareConfig;
in {
  system.build.firmware = pkgs.runCommand "firmware" {} ''
    mkdir $out
    (cd ${pkgs.raspberrypifw}/share/raspberrypi/boot && cp bootcode.bin fixup*.dat start*.elf $out)
    cp ${configTxtFile} $out/config.txt
    cp ${pkgs.ubootRaspberryPi3_64bit}/u-boot.bin $out/u-boot-rpi3.bin
  '';

  system.build.boot = pkgs.runCommand "boot" {} ''
    mkdir $out
    ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d $out
  '';
}
