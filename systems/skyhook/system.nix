{ pkgs, lib, config, ... }:

let
  sources = import ../../nix/sources.nix;
  user = import ../../user.nix;
  username = "adamr";
  home = "/home/${username}";
in
{
  imports = lib.optional (
    builtins.pathExists ../../private/systems/skyhook/system.nix
  ) (
    args: import ../../private/systems/skyhook/system.nix (args // { inherit home pkgs lib; })
  );
  
  environment.systemPackages = with pkgs; [
    git vim qemu 
  ];
  boot.loader.systemd-boot.memtest86.enable = true;

  time.timeZone = "Pacific/Auckland";

  networking = {
    hostName = "skyhook";
    dhcpcd.enable = false;
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 skyhook
      192.168.15.105 rpi3
      192.168.15.175 mac
      192.168.15.37 spacemonkey
      127.0.0.1  nzherald.co.nz
      127.0.0.1  facebook.com
      127.0.0.1  stuff.co.nz
    '';
    firewall = {
      enable = true;
      checkReversePath = "loose";
      trustedInterfaces = [ "tailscale0" ];
      allowedUDPPorts = [ config.services.tailscale.port ];
      allowedTCPPorts = [ 22 ];
    };
  };
  services.tailscale.enable = true;
  services.resolved.enable = true;
  
  boot.kernel.sysctl = {
    "vm.swappiness" = 0;
    "fs.inotify.max_user_watches" = 2048000;
  };
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.cleanTmpDir = true;
  services.fwupd.enable = true;

  services.openssh.enable = true;
  services.gnome.gnome-keyring.enable = true;

  programs.zsh.enable = true;
  programs.wireshark.enable = true;
  
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  nix = {
    settings = {
      trusted-users = [ "root" username ];
      auto-optimise-store = true;
      max-jobs = 4;
    };
    nixPath = [
      "nixpkgs=${pkgs.path}"
    ];
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    autoPrune.enable = true;
    extraOptions = ''
      --default-address-pool="base=172.21.0.0/16,size=24"
      --bip 172.20.64.0/24
    '';
  };

  services.logind.lidSwitch = "ignore";

  services.xserver = {
    enable = true;
    autorun = true;
    videoDrivers = ["nvidia"];
    desktopManager.xterm.enable = true;
    displayManager = {
      lightdm = {
        enable = true;
        greeter.enable = false;
      };
      autoLogin = {
        enable = true;
        user = "${username}";
      };
    };
    xkbOptions = "caps:escape";
  };

  services.lorri.enable = true;

  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
  };

  users.extraUsers.${username} = {
    home = home;
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "networkmanager" "docker" "wireshark" ];
    shell = "${pkgs.zsh}/bin/zsh";
  };
  home-manager.users."${username}" = args: import ./home.nix (args // { inherit pkgs user; });

  services.cron.enable = true;

  system.stateVersion = "22.05";

}
