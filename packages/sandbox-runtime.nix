{ lib, buildNpmPackage, fetchzip, nodejs, makeWrapper, runCommand
, stdenv, bubblewrap ? null, ripgrep, socat
}:

let
  version = "0.0.67"; # bump via `npm view @anthropic-ai/sandbox-runtime version`
  tarball = fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/sandbox-runtime/-/sandbox-runtime-${version}.tgz";
    hash = "sha256-meiGtlpxKxRZNV6fmEACt4JvMPxKczaFPf98CdkqBp0="; 
  };
  src = runCommand "sandbox-runtime-src" { } ''
    mkdir -p $out
    cp -r ${tarball}/* $out/
    cp ${./sandbox-runtime-package-lock.json} $out/package-lock.json
  '';
in
buildNpmPackage {
  pname = "sandbox-runtime";
  inherit version src;
  npmDepsHash = "sha256-vawqGd44S1SivsN8/XNreQyQXjE5TV6H/IS5CZ4mPO4=";
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  postInstall = lib.optionalString stdenv.hostPlatform.isLinux ''
    wrapProgram $out/bin/srt \
      --suffix PATH : ${lib.makeBinPath [ bubblewrap ripgrep socat ]}
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    wrapProgram $out/bin/srt \
      --suffix PATH : ${lib.makeBinPath [ ripgrep socat ]}
  '';

  meta = with lib; {
    description = "Anthropic Sandbox Runtime (srt) — OS-native process sandboxing";
    homepage = "https://github.com/anthropic-experimental/sandbox-runtime";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
