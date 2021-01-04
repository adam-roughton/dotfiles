{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [ qutebrowser ];

    home.file.".config/qutebrowser/config.py".source = ./config.py;
    home.file.".config/qutebrowser/redirector.py".source = ./redirector.py;
    home.file.".config/qutebrowser/bookmarks/urls".source = ./bookmarks;
  };
}
