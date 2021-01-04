{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ubuntu_font_family fira-code 
  ];

  home.file.".config/fontconfig/fonts.conf".source = ./fonts.conf;

}
