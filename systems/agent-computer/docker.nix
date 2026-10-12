{ pkgs, lib }:
let
  # Keep the genuine Compose and Buildx plugins for integration-test builds.
  engine = pkgs.docker.override {
    withSystemd = false;
    withBtrfs = false;
    withLvm = false;
  };
  tun = pkgs.runCommandCC "agent-docker-tun" { } ''
    mkdir -p "$out/bin"
    $CC -std=c11 -O2 -Wall -Wextra -Werror ${./scripts/agent-docker-tun.c} -o "$out/bin/agent-docker-tun"
  '';
  # Run linux/amd64 images under QEMU user-mode emulation on other hosts.
  # binfmt_misc's F flag opens the interpreter at registration so containers
  # can use it without the Nix store, but a dynamic loader would still be
  # looked up inside each container; hence a static build of the one target.
  emulateAmd64 = !pkgs.stdenv.hostPlatform.isx86_64;
  # Nixpkgs' aarch64-musl QEMU 11.1.1 crashes before main on the microsandbox
  # kernel. Use the upstream static interpreter which is tested by binfmt.
  qemu = pkgs.stdenvNoCC.mkDerivation {
    pname = "agent-qemu-x86_64";
    version = "10.2.3-68";
    src = pkgs.fetchurl {
      url = "https://github.com/tonistiigi/binfmt/releases/download/deploy/v10.2.3-68/qemu_v10.2.3_linux-arm64.tar.gz";
      hash = "sha256-yhn40gK5d5BPcPpkZLXvlDl0CVHUD4lzDS8pgfhTv6o=";
    };
    sourceRoot = ".";
    installPhase = ''
      install -Dm755 qemu-x86_64 "$out/bin/qemu-x86_64"
    '';
  };
  # The interpreter path is compiled in, so the helper's store reference also
  # puts QEMU into the image closure.
  binfmt = if !emulateAmd64 then null else pkgs.runCommandCC "agent-docker-binfmt" { } ''
    mkdir -p "$out/bin"
    $CC -std=c11 -O2 -Wall -Wextra -Werror \
      -DAGENT_QEMU_X86_64='"${qemu}/bin/qemu-x86_64"' \
      ${./scripts/agent-docker-binfmt.c} -o "$out/bin/agent-docker-binfmt"
  '';
  start = pkgs.writeShellApplication {
    name = "agent-docker";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linuxMinimal pkgs.gnugrep ];
    text = lib.replaceStrings
      [ "@docker@" "@dockerd@" "@cacert@" "@tun@" "@binfmt@" ]
      [
        "${engine}/bin/docker"
        "${engine}/bin/dockerd-rootless"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "/usr/local/bin/agent-docker-tun"
        (if binfmt == null then "true" else "/usr/local/bin/agent-docker-binfmt")
      ]
      (builtins.readFile ./scripts/agent-docker);
  };
  client = pkgs.writeShellApplication {
    name = "docker";
    text = ''
      export DOCKER_HOST="''${DOCKER_HOST:-unix://$HOME/.local/run/agent-docker/docker.sock}"
      # Match the SDK endpoint even if a project has selected a CLI context.
      if [ "''${DOCKER_HOST:-}" = "unix://$HOME/.local/run/agent-docker/docker.sock" ]; then
        unset DOCKER_CONTEXT
      fi
      case "''${1:-}" in
        --help|-h|--version|-v) ;;
        *) ${start}/bin/agent-docker start ;;
      esac
      exec ${engine}/bin/docker "$@"
    '';
  };
  compose = pkgs.writeShellApplication {
    name = "docker-compose";
    text = ''
      exec ${client}/bin/docker compose "$@"
    '';
  };
in {
  # binfmt is null when the image's platform runs amd64 natively.
  inherit tun binfmt;
  packages = [ start client compose ];
  # Copy these out of the immutable store before setting their setuid bits.
  uidmap = pkgs.shadow;
}
