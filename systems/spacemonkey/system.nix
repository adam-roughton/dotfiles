{ pkgs, lib, ... }:

let
  sources = import ../../nix/sources.nix;
  user = import ../../user.nix;
  username = "adamr";
  home = "/home/${username}";
in
{
  imports = lib.optional (
    builtins.pathExists ../../private/systems/spacemonkey/system.nix
  ) (
    args: import ../../private/systems/spacemonkey/system.nix (args // { inherit home pkgs lib; })
  );
  
  environment.systemPackages = with pkgs; [
    git vim qemu memtest86plus
  ];

  time.timeZone = "Pacific/Auckland";

  networking = {
    hostName = "spacemonkey";
    dhcpcd.enable = false;
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 spacemonkey
      10.255.192.164 rpi3
      10.255.192.112 mac
    '';
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };
  
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
  boot.loader.grub.memtest86.enable = true;

  nix = {
    trustedUsers = [ "root" username ];
    autoOptimiseStore = true;
    maxJobs = 2;
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

  system.stateVersion = "21.05";

}
