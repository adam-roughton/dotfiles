{ config, pkgs, inputs, modulesPath, ... }:

{
  imports = [
    # Boots through the GPU firmware -> U-Boot -> extlinux
    # (generic-extlinux-compatible), and renders config.txt from
    # hardware.raspberry-pi.configtxt (see firmware.nix). Its vendor kernel is
    # only a default; boot.kernelPackages below keeps the cached mainline one.
    "${inputs.nixos-hardware}/raspberry-pi/3"
    # SD card layout: FIRMWARE (FAT) partition at /boot/firmware and the
    # NIXOS_SD ext4 root, plus system.build.sdImage for `make.sh disk-image`.
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible = {
    enable = true;
    configurationLimit = 2;
  };

  # A bunch of boot parameters needed for optimal runtime on RPi 3b+
  boot.kernelParams = [
    "console=tty0" 
  ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  
  boot.initrd.availableKernelModules = [
    "vc4" "bcm2835_dma" "i2c_bcm2835" "bcm2835_rng"
  ];


  hardware.enableRedistributableFirmware = true;

  # The Wi-Fi/Bluetooth firmware comes from the nixos-hardware module.
  hardware.firmware = with pkgs; [
     wireless-regdb
  ];

  # Filesystems ("/" on NIXOS_SD, /boot/firmware) come from sd-image.nix.

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

  hardware.pulseaudio = {
    enable = true;
    package = pkgs.pulseaudioFull;
    support32Bit = true;
  };
  system.stateVersion = "22.05";
}
