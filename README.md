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
msb load --input "$(./make.sh image)" --tag dotfiles-agent:latest
msb run dotfiles-agent:latest
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
