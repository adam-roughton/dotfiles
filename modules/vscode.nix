{ pkgs, ... }:
{
  config = {
    programs.vscode = with pkgs; {
      enable = true;
      package = vscode;
      extensions = with vscode-extensions; [
        vscodevim.vim
        ms-python.python
        ms-python.vscode-pylance
        github.copilot
        ms-toolsai.jupyter
        bungcip.better-toml
        scala-lang.scala
        golang.go 
      ] ++ vscode-utils.extensionsFromVscodeMarketplace [
        {
          name = "vscode-python-test-adapter";
          publisher = "LittleFoxTeam";
          version = "0.7.0";
          sha256 = "sha256-kgz767dp+//4Lx59JmDC9aKq89AVpfgEViQ1fq19hMs=";
        } 
        {
          name = "vscode-test-explorer";
          publisher = "hbenl";
          version = "2.21.1";
          sha256 = "sha256-fHyePd8fYPt7zPHBGiVmd8fRx+IM3/cSBCyiI/C0VAg=";
        } 
        {
          name = "test-adapter-converter";
          publisher = "ms-vscode";
          version = "0.1.5";
          sha256 = "sha256-nli4WJ96lL3JssNuwLCsthvphI7saFT2ktWQ46VNooc=";
        } 
      ];
      mutableExtensionsDir = false;
      userSettings = {
        "jupyter.askForKernelRestart" = false;
        "editor.formatOnSave" = true;
        "python.formatting.autopep8Args" = [
            "--max-line-length=120"
        ];
        "editor.minimap.enabled" = false;
        "git.autofetch" = true;
        "vim.useSystemClipboard" = true;
        "python.formatting.provider" = "black";
        "python.analysis.typeCheckingMode" = "basic";
        "python.languageServer" = "Pylance";
        "git.confirmSync" = false;
        "editor.inlineSuggest.enabled" = true;
      };
      keybindings = [
        { key = "ctrl+shift+t"; command = "testing.viewAsTree"; }
        { key = "ctrl-i"; command = "workbench.action.navigateForward"; }
        { key = "ctrl-o"; command = "workbench.action.navigateBack"; }
      ];
    };
  };
}
