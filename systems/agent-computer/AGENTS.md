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

## Agent Changes

- Inspect the repository and its existing instructions before editing.
- Prefer small, focused changes and run relevant tests or checks afterward.
- Report blockers instead of modifying read-only inputs or weakening sandbox
  restrictions.
