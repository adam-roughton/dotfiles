{ config, pkgs, ... }:
{
  imports = [
    ./firmware.nix
  ];
  sdImage = {
    populateFirmwareCommands = ''
      mkdir firmware
      cp ${system.build.firmware}/* firmware
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      cp ${system.build.boot}/* ./files/boot
    '';
  };
}
