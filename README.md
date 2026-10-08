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

On Linux hosts `make.sh image` builds natively with the host's Nix (flakes are
enabled for that invocation, so `nix.conf` changes are not required) and does
not need Docker or trusted-user settings.

On macOS the image contents must still be built on Linux, so `make.sh image`
runs the Nix build inside a `nixos/nix` container and loads the resulting
tarball. This needs a running Docker daemon (for example `colima start`) and
the repository must be in a directory shared with the Docker VM (colima shares
`$HOME` by default). It does not need a Nix Linux builder or trusted-user
settings on the host. The container's `/nix` store is kept in the Docker volume
`dotfiles-agent-image-nix-<system>` so rebuilds are incremental; remove it with
`docker volume rm` to reclaim space.

The image supports `aarch64-linux` and `x86_64-linux`. To build a specific
system directly on a Linux host (or a host with a Linux builder configured):

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
lifecycle, with `ca` as an alias in both Bash and Zsh. It is enabled on
`superposition` (macOS) and `skyhook` (Linux) and behaves the same on both. It
needs the microsandbox CLI (`msb`) on `PATH`. On `superposition` it is installed
through Homebrew, but on Linux you have to install it yourself, and microsandbox
needs access to `/dev/kvm`.

```text
code-agent {setup|start|resume|stop|status|sync|cleanup} [TASK] [--discard] [--dry-run]
code-agent help [COMMAND]
```

`code-agent` is the single entrypoint; `ca` is only its shell alias, not a
separate implementation. Each lifecycle operation is a subcommand with its
own help:

```sh
ca help
ca help start
ca start --help
ca sync -h
ca cleanup help
```

No arguments shows general help. Help works outside a repository, requires no
running sandbox, and does not create branches or change task state. Invalid
commands or options exit with status 2. `help`, `--help`, and `-h` are reserved
help arguments, not task names.

This entrypoint currently covers coding workflows only. Future `triage-agent`
and `data-agent` commands can use the same subcommand/help pattern with their
own workflows; neither is implemented or installed yet.

The flags are valid only for `cleanup`. Run host commands from the original
host Git checkout. Without a task name, the current branch identifies the task.
On `main`, `setup` and `start` prompt for a task branch; other commands require
switching to the task branch or passing a name explicitly.

**Before switching:** sync any work in old handover workspaces using the old
commands. The `handover-*` commands are removed from installation. Old
workspaces are left untouched, and the new namespaced layout does not
automatically migrate them.

Tasks created by the earlier `code-agent` workflow also use the old identity
and result-branch layout. Sync and clean those tasks with the previous command
version before activating this branch-based workflow; their files are not migrated.

Tasks created before the flat workspace layout (under
`<workspaceDirectory>/code-agent/repo-<hash>/…/data/repo`) are not migrated
either. `code-agent` refuses to operate on such a task and names its old
directory; sync and clean it up with the previous version first. Once every old
task is gone, the leftover `<workspaceDirectory>/code-agent` and
`<upstreamDirectory>/code-agent` directories can be deleted.

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
  cacheDirectory = "${config.home.homeDirectory}/development/agent/package-cache";
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
| `cacheDirectory` | `<homeDirectory>/development/agent/package-cache` |
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

### Shared Package Cache

New sandboxes mount `cacheDirectory` read-write at `/cache`. All tasks and
repositories using that directory reuse downloads, and task cleanup never
removes the cache. Use a dedicated agent cache, not your normal host package
directories. It must not overlap the host repository, workspace, or upstream
directories.

| Tool | Shared Location Inside Sandbox |
| --- | --- |
| uv | `/cache/uv` (copy link mode for cross-volume installs) |
| npm | `/cache/npm` |
| pip | `/cache/pip` |
| Yarn (versions honoring `YARN_CACHE_FOLDER`) | `/cache/yarn` |
| pnpm (versions honoring `npm_config_store_dir`) | `/cache/pnpm` |
| Bun | `/cache/bun` |
| Go modules and build cache | `/cache/go-mod`, `/cache/go-build` |
| Coursier | `/cache/coursier` |
| Cargo | `/root/.cargo/registry`, `/root/.cargo/git` |
| Gradle | `/root/.gradle/caches`, `/root/.gradle/wrapper` |
| Maven | `/root/.m2/repository` |
| Ivy | `/root/.ivy2/cache` |

Cache environment variables are configured on sandbox creation. Credentials,
user configuration, and home directories are not shared wholesale. Only the
listed subdirectories are mounted: Cargo credentials/config, Gradle properties,
and Maven settings remain private. Gradle caches can nevertheless contain
compiled project scripts (including embedded secrets) and cached task outputs.
Do not use this shared cache across trust boundaries.
Project dependencies, virtualenvs, and Cargo target outputs remain task-local.
These settings do not install additional package
managers or make the Nix store writable/shared. Project-specific tool settings
can override cache locations.

Existing sandboxes retain their original mounts and environment. To enable
caching for an old sandbox, preserve/sync its work, clean it up, and start a
new task sandbox. Keep `cacheDirectory` unchanged until its tasks are cleaned up.

For Python projects, run `uv sync --locked` normally inside each task. When
`uv.lock` introduces a new package version, its first use populates the shared
cache. Later VMs with compatible Python/platform/cache versions can reuse the
artifact without downloading it again. HTTP revalidation, cache-format changes,
explicit refreshes, and missing artifacts can still cause network requests.
Each task keeps its own `.venv`; `UV_LINK_MODE=copy` avoids cross-volume hardlinks
and keeps installed files independent of cached artifacts. Managed Python
installations and `uv tool` environments are not shared by this configuration.

Multiple task VMs can use the cache simultaneously. uv documents its artifact
cache as append-only and safe for concurrent readers/writers; npm's content cache
also supports lockless concurrency. Simultaneous first-time downloads or builds
may duplicate work, but subsequent tasks reuse populated entries. This is not
a promise of exactly one download or build across VMs. Other package managers
may rely on locks that are not visible across VMs and can corrupt shared caches.
Cargo's package-cache lock files also remain private. On every start/resume,
`code-agent` warns if another VM is Running or Starting, but does not block.
The check conservatively includes unrelated VMs and is best-effort, not a
concurrency guarantee; concurrent starts or later external state changes can
race the check. Do not enable centralized
shared uv project environments: installation-target locks must stay task-local.

Every agent with this mount can read, modify, or delete the cache, including
cached executable artifacts. This trades isolation for reuse: do not share it
across trust boundaries or put secrets there. Microsandbox directory mounts
do not coordinate file locks across guests. Therefore, stop every cache-using
VM before `uv cache clean`, `uv cache prune`, npm cache cleaning, or manual
maintenance; uv's normal cleanup locks cannot coordinate across these VMs.
Never delete uv cache entries manually while agents are running. There is no
global VM lease, automatic eviction, or cache-delete subcommand.

If corruption occurs, stop all cache users, clear the affected cache with its
package manager (or reset the dedicated host cache directory), then retry the
install/build to repopulate it. Recreate any task environment or build output
that consumed bad artifacts. Keep the mounted directory roots present and do
not clear caches while VMs are running.

See [uv cache safety](https://docs.astral.sh/uv/concepts/cache/#cache-safety).

### Task Selection

Explicit task names are normalized to lower snake case: `Improve API error
handling` selects branch `improve_api_error_handling`. Names that normalize to
the same branch identify the same task. Without a name, the current branch is
used unchanged, including slashes such as `feature/api`. For such branches,
switch to the branch and omit the task argument in subsequent commands.

### Workspace Layout

Each task is a single folder named `<repo>-<hash>-<task>`. `<repo>` is the host
checkout's directory name, and `<hash>` is a short hash of its absolute path, so
same-named checkouts in different places stay separate:

```text
<workspaceDirectory>/
  dotfiles-1a2b3c4d-improve_api/              # task clone, mounted at /workspace
  .code-agent/dotfiles-1a2b3c4d-improve_api.state
  .code-agent/dotfiles-1a2b3c4d-improve_api.lock/   # only while a command runs
<upstreamDirectory>/
  dotfiles-1a2b3c4d.git                       # read-only bare upstream, shared per checkout
sandbox: <sandboxPrefix>-dotfiles-1a2b3c4d-improve_api
```

Task metadata and locks live in the hidden `.code-agent` directory, which is
never mounted into a sandbox. Task names longer than 40 characters are
truncated and end with a short hash of the branch name. Different branches
that normalize to the same name, such as `Feature/X` and `feature_x`, would
share a folder. The second one is refused with an error naming the branch that
already uses it; choose a different task name.

### Setup and Start

Prepare the read-only bare upstream, task metadata, and writable clone:

```sh
ca start
# Or create/select a named branch and start its task:
ca start "Improve API error handling"
```

`start` also performs setup for a new task, so a separate `setup` is optional.
With an explicit name, `setup` and `start` switch to its normalized branch if
it exists, or create it from the current branch if it does not. On `main`, an
omitted name prompts for a branch instead of handing over `main` itself.
No `main` branch is required; detached host `HEAD` is rejected.

`setup`, `start`, `resume`, and `sync` require a clean host working tree and
index, including no untracked files. Ignored host files are allowed and are
not transferred. The command never auto-stashes or commits. Commit or stash
changes first. Reusing a task keeps its original agent clone and source snapshot;
new host commits are not automatically applied inside an existing clone.

The clone is created on the host with `git clone --no-hardlinks`. Only that
task's clone is mounted read-write, at `/workspace`. The bare upstream is
mounted read-only at `/mnt/upstream.git`; the rest of the workspace root,
including task metadata, is not exposed to the sandbox.
Host Git author identity is copied into the clone, but credentials and signing
keys are not. Commit signing is disabled locally in the clone.

The attached shell automatically enters `/workspace`. Launch the agent
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
ca status
ca stop
ca resume
```

`status` outputs the task's paths and `msb ls`. `stop` stops the sandbox but
preserves both the workspace and sandbox state. `resume` reattaches to an
existing sandbox and requires its setup metadata. `start` also resumes an
existing sandbox, so it can be used to return to a task.

### Sync and Review

After committing the work, sync from the original host checkout:

```sh
ca sync
```

`sync` rejects a dirty host or agent tree and requires the agent to be on the
task branch. It bundles committed agent history and fetches it into an incoming
ref, then fast-forwards the corresponding host task branch. If that branch is
checked out here, the index and working files update too. If another branch is
checked out, that checkout stays unchanged. A branch checked out in another
worktree cannot be updated this way.

If the histories diverge, sync stops without modifying the task branch and
prints the incoming ref where the agent commits were preserved. Merge or rebase
manually; no force update or automatic conflict resolution is performed.
Incoming refs are retained as recovery points. Nothing is published to a network
remote. Git LFS objects and submodule material are not automatically transferred.

Review the task branch against `main` before merging or publishing:

```sh
git diff main...HEAD
git log --oneline --decorate main..HEAD
```

The agent's `/root` state is not transferred by `sync`.

### Cleanup

Inspect the removal targets without changing anything, then remove the task
when its work has been safely synced:

```sh
ca cleanup --dry-run
ca cleanup
```

Normal cleanup stops the sandbox first. It refuses removal if the task has
dirty, ignored, or untracked content, or commits reachable from any local
branch, tag, stash, reflog, or `HEAD`, including annotated-tag objects, that are
not present in host refs. Branch names and reflog metadata are not retained.
If it refuses, preserve
the work or explicitly choose to discard it:

```sh
ca cleanup --discard
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
