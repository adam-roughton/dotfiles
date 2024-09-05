{ config, lib, pkgs, ... }:

let
sources = import ../../nix/sources.nix;
in
{
  imports = [
    "${sources.nixos-hardware}/lenovo/thinkpad"
    "${sources.nixos-hardware}/lenovo/thinkpad/p1"
    "${sources.nixos-hardware}/common/gpu/nvidia/prime.nix"
  ];
  
  hardware.nvidia.modesetting.enable = true;
  hardware.nvidia.powerManagement.enable = true;
  hardware.nvidia.powerManagement.finegrained = true;
  hardware.graphics.enable32Bit = true;
  hardware.graphics.enable = true;

  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.latest;
  hardware.nvidia.prime = {
    offload.enable = true;

    # Bus ID of the Intel GPU.
    intelBusId = lib.mkDefault "PCI:0:2:0";
    # Bus ID of the NVIDIA GPU.
    nvidiaBusId = lib.mkDefault "PCI:1:0:0";
  };

  # Add boot option for using nvidia to power an external display
  specialisation = {
    external-display.configuration = {
      system.nixos.tags = [ "external-display" ];
      hardware.nvidia.prime.offload.enable = lib.mkForce false;
      hardware.nvidia.powerManagement.enable = lib.mkForce false;
      hardware.nvidia.powerManagement.finegrained = lib.mkForce false;
    };
  };

  services.fprintd.enable = true;
  
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.cpu.intel.updateMicrocode = true;
  boot.kernelModules = [ "kvm-intel" ];
  boot.kernelParams = [
    "msr.allow_writes=on"
    "acpi_backlight=native"
  ];
  boot.blacklistedKernelModules = [
    "nouveau"
  ];

  services.tlp.settings = {
    # powersave enables intel's p-state driver
    CPU_SCALING_GOVERNOR_ON_AC = "performance";
    CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

    # https://linrunner.de/en/tlp/docs/tlp-faq.html#battery
    # use "tlp fullcharge" to override temporarily
    START_CHARGE_THRESH_BAT0 = 85;
    STOP_CHARGE_THRESH_BAT0 = 90;
    START_CHARGE_THRESH_BAT1 = 85;
    STOP_CHARGE_THRESH_BAT1 = 90;
  };
  services.throttled.enable = true;
  services.libinput = {
    enable = true;
    touchpad = {
      scrollMethod = "twofinger";
      tapping = false;
      naturalScrolling = true;
    };
  };

  services.printing = {
    enable = true;
    drivers = [ pkgs.gutenprint pkgs.gutenprintBin ];
    browsing = true;
  };

  hardware.bluetooth.enable = true;

  hardware.pulseaudio = {
    enable = true;
    package = pkgs.pulseaudioFull;
  };
}
