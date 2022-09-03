self: super:
{
  imports = [ ../../packages ];

  # Use the most update to date firmware
  raspberrypifw = super.raspberrypifw.overrideAttrs (old: rec {
    version = "1.20220830";
    src = super.fetchFromGitHub {
      owner = "raspberrypi";
      repo = "firmware";
      rev = version;
      sha256 = "sha256-ZmNZSFgjaL/S5JB1PMacTCFG5ThemPbYCLRysaO0UGI=";
    };
  });
}
