{ pkgs, ... }:
{
  config = {
    home.packages = with pkgs; [
      fzf
      (vim-full.customize {
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
          customRC = (builtins.readFile ./vimrc);
        };
      })
    ];
  };
}
