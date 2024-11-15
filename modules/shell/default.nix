{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.dotfiles.shell;
  user = import ../../user.nix;
  extraAliasesStr = concatStringsSep "\n" (
    mapAttrsToList (k: v: "alias ${k}=${escapeShellArg v}") cfg.extraAliases
  );
  profileText = ''
    export NIX_PATH=nixpkgs=${pkgs.path}
    source ${./profile}
  '';
in {

  imports = [ 
    ../git.nix
  ];

  options = {
    dotfiles.shell = {
      historySize = mkOption {
        type = types.int;
        default = 10000;
      };
      extraAliases = mkOption {
        type = types.attrsOf types.str;
        default = {};
      };
    };
  };

  config = {
    home.packages = with pkgs; [ 
      zsh zsh-syntax-highlighting nix-zsh-completions
      bashmount ncdu htop zenith
      zip unzip file hexedit 

      findutils ripgrep fd tree fzf 
      autojump ranger eza gettext entr 
  
      watch pv moreutils multitail miller jq direnv dos2unix up
      
      paperkey (pass.withExtensions(ext: [ext.pass-otp])) gnupg openssl zbar 

      ascii translate-shell units tokei
      graphviz todo-txt-cli 

      cmatrix termdown 
      
      dnsutils curl wget mtr nmap w3m httpie
      rsync docker-compose 

      haskellPackages.pandoc 
      
      sqlite-interactive

      awscli (pkgs.callPackage ./aws-console.nix {}) 
    
      # nix
      nix-prefetch-scripts patchelf
      niv

      (runCommand "scripts" { src = ./scripts; } ''
        mkdir -p $out/bin
        cp $src/* $out/bin
        chmod +x $out/bin/*
      '')
    ];

    home.file.".zshrc".text = ''
      ${pkgs.any-nix-shell}/bin/any-nix-shell zsh | source /dev/stdin
      source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
      export HISTSIZE=${toString cfg.historySize}
      source ${./zshrc}
      eval "$(direnv hook zsh)"
    '';

    home.file.".aliases".text = ''
      ${pkgs.any-nix-shell}/bin/any-nix-shell zsh | source /dev/stdin
      source ${./aliases}
      ${extraAliasesStr}
    '';

    home.file.".profile" = {
      text = profileText;
      executable = true;
    };
    home.file.".zprofile" = {
      text = profileText;
      executable = true;
    };

    home.file.".todo/config".source = ./todo;

  };
}
