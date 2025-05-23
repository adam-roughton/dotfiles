{ pkgs, ... }:
{
  home.packages = with pkgs; [

    acpi arandr autorandr dunst feh i3 i3status inotify-tools kitty
    libnotify lxappearance maim networkmanagerapplet parcellite pasystray
    pavucontrol pcmanfm picom rofi scrot srandrd unclutter xautolock xdotool
    xfontsel xnee xorg.xbacklight xorg.xev xorg.xkill xsel xclip
    
    (runCommand "scripts" { src = ./scripts; } ''
      mkdir -p $out/bin
      cp $src/* $out/bin
      chmod +x $out/bin/*
    '')
  ];

  xsession = {
    enable = true;
    windowManager.command = "i3";
    profileExtra = ''
      eval $(${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --daemonize --components=secrets)
    '';
  };

  services.screen-locker = {
    enable = true;
    xautolock.enable = true;
    lockCmd = "${pkgs.i3lock}/bin/i3lock --color '#332233'";
    inactiveInterval = 5;
  };

  home.file.".config/i3/config".source = ./i3/config;
  home.file.".config/i3/autostart.sh".source = ./i3/autostart.sh;
  home.file.".config/i3status/config".source = ./i3/i3status;
  
  home.file.".config/picom.conf".source = ./picom.conf;
  home.file.".config/kitty/kitty.conf".source = ./kitty.conf;
    
  home.file.".config/rofi/config.rasi".source = ./rofi.rasi;
  home.file.".config/dunst/dunstrc".source = ./dunstrc;

  home.file.".config/autorandr/postswitch" = {
    source = ./autorandr-postswitch;
    executable = true;
  };
}
