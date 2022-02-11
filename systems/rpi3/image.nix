{ config, pkgs, ... }:
{
  imports = [
    ./firmware.nix
  ];
  sdImage = with config; {
    populateFirmwareCommands = ''
      cp ${system.build.firmware}/* firmware
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot
      cp -r ${system.build.boot}/* ./files/boot
    '';
  };
}
