# Dotfiles

This repository contains the Nix flake and Home Manager configurations for
the supported machines. The `make.sh` wrapper provides convenient commands
for building, switching, and maintaining those configurations.

## Prerequisites

- Nix with flakes enabled
- A checkout of this repository
- `sudo` for system switching, firmware updates, and garbage collection

On macOS, install `nix-darwin` separately only if it is not already available;
the flake provides its configuration and dependencies.

Run the commands below from any directory. The script resolves the repository
location relative to itself.

## Systems

| System | Platform | Configuration |
| --- | --- | --- |
| `superposition` | macOS / Apple Silicon | `darwinConfigurations.superposition` |
| `spacemonkey` | NixOS / x86_64 | `nixosConfigurations.spacemonkey` |
| `skyhook` | NixOS / x86_64 | `nixosConfigurations.skyhook` |
| `rpi3` | NixOS / aarch64 | `nixosConfigurations.rpi3` |
| `skyhook-ho` | Home Manager / x86_64 | `homeConfigurations."adamr@skyhook-ho"` |
| `agent-image` | OCI / aarch64 or x86_64 Linux | `packages.<system>.agent-image` |

## Commands

### Build

Build a system configuration without activating it. The command prints the
resulting store path.

```sh
./make.sh build skyhook
./make.sh build spacemonkey
./make.sh build rpi3
```

The `superposition` Darwin configuration can also be evaluated directly with
Nix:

```sh
nix build .#darwinConfigurations.superposition.system
```

Additional Nix options can be passed after the system name:

```sh
./make.sh build skyhook --show-trace
```

### Switch

Build and activate the selected system configuration.

```sh
./make.sh switch skyhook
./make.sh switch spacemonkey
./make.sh switch rpi3
```

On macOS, `switch` delegates to `darwin-rebuild`:

```sh
./make.sh switch superposition
```

### Virtual Machine

Build and launch the NixOS VM for a system.

```sh
./make.sh vm skyhook
./make.sh vm spacemonkey
./make.sh vm rpi3
```

This command is intended for the NixOS configurations, not the Darwin
configuration.

### Microsandbox Image

Build an OCI image containing the shell and development packages from this
repository. The image is built for the current host system and is suitable for
loading into microsandbox:

```sh
./make.sh image
```

The image supports `aarch64-linux` and `x86_64-linux`. To build a specific
system directly:

```sh
nix build .#packages.aarch64-linux.agent-image
nix build .#packages.x86_64-linux.agent-image
```

The default command starts zsh in `/workspace`. Mount a project directory
there when creating a microsandbox environment.

### Raspberry Pi Images

Build an SD card image for the Raspberry Pi configuration:

```sh
./make.sh disk-image rpi3
```

Build and interactively install the Raspberry Pi firmware onto the mounted
`FIRMWARE` partition:

```sh
./make.sh firmware rpi3
```

The firmware command mounts `/dev/disk/by-label/FIRMWARE` at `/mnt`, replaces
its contents, and unmounts it after confirmation. Use it only on the intended
Raspberry Pi storage device.

### Update Inputs

Update the flake inputs and write the resulting revisions to `flake.lock`:

```sh
./make.sh update
```

Specific Nix flake update options can be forwarded:

```sh
./make.sh update --update-input nixpkgs
```

### Clean the Store

Remove old Nix garbage and optimise the store:

```sh
./make.sh clean
```

## Agent Handover

The development module provides `handover-setup`, `handover-start`, and
`handover-sync` for passing work between a host repository and an agent
workspace.

The microsandbox image can be built and registered with one command:

```sh
./make.sh image
```

If `dotfiles-agent:latest` is already registered, this command does nothing.
Rebuild and replace the registered image after changing the image definition
or toolchain with:

```sh
./make.sh image --force
```

Set `MSB_AGENT_IMAGE` to use a different local image tag.

From the original host repository, create or update the read-only bare
upstream and prepare a task workspace:

```sh
handover-setup "Improve API error handling"
```

The task ID is normalized to `improve_api_error_handling`. By default, the
bare upstream is stored under `~/development/agent/upstream-ro` and the task
workspace under `~/development/agent/workspaces`. Override those locations
with:

```sh
export HANDOVER_UPSTREAM_DIR="$HOME/path/to/upstreams"
export HANDOVER_WORKSPACES_DIR="$HOME/path/to/workspaces"
```

The setup command prints the bare repository path and the clone command to use
inside the agent:

```sh
git clone --no-hardlinks \
  "$HOME/development/agent/upstream-ro/dotfiles.git" \
  "$HOME/development/agent/workspaces/improve_api_error_handling/dotfiles"
```

After the agent commits its work in that writable clone, return to the original
host repository and fetch the result:

```sh
handover-sync "Improve API error handling"
```

This creates a bundle from the workspace repository's `HEAD` and fetches it
into a local branch named `improve_api_error_handling`. Review it before
publishing:

```sh
git diff main...improve_api_error_handling
git log --oneline --decorate main..improve_api_error_handling
```

`handover-sync` discovers either a repository directly in the task workspace
or the standard nested clone path. It does not push anything to a network
remote.

To create the upstream, start a microsandbox, mount the bare repository
read-only, mount the workspace root read-write, and attach an interactive
shell in one step:

```sh
handover-start "Improve API error handling"
```

The default sandbox name is `dotfiles-agent-improve_api_error_handling`, the
image is `dotfiles-agent:latest`, and the sandbox uses 4 CPUs and 8 GiB of
memory. Override these defaults with:

```sh
export HANDOVER_IMAGE=dotfiles-agent:latest
export HANDOVER_CPUS=4
export HANDOVER_MEMORY=8G
export HANDOVER_SANDBOX_PREFIX=dotfiles-agent
```

Inside the attached sandbox, clone the mounted upstream into the writable
workspace. `handover-start` performs this setup automatically. The resulting
repository is ready for an agent:

```sh
TASK=improve_api_error_handling
REPO=dotfiles
git clone --no-hardlinks \
  "/mnt/upstream/$REPO.git" \
  "/workspace/$TASK/$REPO"
cd "/workspace/$TASK/$REPO"
git switch -c "$TASK" origin/main
git config remote.origin.pushurl /dev/null
opencode
```

Exit the shell when finished, commit the work in the sandbox, and run
`handover-sync` from the original host repository.

When the work is no longer needed, remove the microsandbox and that task's
workspace repository:

```sh
handover-cleanup "Improve API error handling"
```

This uses the same sandbox prefix and workspace location as `handover-start`
and does not remove the bare upstream repository or any other task workspace.

## Direct Flake Commands

The wrapper covers the common system operations. Other outputs can be used
directly with Nix:

```sh
nix flake show --all-systems
nix build .#nixosConfigurations.skyhook.config.system.build.toplevel
nix build .#nixosConfigurations.rpi3.config.system.build.sdImage
nix build .#packages.aarch64-linux.agent-image
home-manager switch --flake .#adamr@skyhook-ho
darwin-rebuild switch --flake .#superposition
```
