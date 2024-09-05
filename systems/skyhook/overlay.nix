self: super:
{
  qutebrowser = super.qutebrowser.override { enableVulkan = false; python3 = super.python311; };
  hplip = super.hplip.override {
    python3Packages = super.python311Packages;
  };
}
