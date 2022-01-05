self: super:
{
  imports = [ ../../packages ];

  # Use the most update to date firmware
  raspberrypifw = super.raspberrypifw.overrideAttrs (old: rec {
    version = "1.20211118";
    src = super.fetchFromGitHub {
      owner = "raspberrypi";
      repo = "firmware";
      rev = version;
      sha256 = "i+gLEI+mNNO38aHPPgRcToH/J3BzVxIV5XQHw0BZEyo=";
    };
  });
}
