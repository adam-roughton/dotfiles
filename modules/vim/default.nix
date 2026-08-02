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
              vim-gitgutter
              vim-easymotion
              undotree
              fzf-wrapper
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
