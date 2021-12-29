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
      sha256 = "1nndhjv4il42yw3pq8ni3r4nlp1m0r229fadrf4f9v51mgcg11i1";
    };
  });
}
