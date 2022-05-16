{ pkgs, ... }:
let
  jupyter = with pkgs; vscode-utils.buildVscodeMarketplaceExtension {
    mktplcRef = {
      name = "jupyter";
      publisher = "ms-toolsai";
      version = "2022.4.1021342353";
      sha256 = "EKIAWJXKddCobw8hLGUrKzhqNi+oOuBdZ5SSxxWD5Pk=";
    };

    nativeBuildInputs = [
      jq
      moreutils
    ];

    postPatch = ''
      # Patch 'packages.json' so that the expected '__metadata' field exists.
      # This works around observed extension load failure on vscode's attempt
      # to rewrite 'packages.json' with this new information.
      print_jq_query() {
          cat <<"EOF"
      .__metadata = {
        "id": "6c2f1801-1e7f-45b2-9b5c-7782f1e076e8",
        "publisherId": "ac8eb7c9-3e59-4b39-8040-f0484d8170ce",
        "publisherDisplayName": "Microsoft",
        "installedTimestamp": 0
      }
      EOF
      }
      jq "$(print_jq_query)" ./package.json | sponge ./package.json
      mkdir -p temp/jupyter/kernels
    '';

    meta = with lib; {
      description = "Jupyter extension for vscode";
      homepage = "https://github.com/microsoft/vscode-jupyter";
      license = licenses.mit;
      maintainers = with maintainers; [ jraygauthier ];
    };
  };
in
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
        jupyter
        #ms-toolsai.jupyter
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
      mutableExtensionsDir = true;
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
        "jupyter.logging.level"= "info";
      };
      keybindings = [
        { key = "ctrl+shift+t"; command = "testing.viewAsTree"; }
        { key = "ctrl-i"; command = "workbench.action.navigateForward"; }
        { key = "ctrl-o"; command = "workbench.action.navigateBack"; }
      ];
    };
  };
}
