# Agent Environment Rules

This is a disposable agent environment. Treat the mounted host repository as
read-only source material.

## Repository Workspaces

- Do not edit, delete, or create files inside a repository mounted read-only
  from the host.
- When a mounted repository is the source for a task, clone it into a writable
  directory under `/workspace` before making changes.
- Work only in the writable clone. Verify the current directory and its write
  permissions before editing.
- Preserve the source repository's remotes and branch history unless the task
  explicitly requests otherwise.
- Keep generated files, build artifacts, and temporary files inside the
  writable workspace or `/tmp`.

## Safety

- Do not attempt to remount host paths read-write or bypass the mount policy.
- Do not access host credentials, SSH keys, cloud configuration, or password
  stores unless the task explicitly provides a safe mechanism for doing so.
- Do not commit or publish changes unless explicitly asked.
- Before destructive commands, confirm the target is inside the writable
  workspace.

## Package Caches

- When `/cache` is mounted, package managers use shared caches automatically.
  Use the project's lockfile normally; for uv projects prefer `uv sync --locked`.
- Keep virtualenvs, installed dependencies, and project build outputs inside the
  task workspace. Do not enable shared centralized uv project environments.
- Shared Cargo, Gradle, Maven, Ivy, and other caches may be corrupted by
  concurrent VMs because cross-VM file locks are not coordinated. Report cache
  errors to the host operator rather than silently deleting or repairing caches.
- Other agents may be using the cache. Do not run cache clean/prune commands or
  manually modify/delete cache entries. Ask the host operator to stop all cache
  users before maintenance.
- Do not put credentials or other secrets in the shared cache.
- Gradle caches can retain compiled project scripts and embedded secret values;
  do not embed credentials in build scripts.

## Project Environment

- If `/etc/agent-project/env.sh` exists, this sandbox was built with the
  project's `shell.nix` environment, and your commands already run inside it
  (`IN_NIX_SHELL` is set). Do not source it again.
- Nix is not available here. Changes to `shell.nix` take effect only in a new
  sandbox; if the project needs tools the environment lacks, report it to the
  host operator.

## Containers

- `docker` is provided by rootless, daemonless Podman; `docker compose` is
  provided by podman-compose. Container images, volumes, and networks are local
  to this disposable sandbox.
- Do not start a privileged container or use host networking, host PID/IPC
  namespaces, or bind mounts outside `/workspace`. These are incompatible with
  the sandbox isolation model.

## Agent Changes

- Inspect the repository and its existing instructions before editing.
- Prefer small, focused changes and run relevant tests or checks afterward.
- Report blockers instead of modifying read-only inputs or weakening sandbox
  restrictions.
