{ pkgs, ... }:
{
  config = {
    programs.vscode = with pkgs; {
      enable = true;
      package = vscodium;
      extensions = with vscode-extensions; [
        vscodevim.vim
        ms-python.python
        github.copilot
        ms-toolsai.jupyter
      ];
    };
  };
}
