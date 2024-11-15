{ stdenv, lib, fetchFromGitHub, buildNpmPackage, electron, nodejs_18 }:
buildNpmPackage rec {
  pname = "openfortivpn-webview";
  version = "1.2.3";
  buildInputs = [ 
    electron
  ];
  src = fetchFromGitHub {
    owner = "gm-vm";
    repo = "openfortivpn-webview";
    rev = "v${version}-electron";
    sha256 = "jGDCFdqRfnYwUgVs3KO1pDr52JgkYVRHi2KvABaZFl4=";
  };
  sourceRoot = "${src.name}/openfortivpn-webview-electron";
  dontNpmBuild = true;
  makeCacheWritable = true;
  npmDepsHash = "sha256-NKGu9jZMc+gd4BV1PnF4ukCNkjdUpZIJlYJ7ZzO+5WI=";

  node = nodejs_18;
  postBuild = ''
    npm exec electron-builder -- \
      --dir \
      -c.electronDist=${electron}/libexec/electron \
      -c.electronVersion=${electron.version}
  '';
  installPhase = ''
    runHook preInstall

    mkdir $out
    mkdir -p $out/opt/openfortivpn-webview
    pushd dist/linux-unpacked
    cp -r locales resources{,.pak} $out/opt/openfortivpn-webview
    popd

    makeWrapper '${electron}/bin/electron' "$out/bin/openfortivpn-webview" \
      --add-flags $out/opt/openfortivpn-webview/resources/app.asar \
      --set-default ELECTRON_IS_DEV 0 \
      --inherit-argv0

    runHook postInstall
  '';

  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
}
