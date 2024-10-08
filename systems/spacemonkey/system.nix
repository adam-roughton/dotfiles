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
    git vim qemu 
  ];
  boot.loader.systemd-boot.memtest86.enable = true;

  time.timeZone = "Pacific/Auckland";

  networking = {
    hostName = "spacemonkey";
    dhcpcd.enable = false;
    networkmanager.enable = true;
    extraHosts = ''
      127.0.0.1 spacemonkey
      192.168.15.105 rpi3
      192.168.15.175 mac
      192.168.15.16 skyhook
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

  nix = {
    settings = {
      trusted-users = [ "root" username ];
      auto-optimise-store = true;
      max-jobs = 2;
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
    desktopManager.xterm.enable = true;
    displayManager = {
      lightdm = {
        enable = true;
        greeter.enable = false;
      };
    };
    xkbOptions = "caps:escape";
  };
  services.displayManager.autoLogin = {
    enable = true;
    user = "${username}";
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
