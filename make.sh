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
    nix-build --no-link \
      --allow-unsafe-native-code-during-evaluation \
      "$DOTFILES_DIR" \
      -A system \
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
  "firmware")
    systemName="$1"
    shift

    if [ "$systemName" != "rpi3" ]; then
      echo "can only update firmware for rpi3"
      exit 1
    fi

    tmp="$(mktemp -d)"
    trap "rm '$tmp/result'" EXIT
    pushd $tmp
    nix-build --no-link \
      --allow-unsafe-native-code-during-evaluation \
      "$DOTFILES_DIR" \
      --argstr systemName "$systemName" \
      -o "result" \
      --keep-going \
      -A firmware $* >&2
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
      rm /mnt/*; \
      cp result/* /mnt; \
      echo 'Updated FIRMWARE:'; \
      ls /mnt; \
      umount /mnt
      "
    echo "Firmware updated. Reboot to apply changes."
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
