{ pkgs, lib, ... }:

let
  sources = import ../../nix/sources.nix;
  user = import ../../user.nix;
  util = pkgs.callPackage ../../util.nix {};
  username = "adam";
  home = "/home/${username}";
in
{
  imports = lib.optional (
    builtins.pathExists ../../private/systems/rpi3/system.nix
  ) (
    args: import ../../private/systems/rpi3/system.nix (args // { inherit home pkgs lib; })
  );

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

  # Preserve space by sacrificing documentation and history
  documentation.nixos.enable = false;
  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 5d";
  boot.cleanTmpDir = true;

  services.openssh.enable = true;

  nix = {
    settings = {
      trusted-users = [ "root" username ];
      max-jobs = 2;  
      auto-optimise-store = true;
    };
    nixPath = [
      "nixpkgs=${pkgs.path}"
    ];
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
  };

  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
  };

  programs.zsh.enable = true;

  users.extraUsers."${username}" = {
    home = "/home/${username}";
    hashedPassword = util.readSecret "rpi3/hashedPassword";
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "networkmanager" "input" "audio" "video" "bluetooth" ];
    shell = "${pkgs.zsh}/bin/zsh";
  };
  services.getty = {
    autologinUser = "${username}";
  };
  home-manager.users."${username}" = args: import ./home.nix (args // { inherit pkgs user; });

  security.pam.loginLimits = [
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@audio"; item = "nofile"; type = "soft"; value = "99999"; }
    { domain = "@audio"; item = "nofile"; type = "hard"; value = "99999"; }
    { domain = "@pulse-rt"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@pulse-rt"; item = "nice"; type = "-"; value = "-20"; }
  ];
}
