{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ubuntu-classic hack-font source-code-pro
  ];

  home.file.".config/fontconfig/fonts.conf".source = ./fonts.conf;

}
