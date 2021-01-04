{ pkgs, ... }:

let
  sources = import ../../nix/sources.nix;
  user = import ../../user.nix;
  username = "adamr";
in
{
  environment.systemPackages = with pkgs; [
    git vim qemu
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

  programs.wireshark.enable = true;
  
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  nix = {
    trustedUsers = [ "root" username ];
    autoOptimiseStore = true;
    maxJobs = 2;
    nixPath = [
      "nixpkgs=${pkgs.path}"
    ];
    daemonNiceLevel = 19;
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
    home = "/home/${username}";
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "networkmanager" "docker" "wireshark" ];
    shell = "${pkgs.zsh}/bin/zsh";
  };
  home-manager.users."${username}" = args: import ./home.nix (args // { inherit pkgs user; });

  services.cron.enable = true;

  system.stateVersion = "20.09";

}
