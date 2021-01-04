{ stdenv, lib, cmake, wiringpi, fftwSinglePrec, gflags, fetchgit }:
stdenv.mkDerivation rec {
  pname = "matrix-creator-hal";
  version = "0.3.8";
  nativeBuildInputs = [ cmake ];
  buildInputs = [ 
    wiringpi
    fftwSinglePrec
    gflags 
  ];
  src = fetchgit {
    url = "https://github.com/matrix-io/matrix-creator-hal";
    rev = "v${version}";
    sha256 = "058ky3jrlh5dqdfb2az2g7d93gsgslmpmfq6918jzpi06nv38bgy";
  };
  meta = with lib; {
    platforms = platforms.aarch64;
  };
}
