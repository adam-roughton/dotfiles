{ stdenv, lib, cmake, wiringpi, libftdi, fetchgit }:
stdenv.mkDerivation rec {
  pname = "matrixio-xc3sprog";
  version = "1.1.1.003";
  nativeBuildInputs = [ cmake ];
  buildInputs = [ 
    wiringpi
    libftdi
  ];
  src = fetchgit {
    url = "https://github.com/matrix-io/xc3sprog";
    rev = "v${version}";
    sha256 = "092npdk6pyas0gascb9c4bl5p3ggli37pjg9m0kwcdblk9pb29x0";
  };
  meta = with lib; {
    platforms = platforms.aarch64;
  };
}
