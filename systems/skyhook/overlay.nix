self: super:
{
  qutebrowser = super.qutebrowser.override { enableVulkan = false; python3 = super.python311; };
}
