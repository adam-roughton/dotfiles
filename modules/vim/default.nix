{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.vim;
in {
  options.dotfiles.vim.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.vim-full;
    defaultText = lib.literalExpression "pkgs.vim-full";
    description = ''
      Customizable vim package (one that provides `.customize`, such as an override of
      `pkgs.vim-full`) that the plugins and vimrc are applied to.
    '';
  };

  config = {
    home.packages = with pkgs; [
      fzf
      (cfg.package.customize {
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
