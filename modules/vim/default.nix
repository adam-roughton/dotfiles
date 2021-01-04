{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      fzf
      (vim_configurable.customize {
        name = "vim";
        vimrcConfig = {
          vam.knownPlugins = vimPlugins;
          vam.pluginDictionaries = [
            { names = [
              "vim-nix"
              "vim-multiple-cursors"
              "gitgutter"
              "easymotion"
              "undotree"
              "fzfWrapper"
              "fzf-vim"
            ];}
          ];
          customRC = (builtins.readFile ./vimrc);
        };
      })
    ];
  };
}
