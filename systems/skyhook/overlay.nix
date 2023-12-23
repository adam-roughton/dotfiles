self: super:
{
  qutebrowser = super.qutebrowser.override { enableVulkan = false; };
}
