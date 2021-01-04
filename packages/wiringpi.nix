{ stdenv, lib, fetchgit }:
let
  version = "2.60";

  src = fetchgit {
    url = "https://github.com/WiringPi/WiringPi";
    rev = "5bbb6e34b854a1a911e85145741681b875aec1a4";
    sha256 = "0xmyaqppwl3acz5m8gzs6l3w1n9xyqhmxb362ms06sf8wasd748k";
  };

  makeFlags = [ "PREFIX=" "DESTDIR=$(out)" "LDCONFIG=" "WIRINGPI_SUID=0" ];

  meta = with lib; {
    platforms = platforms.aarch64;
  };

  libwiringPi = stdenv.mkDerivation {
    inherit src makeFlags meta version;
    pname = "libwiringPi";
    postUnpack = "sourceRoot=$sourceRoot/wiringPi";
  };

  libwiringPiDev = stdenv.mkDerivation {
    inherit src makeFlags meta version;
    pname = "libwiringPiDev";
    postUnpack = "sourceRoot=$sourceRoot/devLib";
    buildInputs = [ libwiringPi ];
  };

  gpio = stdenv.mkDerivation {
    inherit src makeFlags meta version;
    pname = "gpio";
    postUnpack = "sourceRoot=$sourceRoot/gpio";
    buildInputs = [ libwiringPi libwiringPiDev ];
    preInstall = ''
      mkdir -p $out/bin
    '';
  };

in
  stdenv.mkDerivation {
    inherit version meta;
    pname = "wiringpi";
    propagatedBuildInputs = [ libwiringPi libwiringPiDev gpio ];
    unpackPhase = "true";
    installPhase = ''
    mkdir -p $out
    '';
  }
