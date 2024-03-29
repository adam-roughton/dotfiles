{ config, pkgs, ... }:

let
  sources = import ../../nix/sources.nix;
in
{
  boot.loader.grub.enable = false;

  # A bunch of boot parameters needed for optimal runtime on RPi 3b+
  boot.kernelParams = [
    "console=tty0" 
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  
  boot.initrd.availableKernelModules = [
    "vc4" "bcm2835_dma" "i2c_bcm2835" "bcm2835_rng"
  ];


  boot.loader.raspberryPi.enable = true;
  boot.loader.raspberryPi.version = 3;
  boot.loader.raspberryPi.uboot = {
    enable = true;
    configurationLimit = 2;
  };

  boot.loader.raspberryPi.firmwareConfig = ''
  avoid_warnings=1
  kernel=u-boot-rpi3.bin
  arm_64bit=1
  enable_uart=0
  force_turbo=1
  dtparam=i2c1=on
  dtparam=i2c_arm=on
  start_x=1
  dtparam=audio=on
  dtoverlay=vc4-kms-v3d  
  '';
  hardware.enableRedistributableFirmware = true;

  hardware.firmware = with pkgs; [
     wireless-regdb
     raspberrypiWirelessFirmware
  ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };
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
    support32Bit = true;
  };
  system.stateVersion = "22.05";
}
