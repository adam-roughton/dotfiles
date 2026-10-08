#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

usage() {
  echo "usage: $0 {build|image|vm|disk-image|firmware|switch|update|clean} [SYSTEM] [OPTIONS...]" >&2
  exit 1
}

flake_attr() {
  local system_name="$1"
  case "$system_name" in
    superposition)
      echo "darwinConfigurations.superposition"
      ;;
    rpi3|skyhook|spacemonkey)
      echo "nixosConfigurations.$system_name"
      ;;
    *)
      echo "unknown system: $system_name" >&2
      exit 1
      ;;
  esac
}

target_system() {
  local system_name="$1"
  case "$system_name" in
    superposition)
      echo "aarch64-darwin"
      ;;
    rpi3)
      echo "aarch64-linux"
      ;;
    skyhook|spacemonkey)
      echo "x86_64-linux"
      ;;
    *)
      echo "unknown system: $system_name" >&2
      exit 1
      ;;
  esac
}

agent_system() {
  case "$(uname -m)" in
    aarch64|arm64)
      echo "aarch64-linux"
      ;;
    x86_64|amd64)
      echo "x86_64-linux"
      ;;
    *)
      echo "unsupported host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

build_attr() {
  local system_name="$1"
  local target="$2"
  shift 2

  nix build --system "$(target_system "$system_name")" --no-link --print-out-paths \
    "$DOTFILES_DIR#$(flake_attr "$system_name").$target" "$@"
}

# Nix image used to build Linux outputs on macOS hosts. Pinned so Docker does
# not pull (and keep) a new builder image whenever `latest` moves.
NIX_BUILDER_IMAGE="nixos/nix:2.35.2"

# Runs inside the builder container. Arguments: host repo path (for error
# messages), flake attribute, then extra nix build options. The attribute must
# be an image stream script; build logs go to stderr and the image tarball is
# the only thing written to stdout.
# shellcheck disable=SC2016
CONTAINER_BUILD_SCRIPT='
set -eu
host_dir="$1"
attr="$2"
shift 2
if [ ! -f /src/flake.nix ]; then
  echo "$host_dir is not visible to the Docker VM; move it under a shared directory (colima shares \$HOME by default)" >&2
  exit 1
fi
# The bind-mounted repository is owned by the host user, not container root.
printf "[safe]\n\tdirectory = *\n" > "${HOME:-/root}/.gitconfig"
# Unprivileged containers cannot create the Nix build sandbox. keep-outputs and
# keep-derivations make the GC root below also retain the build-time inputs of
# the current image, so rebuilds stay incremental while store paths from older
# builds are collected.
export NIX_CONFIG="extra-experimental-features = nix-command flakes
sandbox = false
keep-outputs = true
keep-derivations = true"
# Request submodules in the flake reference itself. With a plain "/src" the
# flake is first fetched without submodules and, because of
# `inputs.self.submodules`, refetched at its locked (clean-tree) revision; that
# path fetches each submodule from its remote URL, and the container has no
# GitHub credentials. Asking for submodules up front reads them from the
# checked-out working tree under /src instead.
out="$(nix build --print-out-paths \
  --out-link /nix/var/nix/gcroots/dotfiles-agent-image \
  "git+file:///src?submodules=1#$attr" "$@")"
"$out"
nix-collect-garbage >&2 || echo "warning: garbage collection of the builder store failed" >&2
'

# The agent image contains derivations that can only be built on Linux (and
# Nix cannot run Linux builds on a macOS host), so on macOS the build runs
# inside a Linux container. The container's /nix lives in a named Docker volume
# so later builds reuse it. Writes the image tarball to $2.
build_agent_image_in_container() {
  local image_system="$1"
  local output="$2"
  shift 2

  local platform
  case "$image_system" in
    aarch64-linux) platform="linux/arm64" ;;
    x86_64-linux) platform="linux/amd64" ;;
    *)
      echo "unsupported image system: $image_system" >&2
      exit 1
      ;;
  esac

  command -v docker >/dev/null 2>&1 || {
    echo "docker CLI is required to build the agent image on macOS (for example via colima)" >&2
    exit 1
  }
  docker info >/dev/null 2>&1 || {
    echo "cannot reach the Docker daemon; start it first (for example: colima start)" >&2
    exit 1
  }

  # The container reads submodules from the working tree; an uninitialised one
  # would make Nix fall back to cloning it from its remote URL, which needs
  # credentials the container does not have.
  local submodule_line
  while IFS= read -r submodule_line; do
    case "$submodule_line" in
      -*)
        echo "submodule ${submodule_line#* } is not checked out; run: git -C '$DOTFILES_DIR' submodule update --init" >&2
        exit 1
        ;;
    esac
  done < <(git -C "$DOTFILES_DIR" submodule status)

  echo "Building $image_system agent image in a $NIX_BUILDER_IMAGE container..." >&2
  docker run --rm --init --platform "$platform" \
    --volume "dotfiles-agent-image-nix-$image_system:/nix" \
    --mount "type=bind,source=$DOTFILES_DIR,target=/src,readonly" \
    "$NIX_BUILDER_IMAGE" \
    sh -c "$CONTAINER_BUILD_SCRIPT" sh \
    "$DOTFILES_DIR" "packages.$image_system.agent-image" "$@" > "$output"

  [ -s "$output" ] || {
    echo "container build produced no image" >&2
    exit 1
  }
}

mode="${1:-}"
shift || true

case "$mode" in
  "image")
    force=false
    if [ "${1:-}" = "--force" ]; then
      force=true
      shift
    fi
    command -v code-agent >/dev/null 2>&1 || {
      echo "code-agent is not installed; activate the agent-sandbox Home Manager module first" >&2
      exit 1
    }
    image_tag="$(code-agent --print-image)"
    command -v msb >/dev/null 2>&1 || {
      echo "microsandbox CLI (msb) is not installed or is not on PATH" >&2
      exit 1
    }
    image_list="$(msb images -q)"
    image_exists=false
    while IFS= read -r image_ref; do
      if [ "$image_ref" = "$image_tag" ]; then
        image_exists=true
        break
      fi
    done <<< "$image_list"
    if [ "$image_exists" = true ] && [ "$force" = false ]; then
      echo "Microsandbox image already registered: $image_tag" >&2
      echo "Use '$0 image --force' to rebuild and replace it." >&2
      exit 0
    fi
    image_system="$(agent_system)"
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' EXIT
    image_path="$build_dir/agent-image.tar"
    if [ "$(uname -s)" = "Darwin" ]; then
      build_agent_image_in_container "$image_system" "$image_path" "$@"
    else
      # The flake attribute already selects the target system; the host
      # architecture matches it, so no --system override is needed. Enable
      # flakes per-invocation so this does not depend on the host nix.conf.
      # The output is a script that streams the image tarball.
      image_stream="$(nix --extra-experimental-features "nix-command flakes" \
        build --no-link --print-out-paths \
        "$DOTFILES_DIR#packages.$image_system.agent-image" "$@")"
      "$image_stream" > "$image_path"
    fi
    if [ "$image_exists" = true ]; then
      msb rmi --force "$image_tag"
    fi
    msb load --input "$image_path" --tag "$image_tag"
    echo "Registered microsandbox image: $image_tag" >&2
    ;;
  "build")
    system_name="${1:?system name is required}"
    shift
    build_attr "$system_name" "config.system.build.toplevel" "$@"
    ;;
  "vm")
    system_name="${1:?system name is required}"
    shift
    vm="$(build_attr "$system_name" "config.system.build.vm" "$@")"
    command "$vm/bin/run-$system_name-vm"
    ;;
  "disk-image")
    system_name="${1:?system name is required}"
    shift
    build_attr "$system_name" "config.system.build.sdImage" "$@"
    ;;
  "firmware")
    system_name="${1:?system name is required}"
    shift

    if [ "$system_name" != "rpi3" ]; then
      echo "can only update firmware for rpi3" >&2
      exit 1
    fi

    firmware="$(build_attr "$system_name" "config.system.build.firmware" "$@")"
    echo "About to update firmware. Proceed?"
    select answer in "Yes" "No"; do
      if [ "$answer" != "Yes" ]; then
        exit
      fi
      break
    done
    if [ ! -d /mnt ]; then
      sudo mkdir /mnt
    fi
    # set -e so nothing is deleted if the mount fails. The firmware includes
    # the overlays/ directory, so copy recursively.
    sudo -- "$BASH" -c "set -e; \
      mount /dev/disk/by-label/FIRMWARE /mnt; \
      trap 'umount /mnt' EXIT; \
      find /mnt -mindepth 1 -delete; \
      cp -r '$firmware'/. /mnt/; \
      echo 'Updated FIRMWARE:'; \
      ls /mnt
      "
    echo "Firmware updated. Reboot to apply changes."
    ;;
  "update")
    nix flake update "$DOTFILES_DIR" "$@"
    ;;
  "switch")
    system_name="${1:?system name is required}"
    shift

    if [ "$system_name" = "superposition" ]; then
      darwin-rebuild switch --flake "$DOTFILES_DIR#$system_name" "$@"
    else
      drv="$("$BASH" "$0" build "$system_name" "$@")"
      sudo nix-env -p /nix/var/nix/profiles/system --set "$drv"
      NIXOS_INSTALL_BOOTLOADER=1 sudo --preserve-env=NIXOS_INSTALL_BOOTLOADER \
        "$drv/bin/switch-to-configuration" switch
    fi
    ;;
  "clean")
    sudo nix-collect-garbage --delete-older-than 7d
    nix-collect-garbage --delete-older-than 7d
    nix store optimise
    ;;
  *)
    usage
    ;;
esac
