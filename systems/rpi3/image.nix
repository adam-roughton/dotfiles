{ config, pkgs, ... }:
{
  sdImage = {
    populateFirmwareCommands = let
      configTxtFile = pkgs.writeText "config.txt" config.boot.loader.raspberryPi.firmwareConfig;
    in
      ''
      (cd ${pkgs.raspberrypifw}/share/raspberrypi/boot && cp bootcode.bin fixup*.dat start*.elf $NIX_BUILD_TOP/firmware/)
      cp ${configTxtFile} firmware/config.txt
      cp ${pkgs.ubootRaspberryPi3_64bit}/u-boot.bin firmware/u-boot-rpi3.bin
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };
}
