self: super:
{
  # Work around D-Bus property getter reply problem in bluez 5.62
  # https://github.com/bluez/bluez/commit/ebf2d7935690c00c7fd12768177e2023fc63c9fe
  # https://github.com/bluez/bluez/issues/235
  bluez = super.bluez.overrideAttrs (old: rec {
    version = "5.63";
    src = super.fetchurl {
      url = "mirror://kernel/linux/bluetooth/${old.pname}-${version}.tar.xz";
      sha256 = "sha256-k0nhHoFguz1yCDXScSUNinQk02kPUonm22/gfMZsbXY=";
    };
  });
}
