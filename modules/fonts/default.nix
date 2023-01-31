{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ubuntu_font_family hack-font source-code-pro
  ];

  home.file.".config/fontconfig/fonts.conf".source = ./fonts.conf;

}
