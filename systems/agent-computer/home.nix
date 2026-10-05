{ pkgs, ... }:
{
  imports = [
    ../../modules/shell
    ../../modules/vim
    ../../modules/dev.nix
  ];

  home.username = "root";
  home.homeDirectory = "/root";
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    opencode
    pi-coding-agent
  ];

  home.file."AGENTS.md".source = ./AGENTS.md;

  programs.zsh.enable = true;
  programs.bash.enable = true;
}
