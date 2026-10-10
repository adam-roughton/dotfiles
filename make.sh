#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# agent-image (modules/agent-sandbox) runs `make.sh image` from the copy of
# this repository in the Nix store and names itself in DOTFILES_IMAGE_COMMAND.
image_command="${DOTFILES_IMAGE_COMMAND:-$0 image}"

usage() {
  if [ -n "${DOTFILES_IMAGE_COMMAND:-}" ]; then
    echo "usage: $DOTFILES_IMAGE_COMMAND [agent|broker] [--force] [NIX OPTIONS...]" >&2
    echo "       $DOTFILES_IMAGE_COMMAND project DIR [--name NAME] [--force] [NIX OPTIONS...]" >&2
    exit 1
  fi
  echo "usage: $0 {build|image|vm|disk-image|firmware|switch|update|clean} [SYSTEM] [OPTIONS...]" >&2
  echo "       $0 image [agent|broker] [--force] [NIX OPTIONS...]" >&2
  echo "       $0 image project DIR [--name NAME] [--force] [NIX OPTIONS...]" >&2
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

# Prints the names of microsandboxes created from an image reference, one per
# line. msb records the reference verbatim, so an exact match is sufficient.
sandboxes_using_image() {
  local image_tag="$1"
  local sandboxes
  sandboxes="$(msb ls --format json)" || return 1
  jq -r --arg image "$image_tag" \
    'if type == "array" then .[] | select(.image == $image) | .name
     else error("unexpected msb ls output") end' <<< "$sandboxes"
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

# Start of every script run in the builder container. Its first argument is the
# host repo path (for error messages); the script's own arguments follow. A
# checkout is bind-mounted at /src; a copy of the source in the Nix store is
# streamed to stdin as a tar archive instead (see run_in_builder_container).
# shellcheck disable=SC2016
CONTAINER_PRELUDE='
set -eu
host_dir="$1"
shift
if [ "${DOTFILES_SOURCE:-}" = stdin ]; then
  mkdir /src
  tar -x -f - -C /src --warning=no-unknown-keyword
  cat > /dev/null
  # Not a git repository; the store copy already contains the submodules.
  flake="path:/src"
else
  if [ ! -f /src/flake.nix ]; then
    echo "$host_dir is not visible to the Docker VM; move it under a shared directory (colima shares \$HOME by default)" >&2
    exit 1
  fi
  # The bind-mounted repository is owned by the host user, not container root.
  printf "[safe]\n\tdirectory = *\n" > "${HOME:-/root}/.gitconfig"
  # Request submodules in the flake reference itself. With a plain "/src" the
  # flake is first fetched without submodules and, because of
  # `inputs.self.submodules`, refetched at its locked (clean-tree) revision;
  # that path fetches each submodule from its remote URL, and the container
  # has no GitHub credentials. Asking for submodules up front reads them from
  # the checked-out working tree under /src instead.
  flake="git+file:///src?submodules=1"
fi
# Unprivileged containers cannot create the Nix build sandbox. keep-outputs and
# keep-derivations make the GC roots below (one per image) also retain the
# build-time inputs of each image, so rebuilds stay incremental while store
# paths from older builds are collected.
export NIX_CONFIG="extra-experimental-features = nix-command flakes
sandbox = false
keep-outputs = true
keep-derivations = true"
'

# Arguments: flake attribute, then extra nix build options. The attribute must
# be an image stream script; build logs go to stderr and the image tarball is
# the only thing written to stdout.
# shellcheck disable=SC2016
CONTAINER_BUILD_SCRIPT="$CONTAINER_PRELUDE"'
attr="$1"
shift
out="$(nix build --print-out-paths \
  --out-link "/nix/var/nix/gcroots/dotfiles-${attr##*.}" \
  "$flake#$attr" "$@")"
"$out"
nix-collect-garbage >&2 || echo "warning: garbage collection of the builder store failed" >&2
'

# Project images (make.sh image project). Expects AGENT_PROJECT_SHELL and
# AGENT_PROJECT_IMAGE in the environment and the project directory mounted at
# its host path. Arguments: "key" or "build", the image system, then extra nix
# options. Writes the image key or the image tarball to stdout.
# shellcheck disable=SC2016
CONTAINER_PROJECT_SCRIPT="$CONTAINER_PRELUDE"'
action="$1"
system="$2"
shift 2
if [ ! -f "$AGENT_PROJECT_SHELL" ]; then
  echo "$AGENT_PROJECT_SHELL is not visible to the Docker VM; move the project under a shared directory (colima shares \$HOME by default)" >&2
  exit 1
fi
project="$flake#legacyPackages.$system.agent-project"
case "$action" in
  key)
    nix eval --impure --raw "$project.key" "$@"
    ;;
  build)
    # print-dev-env points $out at ./outputs; project.nix rewrites that
    # directory to /workspace/outputs.
    work="$(mktemp -d)"
    cd "$work"
    nix print-dev-env --impure --profile "$work/env-profile" "$project.shell" "$@" > "$work/env.sh"
    AGENT_PROJECT_ENV="$(readlink -f "$work/env-profile")"
    export AGENT_PROJECT_ENV AGENT_PROJECT_ENV_SCRIPT="$work/env.sh"
    # One GC root for project images: the builder store keeps the latest
    # project image, and older ones are rebuilt if they are needed again.
    out="$(nix build --impure --print-out-paths \
      --out-link /nix/var/nix/gcroots/dotfiles-agent-project-image \
      "$project.image" "$@")"
    "$out"
    nix-collect-garbage >&2 || echo "warning: garbage collection of the builder store failed" >&2
    ;;
esac
'

# The images contain derivations that can only be built on Linux (and Nix
# cannot run Linux builds on a macOS host), so on macOS the build runs inside a
# Linux container. The container's /nix lives in a named Docker volume so later
# builds reuse it. Arguments: image system, output file (receives the script's
# stdout), script, extra docker run options, `--`, then the script's arguments.
run_in_builder_container() {
  local image_system="$1"
  local output="$2"
  local script="$3"
  shift 3
  local docker_options=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    docker_options+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift

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

  # A checkout is bind-mounted. agent-image runs this script from the source
  # in the Nix store, which the Docker VM cannot see (colima shares only $HOME
  # by default), so that copy is streamed to the container instead.
  local stream_source=false
  local source_options=()
  if [ -e "$DOTFILES_DIR/.git" ]; then
    # The container reads submodules from the working tree; an uninitialised
    # one would make Nix fall back to cloning it from its remote URL, which
    # needs credentials the container does not have.
    local submodule_line
    while IFS= read -r submodule_line; do
      case "$submodule_line" in
        -*)
          echo "submodule ${submodule_line#* } is not checked out; run: git -C '$DOTFILES_DIR' submodule update --init" >&2
          exit 1
          ;;
      esac
    done < <(git -C "$DOTFILES_DIR" submodule status)
    source_options=(--mount "type=bind,source=$DOTFILES_DIR,target=/src,readonly")
  else
    stream_source=true
    source_options=(--interactive --env DOTFILES_SOURCE=stdin)
  fi

  local docker_run=(docker run --rm --init --platform "$platform"
    --volume "dotfiles-agent-image-nix-$image_system:/nix"
    "${source_options[@]}"
    ${docker_options[@]+"${docker_options[@]}"}
    "$NIX_BUILDER_IMAGE"
    sh -c "$script" sh "$DOTFILES_DIR" "$@")
  if [ "$stream_source" = true ]; then
    tar -c -f - -C "$DOTFILES_DIR" . | "${docker_run[@]}" > "$output"
  else
    "${docker_run[@]}" > "$output"
  fi
}

# Builds a flake image attribute in the builder container and writes the image
# tarball to $3.
build_image_in_container() {
  local image_system="$1"
  local image_attr="$2"
  local output="$3"
  shift 3

  echo "Building $image_system $image_attr in a $NIX_BUILDER_IMAGE container..." >&2
  run_in_builder_container "$image_system" "$output" "$CONTAINER_BUILD_SCRIPT" -- \
    "packages.$image_system.$image_attr" "$@"

  [ -s "$output" ] || {
    echo "container build produced no image" >&2
    exit 1
  }
}

# Temporary build files and the image build lock, released on exit.
build_dir=''
image_lock="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/agent-image.lock"
image_locked=false
release_image_build() {
  [ -z "$build_dir" ] || rm -rf "$build_dir"
  if [ "$image_locked" = true ]; then rmdir "$image_lock"; fi
}
trap release_image_build EXIT

# Serializes image builds and loads, for example two code-agent sessions that
# need the same new project image.
acquire_image_lock() {
  mkdir -p "$(dirname "$image_lock")"
  local waiting=false
  until mkdir "$image_lock" 2>/dev/null; do
    if [ "$waiting" = false ]; then
      echo "Waiting for another image build to finish (if none is running, remove $image_lock)..." >&2
      waiting=true
    fi
    sleep 5
  done
  image_locked=true
}

# Succeeds if msb has an image with exactly this reference.
image_registered() {
  local wanted="$1"
  local image_list image_ref
  image_list="$(msb images -q)" || {
    echo "cannot list microsandbox images" >&2
    exit 1
  }
  while IFS= read -r image_ref; do
    [ "$image_ref" != "$wanted" ] || return 0
  done <<< "$image_list"
  return 1
}

# Sandboxes stay tied to the image they were created from, and msb cannot
# cleanly replace it under them, so refuse to replace an image that is in use.
require_image_unused() {
  local image_tag="$1"
  local image_users sandbox_name
  image_users="$(sandboxes_using_image "$image_tag")" || {
    echo "cannot list microsandboxes; refusing to replace $image_tag" >&2
    exit 1
  }
  if [ -n "$image_users" ]; then
    echo "Refusing to replace $image_tag: it is used by these sandboxes:" >&2
    while IFS= read -r sandbox_name; do
      echo "  $sandbox_name" >&2
    done <<< "$image_users"
    echo "Remove them first with 'code-agent cleanup', 'infra-agent cleanup' / 'infra-agent broker down'" >&2
    echo "(or 'msb rm --force <name>'), then retry." >&2
    exit 1
  fi
}

# Removes the project images NAME:PROJECT-<key> other than the one to keep.
# Images still used by a sandbox are kept: `msb rmi --force` would only untag
# them and leave their storage behind, so they are removed by a later build.
remove_old_project_images() {
  local prefix="$1"
  local keep="$2"
  local image_list image_ref image_users
  image_list="$(msb images -q)" || {
    echo "warning: cannot list microsandbox images; old project images were not removed" >&2
    return
  }
  while IFS= read -r image_ref; do
    if [[ "$image_ref" != "$prefix"* ]] || [ "$image_ref" = "$keep" ] || \
      ! [[ "${image_ref#"$prefix"}" =~ ^[0-9a-f]{16}$ ]]; then
      continue
    fi
    if ! image_users="$(sandboxes_using_image "$image_ref")"; then
      echo "warning: cannot list microsandboxes; keeping $image_ref" >&2
    elif [ -n "$image_users" ]; then
      echo "Keeping $image_ref until these sandboxes are removed: ${image_users//$'\n'/ }" >&2
    elif msb rmi "$image_ref" >&2; then
      echo "Removed old project image: $image_ref" >&2
    else
      echo "warning: cannot remove $image_ref" >&2
    fi
  done <<< "$image_list"
}

# make.sh image project: builds and loads the agent image plus the environment
# of DIR/shell.nix, unless an image for the current base image and shell
# already exists. The tag is NAME:PROJECT-<key>, where NAME is the agent
# image's name and the key identifies the base image and shell derivations
# (systems/agent-computer/project.nix). Loading a new tag removes the
# project's older tags; the agent image itself is never removed. Prints the
# image reference on stdout; everything else goes to stderr.
project_image() {
  local project_dir="$1"
  local project_name="$2"
  local force="$3"
  shift 3

  [ -d "$project_dir" ] || {
    echo "not a directory: $project_dir" >&2
    exit 1
  }
  project_dir="$(cd "$project_dir" && pwd -P)"
  local shell_file="$project_dir/shell.nix"
  [ -f "$shell_file" ] || {
    echo "no shell.nix in $project_dir" >&2
    exit 1
  }
  # The path is part of a docker --mount option on macOS.
  case "$project_dir" in
    *,*|*$'\n'*)
      echo "project paths containing commas or newlines are unsupported: $project_dir" >&2
      exit 1
      ;;
  esac
  if [ -z "$project_name" ]; then
    project_name="$(basename -- "$project_dir" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/_/g; s/^[_-]+//; s/[_-]+$//')"
    project_name="${project_name:0:40}"
  fi
  [[ "$project_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || {
    echo "invalid project image name: '$project_name' (use lowercase letters, digits, '_' and '-')" >&2
    exit 1
  }
  local command_name
  for command_name in code-agent msb jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "$command_name is required to build project images" >&2
      exit 1
    }
  done

  # Project images share the agent image's name, so they are easy to find.
  local agent_image image_name
  agent_image="$(code-agent --print-image)"
  image_name="$agent_image"
  if [[ "$agent_image" =~ ^(.+):[^:/]+$ ]]; then image_name="${BASH_REMATCH[1]}"; fi
  local prefix="$image_name:$project_name-"

  local image_system
  image_system="$(agent_system)"
  build_dir="$(mktemp -d)"
  local darwin=false
  local container_options=()
  if [ "$(uname -s)" = "Darwin" ]; then
    darwin=true
    container_options=(--env "AGENT_PROJECT_SHELL=$shell_file"
      --mount "type=bind,source=$project_dir,target=$project_dir,readonly")
  fi
  local nix_project=(nix --extra-experimental-features "nix-command flakes")
  local project_attr="$DOTFILES_DIR#legacyPackages.$image_system.agent-project"

  # Only evaluates: quick when the image exists already.
  local key
  if [ "$darwin" = true ]; then
    run_in_builder_container "$image_system" "$build_dir/key" "$CONTAINER_PROJECT_SCRIPT" \
      "${container_options[@]}" -- key "$image_system" "$@"
    key="$(cat "$build_dir/key")"
  else
    key="$(AGENT_PROJECT_SHELL="$shell_file" "${nix_project[@]}" eval --impure --raw "$project_attr.key" "$@")"
  fi
  [[ "$key" =~ ^[0-9a-f]{16}$ ]] || {
    echo "unexpected project image key: $key" >&2
    exit 1
  }
  local image_ref="$prefix$key"

  acquire_image_lock
  local image_exists=false
  if image_registered "$image_ref"; then image_exists=true; fi
  if [ "$image_exists" = true ] && [ "$force" = false ]; then
    echo "Using project image $image_ref" >&2
    printf '%s\n' "$image_ref"
    return
  fi
  if [ "$image_exists" = true ]; then require_image_unused "$image_ref"; fi

  echo "Building project image $image_ref for $shell_file..." >&2
  local image_path="$build_dir/project-image.tar"
  if [ "$darwin" = true ]; then
    run_in_builder_container "$image_system" "$image_path" "$CONTAINER_PROJECT_SCRIPT" \
      "${container_options[@]}" --env "AGENT_PROJECT_IMAGE=$image_ref" -- build "$image_system" "$@"
    [ -s "$image_path" ] || {
      echo "container build produced no image" >&2
      exit 1
    }
  else
    # print-dev-env points $out at ./outputs; project.nix rewrites that
    # directory to /workspace/outputs.
    local env_dir="$build_dir/env"
    mkdir "$env_dir"
    (cd "$env_dir" && AGENT_PROJECT_SHELL="$shell_file" "${nix_project[@]}" print-dev-env --impure \
      --profile "$env_dir/profile" "$project_attr.shell" "$@" > "$env_dir/env.sh")
    local image_stream
    image_stream="$(AGENT_PROJECT_SHELL="$shell_file" AGENT_PROJECT_IMAGE="$image_ref" \
      AGENT_PROJECT_ENV="$(readlink -f "$env_dir/profile")" AGENT_PROJECT_ENV_SCRIPT="$env_dir/env.sh" \
      "${nix_project[@]}" build --impure --no-link --print-out-paths "$project_attr.image" "$@")"
    "$image_stream" > "$image_path"
  fi
  if [ "$image_exists" = true ]; then
    msb rmi --force "$image_ref" >&2
  fi
  # The archive also names the image, so msb load registers exactly this tag.
  msb load --input "$image_path" --tag "$image_ref" >&2
  echo "Registered microsandbox image: $image_ref" >&2
  remove_old_project_images "$prefix" "$image_ref"
  printf '%s\n' "$image_ref"
}

mode="${1:-}"
shift || true

case "$mode" in
  "image")
    case "${1:-}" in
      -h|--help|help) usage ;;
    esac
    force=false
    if [ "${1:-}" = "--force" ]; then
      force=true
      shift
    fi
    # agent: the code-agent/infra-agent image. broker: the infra-agent broker.
    # project: the agent image plus a project's shell.nix environment.
    image_kind=agent
    case "${1:-}" in
      agent|broker|project)
        image_kind="$1"
        shift
        ;;
    esac
    if [ "$image_kind" = project ]; then
      [ "$#" -gt 0 ] || usage
      project_dir="$1"
      shift
      project_name=''
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --name)
            [ "$#" -ge 2 ] || usage
            project_name="$2"
            shift 2
            ;;
          --force)
            force=true
            shift
            ;;
          *) break ;;
        esac
      done
      project_image "$project_dir" "$project_name" "$force" "$@"
      exit 0
    fi
    if [ "${1:-}" = "--force" ]; then
      force=true
      shift
    fi
    if [ "$image_kind" = broker ]; then
      image_attr=infra-broker-image
      command -v infra-agent >/dev/null 2>&1 || {
        echo "infra-agent is not installed; enable dotfiles.infraAgent in Home Manager first" >&2
        exit 1
      }
      image_tag="$(infra-agent --print-broker-image)"
    else
      image_attr=agent-image
      command -v code-agent >/dev/null 2>&1 || {
        echo "code-agent is not installed; activate the agent-sandbox Home Manager module first" >&2
        exit 1
      }
      image_tag="$(code-agent --print-image)"
    fi
    command -v msb >/dev/null 2>&1 || {
      echo "microsandbox CLI (msb) is not installed or is not on PATH" >&2
      exit 1
    }
    acquire_image_lock
    image_exists=false
    if image_registered "$image_tag"; then image_exists=true; fi
    if [ "$image_exists" = true ] && [ "$force" = false ]; then
      echo "Microsandbox image already registered: $image_tag" >&2
      echo "Use '$image_command $image_kind --force' to rebuild and replace it." >&2
      exit 0
    fi
    if [ "$image_exists" = true ]; then
      # Check before the slow build.
      command -v jq >/dev/null 2>&1 || {
        echo "jq is required to check which sandboxes use $image_tag" >&2
        exit 1
      }
      require_image_unused "$image_tag"
    fi
    image_system="$(agent_system)"
    build_dir="$(mktemp -d)"
    image_path="$build_dir/$image_attr.tar"
    if [ "$(uname -s)" = "Darwin" ]; then
      build_image_in_container "$image_system" "$image_attr" "$image_path" "$@"
    else
      # The flake attribute already selects the target system; the host
      # architecture matches it, so no --system override is needed. Enable
      # flakes per-invocation so this does not depend on the host nix.conf.
      # The output is a script that streams the image tarball.
      image_stream="$(nix --extra-experimental-features "nix-command flakes" \
        build --no-link --print-out-paths \
        "$DOTFILES_DIR#packages.$image_system.$image_attr" "$@")"
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
