#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

usage() {
  echo "usage: $0 {build|image|vm|disk-image|firmware|switch|update|clean} [SYSTEM] [NIX OPTIONS...]" >&2
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

host_system() {
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

  nix build --no-link --print-out-paths \
    "$DOTFILES_DIR#$(flake_attr "$system_name").$target" "$@"
}

mode="${1:-}"
shift || true

case "$mode" in
  "image")
    nix build --no-link --print-out-paths \
      "$DOTFILES_DIR#packages.$(host_system).agent-image" "$@"
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
    sudo -- "$BASH" -c "mount /dev/disk/by-label/FIRMWARE /mnt; \
      rm -f /mnt/*; \
      cp '$firmware'/* /mnt; \
      echo 'Updated FIRMWARE:'; \
      ls /mnt; \
      umount /mnt
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
