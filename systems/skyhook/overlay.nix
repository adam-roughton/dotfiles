self: super:
{
  qutebrowser = super.qutebrowser.override { enableVulkan = false; python3 = super.python3; };
  picom = super.picom.overrideAttrs (old: {
    version = "12.5";
    src = super.fetchFromGitHub {
      owner = "yshui";
      repo = "picom";
      rev = "v12.5";
      hash = "sha256-H8IbzzrzF1c63MXbw5mqoll3H+vgcSVpijrlSDNkc+o=";
      fetchSubmodules = true;
    };
  });
}
