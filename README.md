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

## Code Agent

The `agent-sandbox` module provides one command for the complete microsandbox
lifecycle, with `ca` as an alias in both Bash and Zsh:

```text
code-agent {setup|start|resume|stop|status|sync|cleanup} TASK [--discard|--dry-run]
```

The flags are valid only for `cleanup`. Run host commands from the original
host Git checkout and quote the task text. Use the same full task text for
every command, not just its normalized ID.

**Before switching:** sync any work in old handover workspaces using the old
commands. The `handover-*` commands are removed from installation. Old
workspaces are left untouched, and the new namespaced layout does not
automatically migrate them.

### Image and Configuration

Build and register the local microsandbox image:

```sh
./make.sh image
```

If the tag is already registered, this does nothing. Rebuild and replace it
after changing the image definition or toolchain with `./make.sh image --force`.
Configure the command through `dotfiles.agentSandbox` in your `home.nix`:

```nix
dotfiles.agentSandbox = {
  enabled = true;
  workspaceDirectory = "${config.home.homeDirectory}/development/agent/workspaces";
  upstreamDirectory = "${config.home.homeDirectory}/development/agent/upstream-ro";
  sandboxPrefix = "code-agent";
  image = "dotfiles-agent:latest";
  cpus = 4;
  memory = "8G";
};
```

Add `config` to your `home.nix` module arguments if using it in these paths.
All settings except `enabled` are optional and have these defaults:

| Option | Default |
| --- | --- |
| `image` | `dotfiles-agent:latest` |
| `upstreamDirectory` | `<homeDirectory>/development/agent/upstream-ro` |
| `workspaceDirectory` | `<homeDirectory>/development/agent/workspaces` |
| `sandboxPrefix` | `code-agent` |
| `cpus` | `4` |
| `memory` | `8G` |

Activate your Home Manager configuration before building the image.
`make.sh image` reads the configured tag from `code-agent --print-image`.
Settings are baked into the installed command; environment variables do not
override them. Paths must be absolute, CPUs must be positive, and memory uses
microsandbox size syntax such as `8G` or `512M`.

Keep paths and the sandbox prefix unchanged until existing tasks are cleaned
up. CPU, memory, and image changes apply to newly created sandboxes, not
existing ones.

Task IDs are lower snake case: `Improve API error handling` becomes
`improve_api_error_handling`. Resource names are repo-scoped using a hash of
the canonical host checkout path and a hash of the full original task text.
Tasks that normalize to the same ID therefore remain distinct, as do separate
host checkouts. The local result branch is
`code-agent/<task-id>-<task-hash>`; use `status` to inspect the resolved paths.

### Setup and Start

Prepare the read-only bare upstream, task metadata, and writable clone:

```sh
code-agent setup "Improve API error handling"
code-agent start "Improve API error handling"
```

`start` also performs setup for a new task, so a separate `setup` is optional.
The initial branch is the current host branch, not necessarily `main`. No
`main` branch is required; a detached host `HEAD` is rejected. Commit or stash
host changes first. Reusing a task keeps its original source snapshot.

The clone is created on the host with `git clone --no-hardlinks`. Only that
task's data directory is mounted read-write at `/workspace`, with the clone
at `/workspace/repo`. The bare upstream is mounted read-only at
`/mnt/upstream.git`; the entire workspace root is not exposed to the sandbox.
Host Git author identity is copied into the clone, but credentials and signing
keys are not. Commit signing is disabled locally in the clone.

The attached shell automatically enters `/workspace/repo`. Launch the agent
yourself and supply its instructions manually; task text is not delivered to
the agent automatically:

```sh
opencode
# After reviewing the changes, commit the files you intend to transfer.
git add path/to/changed-file
git commit -m "Improve API error handling"
exit
```

Commits are required: `sync` transfers committed Git history, not working-tree
changes or the agent's conversation state.

### Stop, Resume, and Status

From the host checkout:

```sh
code-agent status "Improve API error handling"
code-agent stop "Improve API error handling"
code-agent resume "Improve API error handling"
```

`status` outputs the task's paths and `msb ls`. `stop` stops the sandbox but
preserves both the workspace and sandbox state. `resume` reattaches to an
existing sandbox and requires its setup metadata. `start` also resumes an
existing sandbox, so it can be used to return to a task.

### Sync and Review

After committing the work, sync from the original host checkout:

```sh
code-agent sync "Improve API error handling"
```

`sync` rejects a dirty workspace tree, bundles the clone's `HEAD`, and fetches
it into the local result branch `code-agent/<task-id>-<task-hash>`. The branch
update is nonforced: divergent existing results are not overwritten. Nothing
is published to a network remote. Git LFS objects and submodule material are
not automatically transferred; handle those separately if the task needs them.

Review the result against the host branch before merging or publishing. Replace
`<task-hash>` below with the actual hash for this task:

```sh
RESULT_BRANCH='code-agent/improve_api_error_handling-<task-hash>'
git diff HEAD..."$RESULT_BRANCH"
git log --oneline --decorate HEAD.."$RESULT_BRANCH"
```

The agent's `/root` state is not transferred by `sync`.

### Cleanup

Inspect the removal targets without changing anything, then remove the task
when its work has been safely synced:

```sh
code-agent cleanup "Improve API error handling" --dry-run
code-agent cleanup "Improve API error handling"
```

Normal cleanup stops the sandbox first. It refuses removal if the task has
dirty, ignored, or untracked content, or commits reachable from any local
branch, tag, stash, reflog, or `HEAD`, including annotated-tag objects, that are
not present in host refs. Branch names and reflog metadata are not retained.
If it refuses, preserve
the work or explicitly choose to discard it:

```sh
code-agent cleanup "Improve API error handling" --discard
```

`--discard` bypasses these data-loss protections. `--dry-run` only shows targets
and does not stop the sandbox or mutate anything. Cleanup removes the task's
sandbox and workspace, not the shared bare upstream or other tasks. It also
discards the agent's `/root` state, including any conversation or tool state
stored there, even after a successful sync.

### Lifecycle Tests

Run the lifecycle test suite from this repository:

```sh
bash modules/agent-sandbox/tests/lifecycle.sh
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
