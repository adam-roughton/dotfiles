{ pkgs, ... }:
let
  user = import ../user.nix;
in
{
  config = {
    home.packages = with pkgs; [ 
      gitAndTools.hub tig gist 
    ];

    programs.git = {
      enable = true;
      userName = user.name;
      userEmail = user.email;
      signing = {
        signByDefault = true;
        key = user.gpgKey;
        gpgPath = "gpg";
      };
      ignores = [
        "*.iml"
        "*.sw*"
        ".envrc"
        "shell.nix"
      ];
      aliases = {
        co = "checkout";
        cb = "checkout -b";
        st = "status -sb";
        d = "difftool";
        m = "mergetool";
      };
      extraConfig = {
        url = {
          "ssh://git@github.com" = { insteadOf = "https://github.com"; };
        };
        hub.protocol = "git";
        pull = {
          "rebase" = true;
        };
        diff.tool = "vimdiff";
        difftool.prompt = false;
        merge.tool = "vimdiff";
        mergetool.prompt = false;
      };
    };
  };
}
