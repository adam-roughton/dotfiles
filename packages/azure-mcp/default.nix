# Azure MCP Server (https://github.com/microsoft/mcp), from the upstream release.
#
# nixpkgs' azure-mcp patches and strips the binary. On aarch64-linux the
# release is a .NET single-file bundle whose payload is appended to the ELF
# file, so stripping removes it ("Failure processing application bundle").
# This package installs the binary unmodified instead. It therefore needs the
# standard dynamic loader path (passthru.fhsInterpreter) to exist in the image
# that runs it; systems/infra-broker adds that symlink.
{ lib, stdenvNoCC, fetchzip, makeWrapper, glibc, stdenv, zlib, openssl, krb5, icu }:
let
  version = "3.0.0-beta.33";
  srcs = {
    x86_64-linux = {
      url = "https://github.com/microsoft/mcp/releases/download/Azure.Mcp.Server-${version}/Azure.Mcp.Server-linux-x64-native.zip";
      hash = "sha256-Zm55CQkPGvdHJDOqeh9A5wBX4HNXg/h2rhkfGRqy0Zk=";
      interpreter = "/lib64/ld-linux-x86-64.so.2";
    };
    aarch64-linux = {
      url = "https://github.com/microsoft/mcp/releases/download/Azure.Mcp.Server-${version}/Azure.Mcp.Server-linux-arm64.zip";
      hash = "sha256-UY4cYtJE74+dWpOjq9ddhhjCPRavCwvA+VqFLabIV1o=";
      interpreter = "/lib/ld-linux-aarch64.so.1";
    };
  };
  source = srcs.${stdenvNoCC.hostPlatform.system}
    or (throw "azure-mcp: no release for ${stdenvNoCC.hostPlatform.system}");
  libraryPath = lib.makeLibraryPath [ glibc stdenv.cc.cc.lib zlib openssl krb5 icu ];
in
stdenvNoCC.mkDerivation {
  pname = "azure-mcp";
  inherit version;

  src = fetchzip {
    inherit (source) url hash;
    stripRoot = false;
  };

  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/azure-mcp
    cp -r . $out/libexec/azure-mcp/
    rm -f $out/libexec/azure-mcp/*.pdb
    chmod +x $out/libexec/azure-mcp/azmcp
    # .NET extracts the bundle's native libraries on first start, so point the
    # extraction directory at a writable location by default.
    makeWrapper $out/libexec/azure-mcp/azmcp $out/bin/azure-mcp \
      --prefix LD_LIBRARY_PATH : ${libraryPath} \
      --run 'export DOTNET_BUNDLE_EXTRACT_BASE_DIR="''${DOTNET_BUNDLE_EXTRACT_BASE_DIR:-''${TMPDIR:-/tmp}/azure-mcp-bundle}"' \
      --set-default AZURE_MCP_COLLECT_TELEMETRY false \
      --set-default DOTNET_SYSTEM_GLOBALIZATION_INVARIANT 1
    runHook postInstall
  '';

  passthru = {
    fhsInterpreter = source.interpreter;
    # The loader the release binary expects, provided by this glibc.
    interpreterTarget = "${glibc}/lib/${builtins.baseNameOf source.interpreter}";
  };

  meta = {
    description = "Model Context Protocol server for Azure services";
    homepage = "https://github.com/microsoft/mcp";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames srcs;
    mainProgram = "azure-mcp";
  };
}
