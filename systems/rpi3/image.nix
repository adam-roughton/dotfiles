{ config, pkgs, ... }:
{
  imports = [
    ./firmware.nix
  ];
  sdImage = with config; {
    populateFirmwareCommands = ''
      mkdir firmware
      cp ${system.build.firmware}/* firmware
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      cp -r ${system.build.boot}/* ./files/boot
    '';
  };
}
