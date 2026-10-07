#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$TEST_DIR/lifecycle.sh"
SCRIPT="$(cd -- "$TEST_DIR/../scripts" && pwd -P)/code-agent"

fail() { printf 'FAIL: %s\n%s\n' "$*" "${OUTPUT:-}" >&2; exit 1; }
equal() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
contains() { [[ "$1" == *"$2"* ]] || fail "missing [$2] in [$1]"; }
exists() { [ -e "$1" ] || fail "missing path: $1"; }
absent() { if [ -e "$1" ] || [ -L "$1" ]; then fail "unexpected path: $1"; fi; }

agent() { (cd -- "$HOST" && bash "$SCRIPT" "$@"); }
ok() { OUTPUT="$(agent "$@" 2>&1)" || fail "command failed: $*"; }
reject() {
  local reason="$1"
  shift
  if OUTPUT="$(agent "$@" 2>&1)"; then fail "command unexpectedly succeeded: $*"; fi
  contains "$OUTPUT" "$reason"
}
field() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$1: "* ]]; then printf '%s\n' "${line#*: }"; return; fi
  done <<< "$OUTPUT"
  fail "missing output field: $1"
}
setup() {
  TASK="${1:-test task}"
  ok setup "$TASK"
  CLONE="$(field Workspace)"
  BRANCH="$(field Branch)"
  SANDBOX="$(field Sandbox)"
  UPSTREAM="$(field Upstream)"
  DATA="${CLONE%/repo}"
  TASK_DIR="${DATA%/data}"
  META="$TASK_DIR/state"
}
new_repo() {
  HOST="$1"
  mkdir -p "$HOST"
  git init -q -b "${2:-main}" "$HOST"
  git -C "$HOST" config user.name 'Lifecycle Test'
  git -C "$HOST" config user.email lifecycle@example.invalid
  git -C "$HOST" config commit.gpgsign false
  git -C "$HOST" config tag.gpgsign false
  printf 'base\n' > "$HOST/tracked"
  printf 'ignored\n' > "$HOST/.gitignore"
  git -C "$HOST" add .
  git -C "$HOST" commit -qm base
  git -C "$HOST" switch -qc feature
  printf 'feature\n' >> "$HOST/tracked"
  git -C "$HOST" commit -qam feature
}
commit_work() {
  printf '%s\n' "${1:-agent work}" >> "$CLONE/tracked"
  git -C "$CLONE" commit -qam "${1:-agent work}"
}
logged() {
  local expected line
  printf -v expected '%q ' "$@"
  while IFS= read -r line; do [ "$line" != "$expected" ] || return 0; done < "$FAKE_MSB_LOG"
  fail "missing msb invocation: $expected"
}
count_command() {
  local line count=0
  while IFS= read -r line; do
    if [[ "$line" == "$1 "* ]]; then count=$((count + 1)); fi
  done < "$FAKE_MSB_LOG"
  printf '%s\n' "$count"
}
preserved() {
  exists "$CLONE/.git"
  exists "$META"
  absent "$TASK_DIR/lock"
}
snapshot() {
  local path
  # Compare persistent file contents, not directory mtimes changed by locking.
  for path in "$TASK_DIR"/** "$FAKE_MSB_STATE"/**; do
    [ ! -f "$path" ] || sha256sum "$path"
  done
}

roundtrip() {
  local source host_head
  source="$(git -C "$HOST" rev-parse HEAD)"
  setup 'Round Trip'
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$(git config --file "$META" --get task.sourceBranch)" feature
  equal "$(git -C "$CLONE" branch --show-current)" "$BRANCH"
  equal "$(git -C "$CLONE" config commit.gpgsign)" false
  equal "$(git -C "$CLONE" config tag.gpgsign)" false
  equal "$(git -C "$CLONE" config remote.origin.url)" /mnt/upstream.git
  equal "$(git -C "$CLONE" config remote.origin.pushurl)" /dev/null
  equal "$(count_command create)" 0
  ok start "$TASK"
  logged create --name "$SANDBOX" --cpus 4 --memory 8G \
    --volume "$UPSTREAM:/mnt/upstream.git:ro" --volume "$DATA:/workspace" dotfiles-agent:latest
  logged exec --tty "$SANDBOX" -- zsh -c 'cd /workspace/repo && exec zsh'
  commit_work
  host_head="$(git -C "$HOST" rev-parse HEAD)"
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$BRANCH")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$host_head"
  equal "$(git -C "$HOST" branch --show-current)" feature
  ok cleanup "$TASK"
  logged stop "$SANDBOX"
  logged rm --force "$SANDBOX"
  absent "$TASK_DIR"
  absent "$FAKE_MSB_STATE/$SANDBOX"
  exists "$UPSTREAM"
  git -C "$HOST" show-ref --verify --quiet "refs/heads/$BRANCH"
}

reuse() {
  setup
  ok start "$TASK"
  commit_work
  local head
  head="$(git -C "$CLONE" rev-parse HEAD)"
  ok stop "$TASK"
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Stopped
  ok resume "$TASK"
  ok start "$TASK"
  equal "$(count_command create)" 1
  equal "$(count_command start)" 1
  equal "$(count_command resume)" 0
  logged inspect "$SANDBOX" --format json
  equal "$(count_command exec)" 3
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$head"
  ok status "$TASK"
  contains "$OUTPUT" "$SANDBOX"
  logged ls
  rm -- "$FAKE_MSB_STATE/$SANDBOX"
  reject 'sandbox is absent' resume "$TASK"
  equal "$(count_command create)" 1
  ok start "$TASK"
  equal "$(count_command create)" 2
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$head"
}

mount_isolation() {
  setup first
  local first_clone="$CLONE" first_data="$DATA" first_upstream="$UPSTREAM" first_sandbox="$SANDBOX"
  ok start "$TASK"
  setup second
  ok start "$TASK"
  [ "$DATA" != "$first_data" ] || fail 'tasks share writable mount'
  equal "$UPSTREAM" "$first_upstream"
  logged create --name "$first_sandbox" --cpus 4 --memory 8G \
    --volume "$UPSTREAM:/mnt/upstream.git:ro" --volume "$first_data:/workspace" dotfiles-agent:latest
  logged create --name "$SANDBOX" --cpus 4 --memory 8G \
    --volume "$UPSTREAM:/mnt/upstream.git:ro" --volume "$DATA:/workspace" dotfiles-agent:latest
  ok cleanup "$TASK"
  exists "$first_clone/.git"
  exists "$FAKE_MSB_STATE/$first_sandbox"
}

repo_identity() {
  setup same
  local first_clone="$CLONE" first_branch="$BRANCH" first_sandbox="$SANDBOX" first_upstream="$UPSTREAM"
  new_repo "$CASE/another/project"
  setup same
  [ "$CLONE" != "$first_clone" ] || fail 'same basenames share workspace'
  [ "$SANDBOX" != "$first_sandbox" ] || fail 'same basenames share sandbox'
  [ "$UPSTREAM" != "$first_upstream" ] || fail 'same basenames share upstream'
  equal "$BRANCH" "$first_branch"
  exists "$first_clone/.git"
}

task_identity() {
  setup 'Same Task'
  local first_clone="$CLONE" first_branch="$BRANCH" first_sandbox="$SANDBOX"
  setup same-task
  [ "$CLONE" != "$first_clone" ] || fail 'normalized tasks share workspace'
  [ "$BRANCH" != "$first_branch" ] || fail 'normalized tasks share branch'
  [ "$SANDBOX" != "$first_sandbox" ] || fail 'normalized tasks share sandbox'
  contains "$BRANCH" code-agent/same_task-
  contains "$first_branch" code-agent/same_task-
  equal "$(git config --file "$META" --get task.name)" same-task
}

main_task() {
  git -C "$HOST" switch -q main
  setup main
  equal "$(git config --file "$META" --get task.sourceBranch)" main
  [ "$BRANCH" != main ] || fail 'task branch collides with main'
  ok start "$TASK"
  commit_work
  ok sync "$TASK"
  ok cleanup "$TASK"
}

rebased_source() {
  setup before-rebase
  local old_clone="$CLONE" old_head
  old_head="$(git -C "$CLONE" rev-parse HEAD)"
  printf 'rebased\n' >> "$HOST/tracked"
  git -C "$HOST" commit -qam rebased --amend
  setup after-rebase
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$HOST" rev-parse HEAD)"
  equal "$(git -C "$old_clone" rev-parse HEAD)" "$old_head"
  git -C "$UPSTREAM" show-ref --verify --quiet "refs/heads/snapshot-$old_head"
  setup before-rebase
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$old_head"
}

host_rejection() {
  case "$CASE_NAME" in
    detached_host) git -C "$HOST" switch -q --detach; reject 'detached HEAD' setup rejected ;;
    dirty_host) printf 'dirty\n' >> "$HOST/tracked"; reject 'commit or stash host changes' setup rejected ;;
    untracked_host) printf 'untracked\n' > "$HOST/untracked"; reject 'commit or stash host changes' setup rejected ;;
  esac
  equal "$(count_command create)" 0
  local states=("$CODE_AGENT_WORKSPACES_DIR"/**/state)
  equal "${#states[@]}" 0
}

cleanup_work() {
  setup
  ok start "$TASK"
  local reason
  case "$CASE_NAME" in
    dirty_cleanup) printf 'dirty\n' >> "$CLONE/tracked"; reason='modified, untracked, or ignored' ;;
    untracked_cleanup) printf 'untracked\n' > "$CLONE/untracked"; reason='modified, untracked, or ignored' ;;
    ignored_cleanup) printf 'ignored\n' > "$CLONE/ignored"; reason='modified, untracked, or ignored' ;;
    unsynced_cleanup) commit_work; reason='Git objects are not preserved' ;;
    other_branch_cleanup)
      git -C "$CLONE" switch -qc other
      commit_work 'other branch work'
      git -C "$CLONE" switch -q "$BRANCH"
      ok sync "$TASK"
      reason='Git objects are not preserved'
      ;;
    reflog_cleanup)
      local base lost
      base="$(git -C "$CLONE" rev-parse HEAD)"
      commit_work 'reflog only'
      lost="$(git -C "$CLONE" rev-parse HEAD)"
      git -C "$CLONE" reset -q --hard "$base"
      equal "$(git -C "$CLONE" for-each-ref --contains "$lost")" ''
      contains "$(git -C "$CLONE" reflog --format=%H)" "$lost"
      reason='Git objects are not preserved'
      ;;
    stash_cleanup)
      printf 'stashed tracked work\n' >> "$CLONE/tracked"
      printf 'stashed untracked work\n' > "$CLONE/stash-only"
      git -C "$CLONE" stash push -qu -m 'preserve stash objects'
      git -C "$CLONE" rev-parse --verify refs/stash >/dev/null
      reason='Git objects are not preserved'
      ;;
    annotated_tag_cleanup)
      git -C "$CLONE" tag -a agent-tag -m 'agent annotation'
      equal "$(git -C "$CLONE" cat-file -t refs/tags/agent-tag)" tag
      ok sync "$TASK"
      reason='Git objects are not preserved'
      ;;
    extra_file_cleanup) printf 'extra\n' > "$DATA/extra"; reason='workspace contains extra files' ;;
  esac
  local before
  before="$(snapshot)"
  reject "$reason" cleanup "$TASK"
  preserved
  equal "$(count_command rm)" 0
  # Cleanup may stop the VM before refusing, but must retain all work.
  equal "$(snapshot | while IFS= read -r line; do [[ "$line" == *"$FAKE_MSB_STATE/"* ]] || printf '%s\n' "$line"; done)" \
    "$(while IFS= read -r line; do [[ "$line" == *"$FAKE_MSB_STATE/"* ]] || printf '%s\n' "$line"; done <<< "$before")"
  ok cleanup "$TASK" --discard
  absent "$TASK_DIR"
  absent "$FAKE_MSB_STATE/$SANDBOX"
}

lifecycle_failure() {
  setup
  ok start "$TASK"
  local operation="${CASE_NAME%_failure}" before
  before="$(snapshot)"
  export FAKE_MSB_FAIL="$operation"
  reject "${operation} failure" cleanup "$TASK" --discard
  preserved
  exists "$FAKE_MSB_STATE/$SANDBOX"
  if [ "$operation" != rm ]; then equal "$(count_command rm)" 0; fi
  if [ "$operation" = ls ]; then
    equal "$(count_command stop)" 0
    equal "$(snapshot)" "$before"
    reject 'cannot list microsandboxes' cleanup "$TASK" --dry-run
    reject 'cannot list microsandboxes' start "$TASK"
    equal "$(count_command create)" 1
  fi
  unset FAKE_MSB_FAIL
  ok cleanup "$TASK" --discard
  absent "$TASK_DIR"
}

symlink_refusal() {
  setup
  local target link
  case "$CASE_NAME" in
    symlink_parent) link="${TASK_DIR%/*}" ;;
    symlink_clone) link="$CLONE" ;;
    symlink_git) link="$CLONE/.git" ;;
  esac
  target="$CASE/symlink-target"
  mv -- "$link" "$target"
  ln -s -- "$target" "$link"
  reject 'symlinked' setup "$TASK"
  reject 'symlinked' sync "$TASK"
  reject 'symlinked' cleanup "$TASK" --discard
  exists "$target"
  [ -L "$link" ] || fail 'symlink removed'
  equal "$(count_command ls)" 0
  equal "$(count_command rm)" 0
}

dry_run() {
  setup
  ok start "$TASK"
  commit_work
  printf 'ignored\n' > "$CLONE/ignored"
  local before
  before="$(snapshot)"
  ok cleanup "$TASK" --dry-run
  contains "$OUTPUT" 'No work-preservation checks performed'
  equal "$(snapshot)" "$before"
  ok cleanup "$TASK" --discard --dry-run
  equal "$(snapshot)" "$before"
  equal "$(count_command stop)" 0
  equal "$(count_command rm)" 0
  preserved
  rm -- "$FAKE_MSB_STATE/$SANDBOX"
  before="$(snapshot)"
  ok cleanup "$TASK" --dry-run
  equal "$(snapshot)" "$before"
}

partial_initialization() {
  setup
  local head
  head="$(git -C "$CLONE" rev-parse HEAD)"
  git config --file "$META" --unset task.ready
  reject 'initialization incomplete' resume "$TASK"
  ok setup "$TASK"
  equal "$(git config --file "$META" --get task.ready)" true
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$head"
  equal "$(git -C "$CLONE" branch --show-current)" "$BRANCH"
  git config --file "$META" --unset task.ready
  ok start "$TASK"
  equal "$(count_command create)" 1
  commit_work
  git config --file "$META" --unset task.ready
  reject 'incomplete initialization contains work' setup "$TASK"
  preserved
}

checked_out_destination() {
  setup
  commit_work
  ok sync "$TASK"
  git -C "$HOST" switch -q "$BRANCH"
  local head
  head="$(git -C "$HOST" rev-parse HEAD)"
  commit_work 'second commit'
  reject 'checked out' sync "$TASK"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
  preserved
}

no_main() {
  new_repo "$CASE/no-main/project" trunk
  if git -C "$HOST" show-ref --verify --quiet refs/heads/main; then fail 'fixture has main'; fi
  setup
  ok start "$TASK"
  commit_work
  ok sync "$TASK"
  ok cleanup "$TASK"
  absent "$TASK_DIR"
}

lock_refusal() {
  setup
  mkdir "$TASK_DIR/lock"
  local action
  for action in setup start resume stop status sync cleanup; do
    reject 'task is locked' "$action" "$TASK"
    exists "$TASK_DIR/lock"
    exists "$META"
  done
  reject 'task is locked' cleanup "$TASK" --discard
  reject 'task is locked' cleanup "$TASK" --dry-run
  equal "$(count_command ls)" 0
  rmdir "$TASK_DIR/lock"
  ok cleanup "$TASK"
}

wrong_branch() {
  setup
  git -C "$CLONE" switch -qc wrong
  commit_work
  reject 'not on the expected task branch' sync "$TASK"
  if git -C "$HOST" show-ref --verify --quiet "refs/heads/$BRANCH"; then fail 'sync created destination'; fi
  preserved
  git -C "$CLONE" switch -q --detach
  reject 'not on the expected task branch' sync "$TASK"
}

paused_lifecycle() {
  setup
  ok start "$TASK"
  printf 'Paused\n' > "$FAKE_MSB_STATE/$SANDBOX"
  ok resume "$TASK"
  logged resume "$SANDBOX"
  equal "$(count_command start)" 0
  equal "$(count_command create)" 1
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  printf 'Paused\n' > "$FAKE_MSB_STATE/$SANDBOX"
  ok start "$TASK"
  equal "$(count_command resume)" 2
  equal "$(count_command start)" 0
  printf 'Paused\n' > "$FAKE_MSB_STATE/$SANDBOX"
  ok stop "$TASK"
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Stopped
  equal "$(count_command resume)" 3
  printf 'Paused\n' > "$FAKE_MSB_STATE/$SANDBOX"
  ok cleanup "$TASK"
  equal "$(count_command resume)" 4
  absent "$TASK_DIR"
  absent "$FAKE_MSB_STATE/$SANDBOX"
}

transition_failure() {
  setup
  ok start "$TASK"
  local operation="${CASE_NAME%_failure}" state=Running before
  case "$operation" in start) state=Stopped ;; resume) state=Paused ;; esac
  printf '%s\n' "$state" > "$FAKE_MSB_STATE/$SANDBOX"
  before="$(snapshot)"
  export FAKE_MSB_FAIL="$operation"
  reject "${operation} failure" start "$TASK"
  reject "${operation} failure" resume "$TASK"
  preserved
  equal "$(snapshot)" "$before"
  equal "$(count_command exec)" 1
  equal "$(count_command create)" 1
  equal "$(count_command rm)" 0
  if [ "$operation" != start ]; then
    reject "${operation} failure" cleanup "$TASK" --discard
    preserved
    equal "$(snapshot)" "$before"
    equal "$(count_command stop)" 0
    equal "$(count_command rm)" 0
  fi
  unset FAKE_MSB_FAIL
  ok cleanup "$TASK" --discard
}

transition_verification() {
  setup
  ok start "$TASK"
  export FAKE_MSB_NO_TRANSITION=stop
  reject 'sandbox did not stop' cleanup "$TASK" --discard
  preserved
  equal "$(count_command rm)" 0
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  printf 'Stopped\n' > "$FAKE_MSB_STATE/$SANDBOX"
  export FAKE_MSB_NO_TRANSITION=start
  reject 'sandbox did not start' resume "$TASK"
  equal "$(count_command exec)" 1
  printf 'Paused\n' > "$FAKE_MSB_STATE/$SANDBOX"
  export FAKE_MSB_NO_TRANSITION=resume
  reject 'sandbox did not start' start "$TASK"
  equal "$(count_command exec)" 1
  unset FAKE_MSB_NO_TRANSITION
  printf 'Starting\n' > "$FAKE_MSB_STATE/$SANDBOX"
  reject 'transitioning or has unknown status' start "$TASK"
  reject 'transitioning or has unknown status' cleanup "$TASK" --discard
  equal "$(count_command rm)" 0
  preserved
}

signed_push() {
  git -C "$HOST" config push.gpgSign true
  setup
  equal "$(git -C "$HOST" config push.gpgSign)" true
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$HOST" rev-parse HEAD)"
  absent "${UPSTREAM%.git}.lock"
}

concurrent_setup() {
  local first second source first_clone
  source="$(git -C "$HOST" rev-parse HEAD)"
  agent setup concurrent-first > "$CASE/first.out" 2>&1 &
  first=$!
  agent setup concurrent-second > "$CASE/second.out" 2>&1 &
  second=$!
  if ! wait "$first"; then OUTPUT="$(< "$CASE/first.out")"; fail 'first concurrent setup failed'; fi
  if ! wait "$second"; then OUTPUT="$(< "$CASE/second.out")"; fail 'second concurrent setup failed'; fi
  OUTPUT="$(< "$CASE/first.out")"
  first_clone="$(field Workspace)"
  equal "$(git -C "$first_clone" rev-parse HEAD)" "$source"
  OUTPUT="$(< "$CASE/second.out")"
  CLONE="$(field Workspace)"
  UPSTREAM="$(field Upstream)"
  [ "$CLONE" != "$first_clone" ] || fail 'concurrent tasks share workspace'
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$(git -C "$UPSTREAM" rev-parse "refs/heads/snapshot-$source")" "$source"
  git -C "$UPSTREAM" fsck --no-dangling >/dev/null 2>&1
  absent "${UPSTREAM%.git}.lock"
  absent "${first_clone%/data/repo}/lock"
  absent "${CLONE%/data/repo}/lock"
}

interactive_lock() {
  setup
  export FAKE_MSB_EXEC_LOCK="$TASK_DIR/lock"
  export FAKE_MSB_EXEC_SCRIPT="$SCRIPT" FAKE_MSB_EXEC_TASK="$TASK"
  ok start "$TASK"
  logged ls
  preserved
  ok resume "$TASK"
  equal "$(count_command exec)" 2
  equal "$(count_command ls)" 4
  equal "$(count_command start)" 0
  equal "$(count_command create)" 1
}

if [ "${1:-}" = --case ]; then
  CASE_NAME="$2"
  CASE="$3"
  shopt -s globstar nullglob dotglob
  mkdir -p "$CASE/bin" "$CASE/msb-state" "$CASE/home" "$CASE/tmp"
  export HOME="$CASE/home" TMPDIR="$CASE/tmp" GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$CASE/gitconfig"
  export CODE_AGENT_WORKSPACES_DIR="$CASE/workspaces"
  export CODE_AGENT_UPSTREAM_DIR="$CASE/upstream"
  export CODE_AGENT_SANDBOX_PREFIX=code-agent CODE_AGENT_CPUS=4 CODE_AGENT_MEMORY=8G
  export CODE_AGENT_IMAGE=dotfiles-agent:latest
  export FAKE_MSB_STATE="$CASE/msb-state" FAKE_MSB_LOG="$CASE/msb.log"
  unset FAKE_MSB_FAIL FAKE_MSB_NO_TRANSITION FAKE_MSB_EXEC_LOCK FAKE_MSB_EXEC_SCRIPT FAKE_MSB_EXEC_TASK
  : > "$FAKE_MSB_LOG"
  # The tracked fixture need not have its executable bit set.
  cp -- "$TEST_DIR/fake-msb" "$CASE/bin/msb"
  chmod +x "$CASE/bin/msb"
  export PATH="$CASE/bin:$PATH"
  new_repo "$CASE/repositories/project"
  case "$CASE_NAME" in
    detached_host|dirty_host|untracked_host) host_rejection ;;
    dirty_cleanup|untracked_cleanup|ignored_cleanup|unsynced_cleanup|other_branch_cleanup|extra_file_cleanup|reflog_cleanup|stash_cleanup|annotated_tag_cleanup) cleanup_work ;;
    ls_failure|stop_failure|rm_failure) lifecycle_failure ;;
    inspect_failure|start_failure|resume_failure) transition_failure ;;
    symlink_parent|symlink_clone|symlink_git) symlink_refusal ;;
    *) "$CASE_NAME" ;;
  esac
  exit 0
fi

[ "$#" = 0 ] || fail 'usage: bash modules/agent-sandbox/tests/lifecycle.sh'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/code-agent-lifecycle.XXXXXXXX")"
trap 'rm -rf -- "$ROOT"' EXIT
tests=(roundtrip reuse mount_isolation repo_identity task_identity main_task rebased_source
  detached_host dirty_host untracked_host dirty_cleanup untracked_cleanup ignored_cleanup
  unsynced_cleanup other_branch_cleanup extra_file_cleanup ls_failure stop_failure rm_failure
  symlink_parent symlink_clone symlink_git dry_run partial_initialization
  checked_out_destination no_main lock_refusal wrong_branch paused_lifecycle
  inspect_failure start_failure resume_failure transition_verification reflog_cleanup
  stash_cleanup annotated_tag_cleanup signed_push concurrent_setup interactive_lock)
passed=0
failed=0
for test in "${tests[@]}"; do
  if bash "$SELF" --case "$test" "$ROOT/$test"; then
    printf 'PASS %s\n' "$test"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test"
    failed=$((failed + 1))
  fi
done
printf '\nResults: %d passed, %d failed, %d total\n' "$passed" "$failed" "${#tests[@]}"
[ "$failed" = 0 ]
