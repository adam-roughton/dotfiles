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

      awscli2 (pkgs.callPackage ./aws-console.nix {}) 
    
      # nix
      nix-prefetch-scripts patchelf

      (runCommand "scripts" { src = ./scripts; } ''
        mkdir -p $out/bin
        cp $src/* $out/bin
        chmod +x $out/bin/*
      '')
    ];

    programs.bash.enable = true;
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      defaultKeymap = "viins";
      history = {
        size = cfg.historySize;
        append = true;
        expireDuplicatesFirst = true;
        extended = true;
        share = true;
      };
      shellAliases = {
        "ls" = "eza";
        ".." = "cd ..";
        "..." = "cd ../..";
        "...." = "cd ../../..";
        "....." = "cd ../../../..";

        "ll" = "eza -l --git --time-style long-iso";
        "la" = "eza --all --all";
        "lla" = "eza -l --git --time-style long-iso --all --all";
        "lr" = "eza -l -snew -r --git --time-style long-iso";
        "lra" = "eza -l -snew -r --git --time-style long-iso --all --all";

        "r" = "ranger";
        "t" = "todo.sh";
        "tf" = "todo.sh list";
      } // cfg.extraAliases;
      siteFunctions = {
        tt = ''
          todo.sh list +$(date -Idate) 
        '';
        ta = ''
          todo.sh add +$(date -Idate) $1
        '';
      };
      initContent = lib.mkOrder 1500 ''
      setopt NO_FLOW_CONTROL
      setopt NO_CLOBBER

      # Keybindings
      bindkey '^[[3~' delete-char
      bindkey '^[[1;5C' forward-word
      bindkey '^[[1;5D' backward-word   

      autoload -U edit-command-line
      zle -N edit-command-line

      # vi style
      bindkey -M vicmd v edit-command-line

      unsetopt flow_control

      # Prompt
      autoload -U colors zsh/terminfo
      colors

      autoload -Uz vcs_info

      zstyle ':vcs_info:*' enable git
      zstyle ':vcs_info:*' check-for-changes true
      zstyle ':vcs_info:*' unstagedstr !
      precmd () {
          if [[ -z $(git ls-files --other --exclude-standard 2> /dev/null) ]] {
              zstyle ':vcs_info:*' formats '%F{cyan}[%b%c%u%f%F{cyan}]%f'
          } else {
              zstyle ':vcs_info:*' formats '%F{cyan}[%b%c%u%f%F{red}●%f%F{cyan}]%f'
          }
          vcs_info
      }

      nixShellPrompt () {
        case $IN_NIX_SHELL in;
          pure) NIXSH="[nix-sh(p)]";;
          impure) NIXSH="[nix-sh(i)]";;
          *) NIXSH="";;
        esac
      }

      setopt prompt_subst
      nixShellPrompt
      PS1=''\'''\${return_code}%F{magenta}%n%f@%F{yellow}%m%f%F{cyan}''${NIXSH}%F{yellow}:%B%F{green}%~%f%b ''${vcs_info_msg_0_}
      $ '
      '';
    };
    programs.direnv = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.autojump = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.password-store = {
      enable = true;
      package = pkgs.pass.withExtensions(ext: [ext.pass-otp]);
      settings = {
        PASSWORD_STORE_DIR = "${config.home.homeDirectory}/.password-store";
      };
    };

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
