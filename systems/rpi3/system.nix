{ pkgs, ... }:

let
  sources = import ../../nix/sources.nix;
  user = import ../../user.nix;
  util = pkgs.callPackage ../../util.nix {};
  username = "adam";
in
{
  time.timeZone = "Pacific/Auckland";

  environment.systemPackages = with pkgs; [
    libraspberrypi vim
  ];

  networking = {
    hostName = "rpi3";
    wireless = {
      enable = true;
      interfaces = ["wlan0"];
      networks."Roughton (5GHz)".pskRaw = util.readSecret "roughton_psk_raw";
    };
    dhcpcd.enable = true;
    extraHosts = ''
      127.0.0.1 rpi3
      10.255.192.193 spacemonkey
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

  # Preserve space by sacrificing documentation and history
  documentation.nixos.enable = false;
  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 5d";
  boot.cleanTmpDir = true;

  services.openssh.enable = true;

  nix = {
    trustedUsers = [ "root" username ];
    autoOptimiseStore = true;
    maxJobs = 2;
    nixPath = [
      "nixpkgs=${pkgs.path}"
    ];
    daemonNiceLevel = 19;
  };

  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
  };

  users.extraUsers."${username}" = {
    home = "/home/${username}";
    hashedPassword = util.readSecret "rpi3/hashedPassword";
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "networkmanager" "input" "audio" "video" ];
    shell = "${pkgs.zsh}/bin/zsh";
  };
  services.mingetty = {
    autologinUser = "${username}";
  };
  home-manager.users."${username}" = args: import ./home.nix (args // { inherit pkgs user; });
}
