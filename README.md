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

The root `flake.nix` declares every input and lists the outputs. Each system is
defined in `systems/<name>/default.nix`, which receives the flake inputs. The
NixOS systems share their common wiring through `systems/nixos-system.nix`, and
the agent image is defined in `systems/agent-computer/default.nix`. There is one
`flake.lock` for all systems. Per-system flakes are not used, because each one
would have its own lock file and could fall out of sync with the root.

The flake sets `self.submodules = true` so the `private` submodule is included
in the flake source, which needs Nix 2.27 or later. As with any flake in a Git
repository, new files must be added to Git (`git add`) before Nix can see them.

Each NixOS system must name its hardware configuration explicitly with
`hardwareConfiguration` in its `default.nix`. This is the
`nixos-generate-config` output that defines the root and `/boot` filesystems,
initrd modules and swap. If the file is missing, evaluation fails with
instructions for generating it on the machine:

```sh
nixos-generate-config --show-hardware-config > systems/<name>/hardware-configuration.nix
git add systems/<name>/hardware-configuration.nix
```

`make.sh vm` does not need the file. `rpi3` sets `hardwareConfiguration = null`
because its SD card layout defines its filesystems.

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

Build an OCI image for agent sandboxes. The image uses the same zsh, git and
vim configuration as the workstations (Home Manager dotfiles are installed for
the `adamr` user in `/home/adamr`). It includes the core shell tools; the C, Python, Node.js, Rust and JVM
toolchains; and database clients. There are no AWS, Azure or Kubernetes CLIs:
infrastructure access goes through the [Infra Agent](#infra-agent) broker. Its
package set is defined in `systems/agent-computer/home.nix`. Workstation-only
tools are left out (`dotfiles.shell.workstation = false`), as are host
credentials such as the GPG signing key. The image is built for the current host
system and is suitable for loading into microsandbox:

```sh
./make.sh image
```

The `agent-image` flake output is a script that streams the image as an
uncompressed tar (the format `msb load` reads), so a full copy of the image is
never stored in `/nix/store`. `make.sh image` writes the stream to a temporary
file, loads it, and deletes the file.

Every store path is its own image layer (`maxLayers` is above the path count),
so a path's layer is identical in every image built from the same nixpkgs.
microsandbox stores layers once by content, which keeps [project
images](#project-environments-shellnix) cheap: they only add the layers of
their own packages. Docker's 127-layer limit does not apply to microsandbox, but
it does to Docker, so these images are not meant for `docker load`.

On Linux hosts `make.sh image` builds natively with the host's Nix (flakes are
enabled for that invocation, so `nix.conf` changes are not required) and does
not need Docker or trusted-user settings.

On macOS the image contents must still be built on Linux, so `make.sh image`
runs the Nix build inside a pinned `nixos/nix` container and loads the
resulting tarball. This needs a running Docker daemon (for example
`colima start`) and the repository must be in a directory shared with the Docker
VM (colima shares `$HOME` by default; `agent-image`, below, streams its copy of
the source to the container instead). It does not need a Nix Linux builder or
trusted-user settings on the host. The container's `/nix` store is kept in the
Docker volume `dotfiles-agent-image-nix-<system>` so rebuilds are incremental.
After each build the current image (and its build inputs) is kept as a GC root
and everything else in that store is garbage-collected. Remove the volume with
`docker volume rm` to reclaim all of it.

`./make.sh image broker [--force]` builds and loads the infra-agent broker
image (`dotfiles-infra-broker:latest`, see [Infra Agent](#infra-agent)) the
same way; `./make.sh image` is short for `./make.sh image agent`. Both images
share the builder volume, with one GC root each.

The image supports `aarch64-linux` and `x86_64-linux`. To build a specific
system directly on a Linux host (or a host with a Linux builder configured):

```sh
"$(nix build --no-link --print-out-paths .#packages.aarch64-linux.agent-image)" > agent-image.tar
"$(nix build --no-link --print-out-paths .#packages.x86_64-linux.agent-image)" > agent-image.tar
```

The default command starts zsh in `/workspace`. Mount a project directory
there when creating a microsandbox environment.

opencode in the image is configured with a Playwright MCP server
(`~/.config/opencode/opencode.json`), so agents can drive a headless Chromium:
navigate, click, fill forms, read accessibility snapshots and take screenshots.
Each session uses an in-memory browser profile, and files the server writes go
to `/tmp/playwright-mcp`. Chromium and its fonts come from nixpkgs; browsers
that npm-installed Playwright downloads do not run in the image, which has no
FHS dynamic loader. On start the server adds the microsandbox CA to
`~/.pki/nssdb`, because Chromium does not use the system certificate bundle
(see TLS interception below). Pi has no MCP support and does not get the
browser tools.

### Agent Profiles and Skills

Skills are installed per agent type ("profile") rather than for every agent.
All profiles live in the one image, and the launcher chooses which one an agent
uses when it creates the sandbox. `code-agent` uses the `code` profile
(`dotfiles.agentSandbox.agentProfile`).

Skills are plain [Agent Skills](https://agentskills.io/specification)
directories in `skills/<name>/SKILL.md`. The frontmatter must have a `name`
equal to the directory name and a `description` that says when to use the
skill. The `agent-profiles` module declares which skills exist and which
profiles get them, in `systems/agent-computer/home.nix`:

```nix
dotfiles.agentProfiles = {
  skills = {
    task-handover.source = ../../skills/task-handover;
    # Tools the skill runs are installed whenever a profile uses it.
    sql-review = { source = ../../skills/sql-review; packages = [ pkgs.sqlfluff ]; };
    # Third-party skills: add the repository as a `flake = false` input,
    # pass `inputs` to home.nix, and point at the skill's directory.
    # pdf.source = "${inputs.example-skills}/skills/pdf";
  };
  baseSkills = [ ];                                  # added to every profile
  profiles = {
    code.skills = [ "task-handover" ];
    data = {
      skills = [ "sql-review" ];
      opencodeSettings.permission.edit = "deny";     # any opencode config
    };
  };
};
```

Each profile becomes a directory in the image:

```text
~/.config/agent-profiles/<profile>/
  opencode.json      # skills.paths (+ opencodeSettings), selected with OPENCODE_CONFIG
  skills/<skill>/    # the profile's skills, including baseSkills
```

Nothing goes in the directories that agents scan automatically
(`~/.config/opencode/skills`, `~/.agents/skills`, `~/.claude/skills`), so a
skill only reaches the profiles that list it. Pi does not read opencode config.
Point it at a profile explicitly, for example
`ca start -- pi --skill /home/adamr/.config/agent-profiles/code/skills`.

Building the image fails if a profile names a skill that is not in `skills`,
or if a `SKILL.md` has no frontmatter, a different `name`, or no
`description`. Agents would otherwise skip such a skill silently. New skill
files must be tracked by Git (`git add`) before the flake build can see them.
Skills are part of the image, so after changing them rebuild with
`./make.sh image --force` and recreate the sandboxes that should use them.

### Raspberry Pi Images

The Raspberry Pi boots through the GPU firmware, then U-Boot, then extlinux,
using nixos-hardware's `raspberry-pi/3` module. `config.txt` is generated from
`hardware.raspberry-pi.configtxt.settings` in `systems/rpi3/firmware.nix`.

Build an SD card image for the Raspberry Pi configuration. The command prints
the store path; the image is `sd-image/*.img.zst` inside it.

```sh
./make.sh disk-image rpi3
```

The image has a `FIRMWARE` FAT partition holding the firmware files and
`config.txt`, and a `NIXOS_SD` ext4 root partition. After switching, extlinux
entries on the root partition are updated automatically. The firmware partition
is not updated on switch, so after changing `config.txt` or updating nixpkgs,
build and interactively install the firmware onto the `FIRMWARE` partition:

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
code-agent {setup|start|resume} [TASK] [-- COMMAND [ARG...]]
code-agent {stop|status|sync|cleanup} [TASK] [--discard] [--dry-run]
code-agent login
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

This entrypoint covers coding workflows only. Production triage uses
[`infra-agent`](#infra-agent), which follows the same subcommand/help pattern
with its own agent profile (see
[Agent Profiles and Skills](#agent-profiles-and-skills)).

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
agent-image
```

If the tag is already registered, this does nothing. Rebuild and replace it
after changing the image definition or toolchain with `agent-image --force`.
Replacing refuses, before building, while any sandbox was created from the tag;
remove those sandboxes first (for example with `code-agent cleanup`).
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
  rootDisk = "12G";
  networkProfiles = [ "public" ];
  deniedNetworks = [ "172.120.0.0/16" ];
  allowedNetworks = [ ];
  copilotTokenFile = "${config.home.homeDirectory}/development/agent/credentials/github-copilot-token";
  opencodeConfig = { model = "github-copilot/claude-opus-5.5"; };
  agentProfile = "code";
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
| `rootDisk` | `12G` |
| `networkProfiles` | `[ "public" ]` |
| `deniedNetworks` | `[ ]` |
| `allowedNetworks` | `[ ]` |
| `copilotTokenFile` | `null` (no Copilot secret) |
| `opencodeConfig` | `{ autoupdate = false; share = "disabled"; }`, merged with your settings |
| `agentProfile` | `code` (`null` for no profile) |

Activate your Home Manager configuration before building the image.
`agent-image` and `make.sh image` read the configured tag from
`code-agent --print-image`.
Settings are baked into the installed command; environment variables do not
override them. Paths must be absolute, CPUs must be positive, and memory and
root-disk sizes use microsandbox syntax such as `8G` or `512M`.

`agent-image` is installed with `code-agent`. It runs `make.sh image` (taking
the same arguments after `image`) from the copy of this repository in the Nix
store that the active Home Manager generation was built from, so it needs no
checkout and builds the images that the installed configuration defines. Changes
to the image definitions reach it after a switch; to try uncommitted changes,
run `./make.sh image` from the checkout instead.

`networkProfiles` accepts `public`, `private`, and `host`. The default,
`[ "public" ]`, is the Microsandbox default: public internet only, with private
ranges (RFC 1918, Tailscale's `100.64.0.0/10`, IPv6 ULA), loopback, link-local,
cloud metadata, and the host denied. Avoid `private` for agents that handle
untrusted input: it opens every private network the host can reach, including
the LAN, the whole tailnet, and VPN routes.

`allowedNetworks` and `deniedNetworks` take IPv4 or IPv6 addresses and CIDRs
and are passed to `msb create` as `--net-rule` entries, all ports and protocols.
Denies take precedence over allows, and both take precedence over the
profiles. Allowing a private range also lets DNS return private addresses in
it. Use `deniedNetworks` for host-local ranges that Microsandbox would
otherwise classify as public, such as Docker networks outside RFC 1918.

Keep paths and the sandbox prefix unchanged until existing tasks are cleaned
up. CPU, memory, root-disk, network, and image changes apply to newly created
sandboxes, not existing ones.

`opencodeConfig` is passed to new sandboxes as `OPENCODE_CONFIG_CONTENT`. It
takes precedence over a repository's own opencode config. Set `model` there to
pick a default model; otherwise choose one with `/models`.

`agentProfile` selects the image's agent profile for new sandboxes by setting
`OPENCODE_CONFIG=/home/adamr/.config/agent-profiles/<profile>/opencode.json`
and `AGENT_PROFILE=<profile>`. Configuration is layered: the image's global
opencode config, then the profile, then the repository's config, then
`opencodeConfig`. opencode replaces arrays instead of appending to them, so
setting `skills.paths` in `opencodeConfig` would hide the profile's skills, and
Home Manager warns about it. The profile is fixed when the sandbox is created.
opencode silently ignores a missing `OPENCODE_CONFIG`, so `code-agent` refuses
to attach when the image lacks the profile. That happens with an image built
before the profile existed: rebuild it and recreate the sandbox. Sandboxes
created without a profile skip the check.

### Project Environments (shell.nix)

When the host checkout has a `shell.nix` at its root (tracked or ignored), new
sandboxes for it use a project image: the agent image plus that shell's
environment, baked in when the image is built. The sandbox needs neither Nix
nor a network connection for it, and starting a sandbox from an existing project
image costs nothing extra. `code-agent start` runs `agent-image project` before
creating the sandbox, which:

1. Evaluates (without building) the agent image and the shell, and derives a
   key from the two derivations. On macOS this runs in the builder container
   and takes a few seconds.
2. Uses `dotfiles-agent:<repo>-<path hash>-<key>` if it is registered.
3. Otherwise builds and loads it, then removes the repository's other project
   images. Images still used by a sandbox are kept until a later build, because
   `msb rmi --force` would only untag them and leave their storage behind. The
   default image and other repositories' images are never removed.

The shell is rebuilt when `shell.nix` or anything it imports changes the
shell's derivation, and when the agent image definition changes (for example
after `make.sh update`). Existing sandboxes keep the image they were created
with; recreate a task's sandbox to pick up changes. `agent-image` builds from
the dotfiles of the active Home Manager generation, so project images follow
the installed configuration rather than uncommitted changes in a checkout; run
`./make.sh image project` from the checkout to build from it instead.

`<nixpkgs>` in `shell.nix`, and in project files it imports, resolves to the
image's pinned nixpkgs rather than the host's `NIX_PATH`, so the environment
reuses the agent image's packages, and their layers, where it can. A `shell.nix`
that is a function receives `pkgs` and `lib` for the arguments it declares, as
in `{ pkgs ? import <nixpkgs> { } }: pkgs.mkShell { ... }`. Shells that pin
their own nixpkgs work too, but bring their own toolchain.

On attach, `code-agent` sources the environment (`nix print-dev-env` output,
stored in `/etc/agent-project/env.sh`) in bash, which also runs the
`shellHook`, and then starts opencode (or the command after `--`) with
the environment's variables. Commands run by the agent inherit them. The
environment's `PATH` entries come before the image's. `$out` and the other
output variables point at `/workspace/outputs`, as `nix develop` run in the
workspace would set them. Shells that need user namespaces (`buildFHSEnv`) or
host state in their `shellHook` are not supported.

Build or refresh a project image directly with:

```sh
agent-image project ~/src/my-project [--name NAME] [--force]
```

`--name` sets the tag prefix (default: the directory name; `code-agent` passes
`<repo>-<path hash>`). On macOS the project directory must be shared with the
Docker VM. The builder volume keeps only the latest
project image's store paths, so rebuilding an older project's image downloads
its packages again. Project and agent image builds are serialized with the lock
`~/.cache/dotfiles/agent-image.lock`.

### GitHub Copilot Credentials

opencode in the sandbox can use your GitHub Copilot subscription without the
real token ever entering the sandbox. With `copilotTokenFile` set (enabled on
`superposition` and `skyhook`), sign in once on the host:

```sh
code-agent login
```

This runs opencode's GitHub Copilot device sign-in with a throwaway data
directory, so your normal host opencode credentials are untouched. Only the
Copilot token is saved to `copilotTokenFile`, with permissions 600. Run it
again to replace the token. To revoke it, remove the opencode app under GitHub
→ Settings → Applications → Authorized OAuth Apps.

When opencode asks for the deployment type, choose **GitHub.com**. This is
also correct for enterprise accounts that sign in at github.com, such as
enterprise-managed users or Copilot Business/Enterprise seats: their Copilot
requests go to the same `api.githubcopilot.com`. GHE.com data-residency and
self-hosted deployments, which use `copilot-api.<domain>`, are not supported;
`login` refuses them.

One sign-in is active at a time. To switch between a personal and an
enterprise account, run `code-agent login` again and authorize in the browser
as the other account. Sandboxes use the new token from their next start
(`ca stop`, then `ca resume`); there is no need to recreate them. If your
enterprise restricts third-party OAuth apps, an owner may need to approve the
opencode app before the sign-in succeeds.

How the token reaches Copilot:

- New sandboxes are created with the microsandbox secret
  `CODE_AGENT_COPILOT_TOKEN@api.githubcopilot.com`. `code-agent` gives `msb`
  the token only through its environment, never on the command line. msb
  stores a reference to that variable, not the value.
- Inside the sandbox, opencode's `auth.json` holds only the placeholder
  `$MSB_CODE_AGENT_COPILOT_TOKEN`. microsandbox swaps in the real token in
  request headers to `api.githubcopilot.com` and nowhere else, so the agent
  and any code it runs never see the token.
- An existing `auth.json` is left alone, so `/connect` inside a sandbox still
  works for other providers. Connecting Copilot that way puts a real token in
  the sandbox.
- msb reads the token again every time the sandbox starts. A new token takes
  effect on the next start, and starting a Copilot sandbox fails if the token
  file is missing. Running or paused sandboxes don't need it.
- Sandboxes created before `copilotTokenFile` was set keep running without the
  secret. Recreate them (`ca cleanup`, then `ca start`) to add it.
- `code-agent` refuses token files that group or others can read, and token
  files inside the repository, workspace, upstream, or cache directories.

**TLS interception:** microsandbox can only substitute secrets in traffic it
decrypts. Declaring the secret turns on TLS interception for all of the
sandbox's HTTPS on port 443, not just Copilot. The guest is set up to trust the
microsandbox CA through the system bundle, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`,
`REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS`. The Playwright MCP server adds
the CA to Chromium's NSS database (`~/.pki/nssdb`) each time it starts. Clients
with their own trust stores, notably JVM tools (Gradle, Maven, sbt, Coursier),
and clients that pin certificates may fail TLS in Copilot sandboxes. HTTP/3
(QUIC) is not intercepted.

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

`start` and `resume` run `opencode` in `/workspace` by default. Supply a
different command after `--` when needed; its arguments are passed unchanged:

```sh
ca start -- bash
ca resume -- git status
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

`sync` rejects modified or untracked host and agent files and requires the agent
to be on the task branch. Ignored files in the agent workspace are retained and
do not block sync. It bundles committed agent history and fetches it into an
incoming ref, then fast-forwards the corresponding host task branch. If that
branch is checked out here, the index and working files update too. If another
branch is checked out, that checkout stays unchanged. A branch checked out in
another worktree cannot be updated this way.

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

## Infra Agent

`infra-agent` (alias `ia`) runs opencode for production triage, with customer
data in scope, without giving the agent credentials or network access to
infrastructure. It is installed by the `infra-agent` module
(`dotfiles.infraAgent`) and uses three pieces:

```text
host
├─ infra-agent CLI          lifecycle, SSO preflight, audit log
├─ infra-credd              mints short-lived credentials from your host sessions (aws, az, pass)
│     Unix socket ──vsock──┐
├─ VM infra-broker-<env>    MCP gateway + read-only MCP servers (one per environment)
│     egress: only the declared API hostnames, cluster and database CIDR:port pairs
│     gateway published on 127.0.0.1:<port>
│        ▲ http://host.microsandbox.internal:<port>/mcp, one bearer token per incident
└─ VM infra-agent-<incident> opencode with the `infra` profile (dotfiles-agent image)
      egress: only api.githubcopilot.com:443 and the broker port; no DNS for anything else
```

- The VM that reads production data (logs, rows, events — all of which can
  contain prompt injections) has no credentials and no route to infrastructure.
  Its only capability is the broker's read-only, audited tools.
- The VM that holds credentials runs only pinned code from this repository and
  nixpkgs, never the agent's commands, and can reach only the declared
  endpoints. It has no route to the model API or the internet at large.
- Credentials are short-lived, minted from your own SSO sessions on the host, and
  dropped with `ia revoke`.

### Setup

Configure environments in Home Manager, typically in the `private` submodule
for company details. Every network rule is derived from what you declare here:

```nix
dotfiles.infraAgent = {
  enabled = true;
  # copilotTokenFile and the model default to the code-agent settings.
  environments.prod = {
    description = "production";
    vpns = {
      tailscale.check = "tailscale status --peers=false >/dev/null";
      fortinet.check = "ifconfig | grep -q ppp0";     # whatever proves the tunnel is up
    };
    # Optional split DNS for private names (see Network Policy).
    dnsForwarders."privatelink.westeurope.azmk8s.io" = "10.40.0.4";
    aws.accounts.prod = {
      sourceProfile = "sso-prod";                       # host AWS CLI profile (IAM Identity Center)
      roleArn = "arn:aws:iam::111111111111:role/infra-agent-readonly";   # optional, see Credentials
      regions = [ "eu-west-1" ];
    };
    azure = { tenantId = "…"; subscriptions = [ "…" ]; };
    kubernetes.payments = {
      provider = "eks";                                 # eks | aks | command
      server = "https://ABC123.gr7.eu-west-1.eks.amazonaws.com";
      certificateAuthorityData = "LS0t…";
      cidrs = [ "10.20.0.0/16" ];                       # where the API server resolves
      via = "tailscale";
    };
    databases.orders = {
      engine = "postgres";                              # postgres | mysql | mariadb | sqlserver
      host = "orders-replica.cluster-ro-abc.eu-west-1.rds.amazonaws.com";
      port = 5432; database = "orders"; user = "infra_agent_ro";
      auth = "rds-iam";                                 # or password (+ passwordCommand), entra (sqlserver)
      cidrs = [ "10.20.64.0/20" ];
      via = "tailscale";
    };
    datadog = {
      site = "datadoghq.eu";
      apiKeyCommand = "pass show datadog/api-key";
      appKeyCommand = "pass show datadog/app-key-readonly";
    };
  };
};
```

`modules/infra-agent/tests/example.nix` is a complete example (built as
`packages.<system>.infra-agent-example`), and every option is documented in
`modules/infra-agent/default.nix`. Then:

```sh
./make.sh image --force      # the agent image now has the infra profile and skills
./make.sh image broker
code-agent login             # once; the Copilot token is shared with code-agent
```

The host needs the `aws` and `az` CLIs (from `modules/shell` and
`modules/dev.nix`) and whatever your password commands use.

### Usage

```text
infra-agent start INCIDENT [--env ENV] [--skip-preflight] [-- COMMAND...]
infra-agent resume|stop|status INCIDENT
infra-agent cleanup INCIDENT [--keep-workspace] [--dry-run]
infra-agent broker up|down|status|doctor|logs [--env ENV]
infra-agent creds [--env ENV]
infra-agent audit [INCIDENT] [--env ENV] [--follow]
infra-agent revoke [--env ENV]
```

`ia start INC-1234` does everything needed: when the environment's broker is
not running (or its configuration changed) it runs preflight checks, starts
infra-credd, (re)creates the broker and waits for it to be healthy; then it
issues the incident's token, creates or starts the incident VM and attaches
opencode in `/workspace`. Later incidents reuse the running broker, so they
start in seconds. Preflight checks each AWS profile and the Azure tenant
(running `aws sso login` / `az login` interactively when a session has
expired), each VPN's check command, and TCP reachability of every private
target, and reports what is down without stopping.

In opencode the tools are named `infra_<source>_<tool>`, for example
`infra_k8s_pods_log`, `infra_aws_logs_insights`,
`infra_datadog_search_datadog_logs` and `infra_db_execute_sql_orders`. The
`infra-triage` and `incident-report` skills guide the investigation and the
report in `/workspace/report.md`.

`ia cleanup` removes the VM (including opencode's session history, which holds
query results), revokes the incident token and deletes the workspace; use
`--keep-workspace` to keep the report. Incident workspaces contain customer
data: keep `stateDirectory` (default `~/development/agent/infra`) on an
encrypted disk and out of synced or backed-up folders.

### MCP Servers

Each environment's broker runs only the servers its configuration needs, behind
`infra-broker-gateway` (`packages/infra-broker`), which authenticates incident
tokens, allows only listed tools (new tools from upgraded servers stay hidden),
caps result sizes and audits every call.

| Source | Server | Read-only enforcement (besides IAM/RBAC) |
| --- | --- | --- |
| `k8s` | [kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) 0.0.67 | `read_only`, core toolset, Secrets denied, `configuration_view` (returns kubeconfig credentials) disabled |
| `aws` | `infra-aws-mcp` (this repository) | Describe/List/Get-style operations only, a denylist of reads that return secrets or signed URLs, environment values redacted |
| `azure` | [Azure MCP Server](https://github.com/microsoft/mcp) 3.0.0-beta.33 | `--read-only`, only the configured namespaces (default monitor, resourcehealth, aks, group, subscription; no keyvault/appservice, whose read tools return secrets) |
| `db` | [DBHub](https://github.com/bytebase/dbhub) 1.4.0 | `readonly` execute_sql (keyword checks plus read-only transactions), row limits, query timeouts |
| `datadog` | [Datadog MCP](https://docs.datadoghq.com/mcp_server/) (remote) | notebook write tools omitted; use a read-only application key |

The awslabs AWS servers are not used: their current releases pin `awscli` and
`mcp` versions that conflict with nixpkgs, and their read-only mode still
allows `secretsmanager:GetSecretValue`. Datadog's server is remote, so the
gateway proxies it. `extraServers` adds further upstreams (stdio command or
URL) with their own `allowTools`; their hosts need `extraAllowedHosts`.

The real read-only boundary is always the identity: IAM role or permission set,
Kubernetes RBAC (`view` excludes Secrets), Azure Reader roles, a read-only
database user on a replica, and a read-only Datadog key. The MCP checks are
defence in depth.

### Credentials

Nothing secret is stored in an image, a Nix store path or the agent VM.

| Credential | How the broker gets it | Lifetime |
| --- | --- | --- |
| AWS | infra-credd serves the container-credentials protocol (`AWS_CONTAINER_CREDENTIALS_FULL_URI`); SDKs refresh on their own. Per-account profiles (`credential_process`) for DBHub. | ≤ 1 hour |
| Azure | infra-credd emulates the App Service managed-identity endpoint, only for the audiences in `tokenResources` | about 1 hour |
| Kubernetes | kubeconfig exec plugin → infra-credd runs `aws eks get-token` (as the agent's AWS identity) or mints an AKS Entra token | 15–60 minutes |
| Database passwords | `passwordCommand` runs on the host when the broker starts DBHub; `rds-iam` signs tokens in DBHub | per connection |
| Datadog keys | microsandbox secrets: the broker only has `$MSB_…` placeholders, replaced in requests to `mcp.<site>` | until rotated |
| Incident token | random per incident; read from a read-only mount at every attach | until cleanup or revoke |
| Copilot | the code-agent secret | — |

infra-credd caches each credential until five minutes before it expires, logs
every mint to the audit log, refuses Azure audiences outside the allowlist, and
listens on a socket in a 0700 directory that only the broker can reach (as a
vsock route). It never runs `aws sso login` or `az login` itself; preflight
does that in your terminal.

Getting started with your own identity:

- **AWS:** with only `sourceProfile`, the broker uses that SSO session's
  credentials (`aws configure export-credentials`), so use a read-only
  permission set. With `roleArn`, infra-credd assumes the role with a session
  policy (default: deny secret reads and remote execution), a one-hour session
  and `SourceIdentity = infra-agent`, so CloudTrail separates the agent's calls
  from yours.
- **Azure:** tokens come from `az account get-access-token`, so they carry your
  roles. Activate only Reader roles (for example through PIM) before
  triaging; the gateway allowlist is the only write barrier until a dedicated
  identity exists.
- **Kubernetes, databases, Datadog:** as above, use read-only identities and keys.

Moving to dedicated identities: an `infra-agent-readonly` IAM role per account
(ViewOnlyAccess plus CloudWatch Logs reads and explicit denies, trusted by your
SSO role, requiring a SourceIdentity), mapped to the `view` ClusterRole with an
EKS access entry; an Entra service principal or group with Reader, Log
Analytics Reader and AKS RBAC Reader (a principal's certificate stays on the
host and is used only by infra-credd); `infra_agent_ro` database users on
replicas; a Datadog service account with a read-only role. Only
`dotfiles.infraAgent` changes.

### Network Policy

Both VMs are created with `--net-default-egress deny`:

- **Agent:** `allow@<llmHost>:tcp:443` for each `llmHosts` entry and
  `allow@host.microsandbox.internal:tcp:<port>`, `allow@host:tcp:<port>` for
  its broker. There is no general DNS rule, so names other than these do not
  resolve (no DNS tunnelling).
- **Broker:** generated from the configuration (`netRules` in the generated
  `infra-agent.json`):
  - public APIs by hostname on 443: `<service>.<region>.amazonaws.com` for the
    configured services and regions (never `*.amazonaws.com`, which includes
    S3 buckets), `management.azure.com`, `api.loganalytics.io`,
    `mcp.<datadog site>`, plus `extraHosts`/`extraAllowedHosts`;
  - private targets by CIDR and port only, plus their hostname so they resolve
    (microsandbox rejects private DNS answers outside the allowed CIDRs).

Hostname rules need inspectable HTTPS, so both VMs use TLS interception.
Kubernetes API hostnames bypass it, because their kubeconfig pins the cluster
CA; give clusters a hostname, not an IP. If the Fortinet tunnel re-signs public
HTTPS with a corporate CA, add it to `tlsUpstreamCaCerts`.

The broker's traffic leaves through the host's network stack, so it goes
through Tailscale and FortiClient exactly like yours and Tailscale sees it as
your device. That is why rules are per target CIDR:port and never whole
tailnet or VPN ranges. If private names do not resolve from the broker (for
example macOS per-domain resolvers set up by Tailscale or FortiClient), set
`dnsForwarders`: infra-agent then runs dnsmasq on host loopback (port + 1) that
forwards those domains to the given resolvers, and the broker uses it.

### Audit Log and State

```text
<stateDirectory>/
  incidents/<incident>/                 /workspace of the incident VM (customer data)
  .infra-agent/                         0700, never mounted as a whole
    incidents/<incident>.json           environment and sandbox
    incidents/<incident>.run/mcp-token  mounted read-only at /run/infra-agent
    brokers/<env>/run/                  mounted read-only at /run/infra in the broker
      credd-token, tokens/<incident>
    brokers/<env>/credd.sock|.log, dnsmasq.log, broker.hash
    audit/<env>.jsonl
```

The audit log has one JSON line per tool call (incident, tool, arguments)
written before the call runs (calls fail if it cannot be written), one per
result (size, SHA-256, duration, error) and one per credential mint, token
issue, revoke and cleanup. Results themselves are not logged. `ia audit INC-1234
--follow` filters by incident.

### First Run

Some microsandbox behaviour this relies on could not be exercised outside a
real host. On the first start check, in this order:

1. `ia broker doctor` — credd reachable over vsock, credentials minted for each
   AWS account, Azure and cluster, and TCP reachability of every target from
   inside the broker (DNS through `dnsForwarders` if set).
2. `ia start test` — the agent reaches `host.microsandbox.internal:<port>`
   without a DNS rule, and `opencode mcp list` in the VM shows `infra`
   connected. `msb logs <sandbox> --source system` lists denied destinations;
   opencode should only need the Copilot host (models.dev and LSP downloads are
   disabled).
3. File ownership in the read-only mounts (`/run/infra`, `/run/infra-agent`):
   both use `uid=1000,gid=1000` so the guest users can read the 0600 tokens.

### Tests

```sh
bash modules/infra-agent/tests/lifecycle.sh           # CLI with a fake msb and the real infra-credd
python3 -m unittest discover -s modules/infra-agent/tests -p 'test_*.py'   # infra-credd
nix build .#packages.aarch64-linux.infra-broker       # gateway, AWS server and helpers (runs their tests)
nix build .#packages.aarch64-linux.infra-agent-example
```

The lifecycle tests check the security properties of the generated `msb`
commands: the agent VM gets no vsock route, credentials, broker mounts or
infrastructure rules; the broker gets no model API access; secrets reach `msb`
only through its environment; tokens and sockets are private; and revoke
rotates every token.

## Direct Flake Commands

The wrapper covers the common system operations. Other outputs can be used
directly with Nix:

```sh
nix flake show --all-systems
nix build .#nixosConfigurations.skyhook.config.system.build.toplevel
nix build .#nixosConfigurations.rpi3.config.system.build.sdImage
nix build .#packages.aarch64-linux.agent-image  # image stream script
nix build .#packages.aarch64-linux.infra-broker-image
nix build .#packages.aarch64-linux.infra-agent-example  # infra-agent with an example configuration
home-manager switch --flake .#adamr@skyhook-ho
darwin-rebuild switch --flake .#superposition
```
