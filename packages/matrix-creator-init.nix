{ stdenv, lib, cmake, fetchgit, openocd, matrixio-xc3sprog, matrix-creator-hal, ... }:

stdenv.mkDerivation rec {
  pname = "matrix-creator-init";
  version = "0.4.17";

  nativeBuildInputs = [ cmake ];

  buildInputs = [ openocd matrixio-xc3sprog matrix-creator-hal ];
  
  src = fetchgit {
    url = "https://github.com/matrix-io/matrix-creator-init";
    rev = "v${version}";
    sha256 = "1n3m8qkxcp02q6vq9h5z0jb7w9jvjfiqbyhwjd7bdlzmdm0fk2vj";
  };

  meta = with lib; {
    platforms = platforms.aarch64;
  };
}
