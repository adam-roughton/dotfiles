---
name: task-handover
description: Hands finished work in /workspace back to the host operator. Use when finishing a task, before saying work is done, or when the user mentions code-agent sync, handover, or a blocked sync.
---

# Task handover

The host imports agent work with `code-agent sync`. It fast-forwards the host
task branch to the committed `HEAD` of `/workspace`, and only that. Uncommitted
changes never reach the host.

## Before reporting the task as done

1. Confirm you are on the task branch that `/workspace` was cloned on
   (`git branch --show-current`). Do not switch branches or rebase onto `main`.
2. Commit the intended changes with a descriptive message. Prefer small,
   reviewable commits over one large commit when the work has distinct steps.
3. Run `git status --porcelain --untracked-files=all --ignored`.
   `code-agent sync` refuses to run unless this prints nothing, which includes
   ignored files such as `.venv/`, `node_modules/`, `target/` and build output.
   - Remove build outputs and environments that you created and that the
     project can regenerate.
   - Do not delete files you did not create, or anything that cannot be
     regenerated. List them for the operator instead.
4. Do not push. `origin` is a read-only snapshot and its push URL is
   `/dev/null`; the host pulls work out of the sandbox.

## Final message

Include:

- the commits made (`git log --oneline <start>..HEAD`),
- checks or tests run and their results,
- anything left in `git status --ignored` and why, since it blocks sync,
- follow-ups or open questions.
