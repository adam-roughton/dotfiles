{ config, pkgs, ... }:

let
  sources = import ../../nix/sources.nix;
  configTxt = ''
    avoid_warnings=1
    kernel=u-boot-rpi3.bin
    arm_64bit=1
    gpu_mem=256
    start_x=1
    dtparam=audio=on
    dtparam=i2c1=on
    dtparam=i2c_arm=on
  '';
in
{
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # A bunch of boot parameters needed for optimal runtime on RPi 3b+
  boot.kernelParams = [
    "console=ttyAMA0,115200n8" 
    "console=tty0"
  ];
  
  boot.initrd.availableKernelModules = [
    "vc4" "bcm2835_dma" "i2c_bcm2835"
  ];


  boot.loader.raspberryPi.enable = true;
  boot.loader.raspberryPi.version = 3;
  boot.loader.raspberryPi.uboot = {
    enable = true;
    configurationLimit = 2;
  };
  
  boot.loader.raspberryPi.firmwareConfig = configTxt;
  hardware.enableRedistributableFirmware = true;

  # Used when generating a custom SD image for initial installation
  sdImage = {
    populateFirmwareCommands = let
      configTxtFile = pkgs.writeText "config.txt" configTxt;
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

  # Use 1GB of additional swap memory in order to not run out of memory
  # when installing lots of things while running other things at the same time.
  swapDevices = [ { device = "/swapfile"; size = 1024; } ];

  systemd.services.btattach = {
    before = [ "bluetooth.service" ];
    after = [ "dev-ttyAMA0.device" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bluez}/bin/btattach -B /dev/ttyAMA0 -P bcm -S 3000000";
    };
  };
  hardware.bluetooth.enable = true;

  sound.enable = true;
  hardware.pulseaudio = {
    enable = true;
    package = pkgs.pulseaudioFull;
  };
}
