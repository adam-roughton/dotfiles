{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      spotify slack vlc libreoffice
      sxiv qiv obsidian
      google-chrome zoom-us
    ];
  };
}
