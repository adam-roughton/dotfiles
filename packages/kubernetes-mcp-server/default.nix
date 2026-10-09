# kubernetes-mcp-server (https://github.com/containers/kubernetes-mcp-server).
# Not in nixpkgs; the upstream release binaries are static Go builds.
{ lib, stdenvNoCC, fetchurl }:
let
  version = "0.0.67";
  assets = {
    x86_64-linux = {
      name = "linux-amd64";
      hash = "sha256-15HCK1NngTzJ58ZuQF2P9/fVEYm1vWGf3YSpnPehwRY=";
    };
    aarch64-linux = {
      name = "linux-arm64";
      hash = "sha256-2TeAObaLUkd5ZlW6i7shDV6UKH5WvVMhEtgZUKGfDlA=";
    };
  };
  asset = assets.${stdenvNoCC.hostPlatform.system}
    or (throw "kubernetes-mcp-server: no release binary for ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "kubernetes-mcp-server";
  inherit version;

  src = fetchurl {
    url = "https://github.com/containers/kubernetes-mcp-server/releases/download/v${version}/kubernetes-mcp-server-${asset.name}";
    inherit (asset) hash;
  };

  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/kubernetes-mcp-server
    runHook postInstall
  '';

  meta = {
    description = "Model Context Protocol server for Kubernetes and OpenShift";
    homepage = "https://github.com/containers/kubernetes-mcp-server";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames assets;
    mainProgram = "kubernetes-mcp-server";
  };
}
