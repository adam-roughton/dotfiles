{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ubuntu_font_family hack-font
  ];

  home.file.".config/fontconfig/fonts.conf".source = ./fonts.conf;

}
