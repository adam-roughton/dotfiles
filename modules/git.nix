{ pkgs, ... }:
let
  user = import ../user.nix;
in
{
  config = {
    home.packages = with pkgs; [ 
      gitAndTools.hub tig gist git-crypt
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
      lfs.enable = true;
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
        init.defaultBranch = "main";
        push.autoSetupRemote = true;
      };
    };
  };
}
