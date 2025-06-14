{ user, pkgs, lib, ... }:
{
  imports = [ 
    ../../modules/shell
    ../../modules/vim
    ../../modules/fonts
    ../../modules/linux/i3-desktop
    ../../modules/linux/apps.nix
    ../../modules/linux/shell.nix
    ../../modules/qutebrowser
    ../../modules/apps.nix
    ../../modules/dev.nix
    ../../modules/vscode
  ] ++ lib.optional (builtins.pathExists ../../private) ../../private/systems/skyhook/home.nix;

  home.packages = with pkgs; [
    gparted
    (runCommand "scripts" { src = ./scripts; } ''
      mkdir -p $out/bin
      cp $src/* $out/bin
      chmod +x $out/bin/*
    '')
    hplip
  ];

  home.file.".config/mimeapps.list".text = 
  ''
  [Default Applications]
  x-scheme-handler/http=org.qutebrowser.qutebrowser.desktop
  x-scheme-handler/https=org.qutebrowser.qutebrowser.desktop
  x-scheme-handler/ftp=org.qutebrowser.qutebrowser.desktop
  x-scheme-handler/chrome=org.qutebrowser.qutebrowser.desktop
  text/html=org.qutebrowser.qutebrowser.desktop
  application/x-extension-htm=org.qutebrowser.qutebrowser.desktop
  application/x-extension-html=org.qutebrowser.qutebrowser.desktop
  application/x-extension-shtml=org.qutebrowser.qutebrowser.desktop
  application/xhtml+xml=org.qutebrowser.qutebrowser.desktop
  application/x-extension-xhtml=org.qutebrowser.qutebrowser.desktop
  application/x-extension-xht=org.qutebrowser.qutebrowser.desktop
  application/pdf=userapp-zathura-MQERZZ.desktop;

  [Added Associations]
  application/pdf=userapp-zathura-MQERZZ.desktop;
  '';

  systemd.user.services.battery-notification =
    let p = pkgs.runCommand "battery-notification" {
      buildInputs = [ pkgs.makeWrapper pkgs.coreutils ];
    } ''
      mkdir -p $out/bin
      makeWrapper ${./scripts/battery-notification.sh} $out/bin/battery-notification.sh \
        --prefix PATH : "${pkgs.acpi}/bin:${pkgs.libnotify}/bin:${pkgs.bash}/bin:${pkgs.gnugrep}/bin"
    '';
    in {
      Unit = {
        Description = "Sends a notification on low battery.";
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${p}/bin/battery-notification.sh";
      };
    };
  systemd.user.timers.battery-notification = {
    Timer = {
      OnCalendar = "minutely";
      Unit = "battery-notification.service";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
  
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    sshKeys = [ user.gpgSshKeygrip.skyhook ];
    pinentry.package = pkgs.pinentry-gnome3;
  };
  
  manual.manpages.enable = true;
  news.display = "silent";

  home.stateVersion = "22.05";

  # Force home-manager to use pinned nixpkgs
  _module.args.pkgs = pkgs.lib.mkForce pkgs;
}
