{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      spotify slack vlc libreoffice
      sxiv qiv
      google-chrome obsidian
    ];
  };
}
