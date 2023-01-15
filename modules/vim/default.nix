{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      fzf
      (vim_configurable.customize {
        name = "vim";
        vimrcConfig = {
          packages.myplugins = with pkgs.vimPlugins; {
            start = [
              vim-nix
              vim-multiple-cursors
              gitgutter
              easymotion
              undotree
              fzfWrapper
              fzf-vim
            ];
            opt = [];
          };
         # vam.knownPlugins = vimPlugins;
         # vam.pluginDictionaries = [
         #   { names = [
         #     "vim-nix"
         #     "vim-multiple-cursors"
         #     "gitgutter"
         #     "easymotion"
         #     "undotree"
         #     "fzfWrapper"
         #     "fzf-vim"
         #   ];}
         # ];
          customRC = (builtins.readFile ./vimrc);
        };
      })
    ];
  };
}
