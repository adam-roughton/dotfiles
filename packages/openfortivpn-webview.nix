{ stdenv, lib, fetchFromGitHub, buildNpmPackage, electron_25, nodejs_18 }:
let
  electron = electron_25;
in
buildNpmPackage rec {
  pname = "openfortivpn-webview";
  version = "1.1.2";
  buildInputs = [ 
    electron
  ];
  src = let
    repo = fetchFromGitHub {
      owner = "gm-vm";
      repo = "openfortivpn-webview";
      rev = "v${version}-electron";
      sha256 = "BNotbb2pL7McBm0SQwcgEvjgS2GId4HVaxWUz/ODs6w=";
    };
  in "${repo}/openfortivpn-webview-electron";
  
  dontNpmBuild = true;
  makeCacheWritable = true;
  npmDepsHash = "sha256-FvonIgVWAB0mHQaYcJkrZ9pn/nrTju2Br5OkmtGFsIk=";

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
