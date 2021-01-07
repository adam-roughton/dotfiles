#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

mode="$1"
shift

case "$mode" in
  "build")
    systemName="$1"
    shift

    tmp="$(mktemp -u)"
    nix build --no-link \
      --allow-unsafe-native-code-during-evaluation \
      -f "$DOTFILES_DIR" \
      system \
      --argstr systemName "$systemName" \
      -o "$tmp/result" \
      --keep-going $* >&2
    trap "rm '$tmp/result'" EXIT
    drv="$(readlink "$tmp/result")"
    echo "$drv"
    ;;
  "vm")
    systemName="$1"
    shift

    tmp="$(mktemp -d)"
    trap "rm '$tmp/result'" EXIT
    pushd $tmp
    nix-build --no-link \
      --allow-unsafe-native-code-during-evaluation \
      "$DOTFILES_DIR" \
      --argstr systemName "$systemName" \
      -o "result" \
      --keep-going \
      -A vm $* >&2
    command "./result/bin/run-$systemName-vm"
    popd
    ;;
  "disk-image")
    systemName="$1"
    shift

    tmp="$(mktemp -d)"
    trap "rm '$tmp/result'" EXIT
    pushd $tmp
    nix-build --no-link \
      --allow-unsafe-native-code-during-evaluation \
      "$DOTFILES_DIR" \
      --argstr systemName "$systemName" \
      -o "result" \
      --keep-going \
      -A diskImage $* >&2
    ;;
  "update")
    niv update
    ;;
  "switch")
    systemName="$1"
    shift

    drv="$(./make.sh build $systemName)"
    sudo nix-env -p /nix/var/nix/profiles/system --set "$drv"
    NIXOS_INSTALL_BOOTLOADER=1 sudo --preserve-env=NIXOS_INSTALL_BOOTLOADER "$drv/bin/switch-to-configuration" switch
    ;;
  "clean")
    sudo nix-collect-garbage --delete-older-than 7d
    nix-collect-garbage --delete-older-than 7d # clean user drv as well
    nix optimise-store
    ;;
  *)
    exit 1
esac
