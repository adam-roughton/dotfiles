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
  start = pkgs.writeShellApplication {
    name = "agent-docker";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linuxMinimal pkgs.gnugrep ];
    text = lib.replaceStrings
      [ "@docker@" "@dockerd@" "@cacert@" "@tun@" ]
      [ "${engine}/bin/docker" "${engine}/bin/dockerd-rootless" "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" "/usr/local/bin/agent-docker-tun" ]
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
  inherit tun;
  packages = [ start client compose ];
  # Copy these out of the immutable store before setting their setuid bits.
  uidmap = pkgs.shadow;
}
