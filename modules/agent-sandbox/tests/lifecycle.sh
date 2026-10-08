#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$TEST_DIR/lifecycle.sh"
TEMPLATE="$(cd -- "$TEST_DIR/../scripts" && pwd -P)/code-agent"

fail() { printf 'FAIL: %s\n%s\n' "$*" "${OUTPUT:-}" >&2; exit 1; }
equal() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
contains() { [[ "$1" == *"$2"* ]] || fail "missing [$2] in [$1]"; }
exists() { [ -e "$1" ] || fail "missing path: $1"; }
absent() { if [ -e "$1" ] || [ -L "$1" ]; then fail "unexpected path: $1"; fi; }

agent() { (cd -- "$HOST" && bash "$SCRIPT" "$@"); }
ok() { OUTPUT="$(agent "$@" 2>&1)" || fail "command failed: $*"; }
ok_attach() {
  local before
  before="$(count_command exec)"
  agent "$@" > "$CASE/attach.out" 2> "$CASE/attach.err" || { OUTPUT="$(< "$CASE/attach.err")"; fail "attach failed: $*"; }
  OUTPUT="$(< "$CASE/attach.out")"
  STDERR="$(< "$CASE/attach.err")"
  [[ "$OUTPUT" != *WARNING:* ]] || fail 'cache warning emitted on stdout'
  equal "$(count_command exec)" "$((before + 1))"
}
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
  task_fields
}
task_fields() {
  TASK="$(field Task)"
  CLONE="$(field Workspace)"
  BRANCH="$(field Branch)"
  SANDBOX="$(field Sandbox)"
  UPSTREAM="$(field Upstream)"
  equal "$(field Cache)" "$CACHE"
  META="$(meta_of "$CLONE")"
  LOCK="$(lock_of "$CLONE")"
  STATE_DIR="${CLONE%/*}/.code-agent"
}
# Task metadata and locks live in the workspace root's hidden .code-agent directory.
meta_of() { printf '%s/.code-agent/%s.state\n' "${1%/*}" "${1##*/}"; }
lock_of() { printf '%s/.code-agent/%s.lock\n' "${1%/*}" "${1##*/}"; }
removed() {
  absent "$CLONE"
  absent "$META"
  absent "$LOCK"
}
short_hash() { local hash; hash="$(printf '%s' "$1" | sha256sum)"; printf '%s\n' "${hash:0:$2}"; }
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
expected_create() {
  logged create --name "${1:-$SANDBOX}" --cpus "${3:-4}" --memory "${4:-8G}" \
    --volume "$UPSTREAM:/mnt/upstream.git:ro" --volume "${2:-$CLONE}:/workspace" \
    --volume "$CACHE:/cache" \
    --volume "$CACHE/cargo/registry:/root/.cargo/registry" \
    --volume "$CACHE/cargo/git:/root/.cargo/git" \
    --volume "$CACHE/gradle/caches:/root/.gradle/caches" \
    --volume "$CACHE/gradle/wrapper:/root/.gradle/wrapper" \
    --volume "$CACHE/maven/repository:/root/.m2/repository" \
    --volume "$CACHE/ivy:/root/.ivy2/cache" \
    --env PIP_CACHE_DIR=/cache/pip \
    --env UV_CACHE_DIR=/cache/uv --env UV_LINK_MODE=copy \
    --env npm_config_cache=/cache/npm --env YARN_CACHE_FOLDER=/cache/yarn \
    --env npm_config_store_dir=/cache/pnpm --env BUN_INSTALL_CACHE_DIR=/cache/bun \
    --env GOMODCACHE=/cache/go-mod --env GOCACHE=/cache/go-build \
    --env COURSIER_CACHE=/cache/coursier "${5:-dotfiles-agent:latest}"
}
render() {
  local template index value
  template="$(< "$TEMPLATE")"
  values[6]="$CACHE"
  for index in "${!keys[@]}"; do
    printf -v value '%q' "${values[$index]}"
    template="${template//\@${keys[$index]}\@/$value}"
  done
  printf '%s\n' "$template" > "$SCRIPT"
  chmod +x "$SCRIPT"
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
  absent "$LOCK"
}
snapshot() {
  local path
  # Compare persistent file contents, not directory mtimes changed by locking.
  for path in "$CLONE"/** "$META" "$FAKE_MSB_STATE"/**; do
    [ ! -f "$path" ] || sha256sum "$path"
  done
}

roundtrip() {
  local source
  source="$(git -C "$HOST" rev-parse HEAD)"
  setup 'Round Trip'
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$BRANCH" round_trip
  equal "$(git config --file "$META" --get task.sourceBranch)" "$BRANCH"
  equal "$(git -C "$HOST" branch --show-current)" "$BRANCH"
  equal "$(git -C "$CLONE" branch --show-current)" "$BRANCH"
  equal "$(git -C "$CLONE" config commit.gpgsign)" false
  equal "$(git -C "$CLONE" config tag.gpgsign)" false
  equal "$(git -C "$CLONE" config remote.origin.url)" /mnt/upstream.git
  equal "$(git -C "$CLONE" config remote.origin.pushurl)" /dev/null
  equal "$(count_command create)" 0
  absent "$CACHE"
  ok start "$TASK"
  expected_create
  logged exec --tty "$SANDBOX" -- zsh -c 'cd /workspace && exec zsh'
  commit_work
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$BRANCH")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" branch --show-current)" "$BRANCH"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
  ok cleanup "$TASK"
  logged stop "$SANDBOX"
  logged rm --force "$SANDBOX"
  removed
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
  local first_clone="$CLONE" first_mount="$CLONE" first_upstream="$UPSTREAM" first_sandbox="$SANDBOX"
  ok start "$TASK"
  setup second
  ok start "$TASK"
  [ "$CLONE" != "$first_mount" ] || fail 'tasks share writable mount'
  equal "$UPSTREAM" "$first_upstream"
  expected_create "$first_sandbox" "$first_mount"
  expected_create
  ok cleanup "$TASK"
  exists "$first_clone/.git"
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
}

cache_sharing() {
  setup first
  ok_attach start "$TASK"
  [[ "$STDERR" != *WARNING:* ]] || fail 'single VM warned about itself'
  expected_create
  local first_sandbox="$SANDBOX" first_clone="$CLONE" first_cache cache line destination
  local caches=(pip uv npm yarn pnpm bun go-mod go-build coursier cargo/registry cargo/git gradle/caches gradle/wrapper maven/repository ivy)
  first_cache="$(field Cache)"
  # Exact create arguments above must not expose credential/config parents or files.
  while IFS= read -r line; do
    [[ "$line" == 'create '* ]] || continue
    for destination in /root /root/.cargo /root/.gradle /root/.m2 /root/.ivy2 \
      /root/.cargo/credentials /root/.cargo/credentials.toml /root/.cargo/config.toml \
      /root/.gradle/gradle.properties /root/.m2/settings.xml /root/.ivy2/ivysettings.xml \
      /root/.npmrc /root/.yarnrc.yml; do
      [[ "$line" != *":$destination "* && "$line" != *":$destination:ro "* ]] || fail "mounted private path: $destination"
    done
  done < "$FAKE_MSB_LOG"
  for cache in cargo/registry cargo/git gradle/caches gradle/wrapper maven/repository ivy; do exists "$CACHE/$cache"; done
  # Simulate downloads in every configured cache, including the nested mounts.
  for cache in "${caches[@]}"; do
    mkdir -p "$CACHE/$cache"
    printf '%s package\n' "$cache" > "$CACHE/$cache/downloaded"
  done
  setup second
  ok_attach start "$TASK"
  contains "$STDERR" "WARNING: Other VMs are running: $first_sandbox"
  contains "$STDERR" 'cross-VM file locks are not coordinated'
  contains "$STDERR" 'This warning does not block startup.'
  [[ "$STDERR" != *"$SANDBOX"* ]] || fail 'warning included current VM'
  expected_create
  equal "$(field Cache)" "$first_cache"
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  equal "$(count_command create)" 2
  ok stop first
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Stopped
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  ok_attach resume first
  contains "$STDERR" "WARNING: Other VMs are running: $SANDBOX"
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  ok_attach resume "$TASK"
  contains "$STDERR" "WARNING: Other VMs are running: $first_sandbox"
  equal "$(count_command create)" 2
  ok stop first
  ok_attach resume "$TASK"
  [[ "$STDERR" != *WARNING:* ]] || fail 'stopped VM triggered warning'
  printf 'Paused\n' > "$FAKE_MSB_STATE/$first_sandbox"
  ok_attach resume "$TASK"
  [[ "$STDERR" != *WARNING:* ]] || fail 'paused VM triggered warning'
  printf 'Running\n' > "$FAKE_MSB_STATE/unrelated-vm"
  ok_attach resume "$TASK"
  contains "$STDERR" 'WARNING: Other VMs are running: unrelated-vm'
  [[ "$STDERR" != *"$first_sandbox"* ]] || fail 'warning included paused VM'
  printf 'Starting\n' > "$FAKE_MSB_STATE/unrelated-vm"
  ok_attach resume "$TASK"
  contains "$STDERR" 'WARNING: Other VMs are running: unrelated-vm'
  export FAKE_MSB_FAIL_INSPECT_NAME=unrelated-vm
  ok_attach resume "$TASK"
  contains "$STDERR" 'WARNING: Cannot inspect VM unrelated-vm; shared cache concurrency risk is unknown.'
  logged inspect unrelated-vm --format json
  unset FAKE_MSB_FAIL_INSPECT_NAME
  rm -- "$FAKE_MSB_STATE/unrelated-vm"
  ok_attach resume first
  contains "$STDERR" "WARNING: Other VMs are running: $SANDBOX"
  ok cleanup "$TASK"
  removed
  exists "$first_clone/.git"
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
  for cache in "${caches[@]}"; do equal "$(< "$CACHE/$cache/downloaded")" "$cache package"; done
  setup first
  ok cleanup "$TASK" --discard
  removed
  absent "$FAKE_MSB_STATE/$first_sandbox"
  for cache in "${caches[@]}"; do equal "$(< "$CACHE/$cache/downloaded")" "$cache package"; done
  setup second
  ok start "$TASK"
  expected_create
  equal "$(count_command create)" 3
  for cache in "${caches[@]}"; do equal "$(< "$CACHE/$cache/downloaded")" "$cache package"; done
}

cache_reuse() {
  setup
  local uncreated_cache="$CACHE"
  if git config --file "$META" --get task.cacheDirectory; then fail 'setup pinned cache before creation'; fi
  CACHE="$CASE/created-cache"
  render
  ok start "$TASK"
  expected_create
  absent "$uncreated_cache"
  local original_cache="$CACHE" action before
  equal "$(git config --file "$META" --get task.cacheDirectory)" "$original_cache"
  before="$(snapshot)"
  CACHE="$CASE/reconfigured-cache"
  values[3]=reconfigured-agent:latest
  values[4]=2
  values[5]=512M
  render
  for action in start resume stop cleanup; do
    reject 'cache directory differs from task setup; restore it before stopping or cleaning up' "$action" "$TASK"
    equal "$(git config --file "$META" --get task.cacheDirectory)" "$original_cache"
    equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
    absent "$CACHE"
    preserved
  done
  CACHE="$original_cache"
  render
  equal "$(snapshot)" "$before"
  ok stop "$TASK"
  exists "$CACHE"
  ok resume "$TASK"
  ok start "$TASK"
  equal "$(count_command create)" 1
  exists "$CACHE"
  rm -- "$FAKE_MSB_STATE/$SANDBOX"
  ok start "$TASK"
  expected_create "$SANDBOX" "$CLONE" 2 512M reconfigured-agent:latest
  equal "$(count_command create)" 2
  exists "$CACHE"
  ok cleanup "$TASK"
  removed
  exists "$CACHE"
}

cache_lazy_creation() {
  ok --help
  absent "$CACHE"
  ok --print-image
  absent "$CACHE"
  setup
  absent "$CACHE"
  if git config --file "$META" --get task.cacheDirectory; then fail 'setup pinned cache before creation'; fi
  ok cleanup "$TASK" --dry-run
  absent "$CACHE"
  ok cleanup "$TASK" --discard --dry-run
  absent "$CACHE"
  ok cleanup "$TASK"
  absent "$CACHE"
  equal "$(count_command create)" 0
  setup symlinked-cache
  local cache target="$CASE/cache-symlink-target"
  mkdir -p "$target"
  printf 'untouched\n' > "$target/marker"
  for cache in cargo/registry cargo/git gradle/caches gradle/wrapper maven/repository ivy; do
    mkdir -p "$CACHE/$(dirname "$cache")"
    # Earlier refusal attempts may have created preceding cache subdirectories.
    if [ -d "$CACHE/$cache" ]; then rmdir "$CACHE/$cache"; fi
    ln -s -- "$target" "$CACHE/$cache"
    reject 'refusing symlinked package cache directory' start "$TASK"
    equal "$(count_command create)" 0
    if git config --file "$META" --get task.cacheDirectory; then fail 'symlink refusal pinned cache'; fi
    equal "$(< "$target/marker")" untouched
    [ -L "$CACHE/$cache" ] || fail 'cache symlink removed'
    preserved
    rm -- "$CACHE/$cache"
  done
  ok start "$TASK"
  expected_create
}

cache_start_failure() {
  setup
  local operation="${CASE_NAME#cache_start_failure_}" first_sandbox="$SANDBOX" first_meta="$META"
  export FAKE_MSB_FAIL="$operation"
  reject "$operation failure" start "$TASK"
  preserved
  if [ "$operation" = ls ]; then
    absent "$CACHE"
    if git config --file "$META" --get task.cacheDirectory; then fail 'inspection failure pinned cache before creation'; fi
  fi
  unset FAKE_MSB_FAIL
  setup second
  ok start "$TASK"
  expected_create
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  exists "$first_meta"
  if [ "$operation" = inspect ] || [ "$operation" = exec ]; then
    equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
  else
    absent "$FAKE_MSB_STATE/$first_sandbox"
  fi
  ok start test_task
  equal "$(< "$FAKE_MSB_STATE/$first_sandbox")" Running
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
}

cache_missing_resume() {
  setup
  reject 'sandbox is absent' resume "$TASK"
  absent "$CACHE"
  if git config --file "$META" --get task.cacheDirectory; then fail 'missing resume pinned cache before creation'; fi
  equal "$(count_command create)" 0
  ok stop "$TASK"
  absent "$CACHE"
}

cache_overlap() {
  local private relation root before
  private="${CASE_NAME#cache_overlap_}"
  relation="${private##*_}"
  private="${private%_*}"
  case "$private" in
    repo) root="$HOST" ;;
    workspace) values[0]="$CASE/private-workspace/root"; root="${values[0]}" ;;
    upstream) values[1]="$CASE/private-upstream/root"; root="${values[1]}" ;;
  esac
  case "$relation" in
    equal) CACHE="$root" ;;
    descendant) CACHE="$root/package-cache" ;;
    ancestor) CACHE="$(dirname "$root")" ;;
  esac
  render
  before="$(git -C "$HOST" show-ref)"
  reject 'package cache must not overlap the host repository, workspace, or upstream directories' start rejected
  equal "$(count_command create)" 0
  equal "$(count_command ls)" 0
  equal "$(git -C "$HOST" show-ref)" "$before"
  absent "${values[0]}"
  absent "${values[1]}"
  if [ "$relation" = descendant ]; then absent "$CACHE"; fi
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
  equal "$CLONE" "$first_clone"
  equal "$BRANCH" "$first_branch"
  equal "$SANDBOX" "$first_sandbox"
  equal "$BRANCH" same_task
  equal "$(git config --file "$META" --get task.name)" same_task
}

readable_layout() {
  local repo_key entries
  repo_key="project-$(short_hash "$(realpath -e "$HOST")" 8)"
  setup 'Improve API'
  equal "$CLONE" "$CASE/workspaces/$repo_key-improve_api"
  equal "$META" "$CASE/workspaces/.code-agent/$repo_key-improve_api.state"
  equal "$UPSTREAM" "$CASE/upstream/$repo_key.git"
  equal "$SANDBOX" "code-agent-$repo_key-improve_api"
  equal "$(git -C "$CLONE" rev-parse --show-toplevel)" "$CLONE"
  # The workspace root holds only task clones and the hidden state directory.
  entries="$(cd -- "$CASE/workspaces" && printf '%s\n' *)"
  equal "$entries" "$(printf '%s\n' .code-agent "$repo_key-improve_api")"
  ok start "$TASK"
  expected_create
  logged exec --tty "$SANDBOX" -- zsh -c 'cd /workspace && exec zsh'
  # Repository names are normalized for paths and sandbox names.
  new_repo "$CASE/odd/My.Repo Name!"
  setup 'Improve API'
  equal "${CLONE##*/}" "my_repo_name-$(short_hash "$(realpath -e "$HOST")" 8)-improve_api"
  equal "${SANDBOX}" "code-agent-${CLONE##*/}"
}

task_name_clash() {
  git -C "$HOST" switch -qc 'Feature/X'
  ok setup
  task_fields
  equal "$BRANCH" Feature/X
  [[ "$CLONE" == *-feature_x ]] || fail "unexpected workspace name: $CLONE"
  local before refs action
  before="$(snapshot)"
  refs="$(git -C "$HOST" show-ref)"
  for action in setup start resume stop status sync cleanup; do
    reject "is already used by branch 'Feature/X'; choose a different task name" "$action" feature_x
    equal "$(git -C "$HOST" branch --show-current)" Feature/X
    equal "$(git -C "$HOST" show-ref)" "$refs"
    equal "$(snapshot)" "$before"
  done
  absent "$LOCK"
  equal "$(count_command create)" 0
}

long_task_names() {
  local prefix='a very long task name that keeps going past the limit' first_clone name
  setup "$prefix one"
  first_clone="$CLONE"
  name="${CLONE##*/}"
  equal "${name#project-*-}" "a_very_long_task_name_that_keep-$(short_hash "${prefix// /_}_one" 8)"
  setup "$prefix two"
  [ "$CLONE" != "$first_clone" ] || fail 'long task names share a workspace'
  name="${CLONE##*/}"
  equal "${name#project-*-}" "a_very_long_task_name_that_keep-$(short_hash "${prefix// /_}_two" 8)"
  exists "$first_clone/.git"
  # Exactly 40 characters keeps the readable name without a hash.
  setup 'abcdefghi abcdefghi abcdefghi abcdefghij'
  name="${CLONE##*/}"
  equal "${name#project-*-}" abcdefghi_abcdefghi_abcdefghi_abcdefghij
}

legacy_layout() {
  local legacy refs
  legacy="$CASE/workspaces/code-agent/repo-$(short_hash "$(realpath -e "$HOST")" 12)/test_task-$(short_hash test_task 12)"
  mkdir -p "$legacy/data/repo"
  printf '[task]\n\tname = test_task\n' > "$legacy/state"
  refs="$(git -C "$HOST" show-ref)"
  for action in setup start resume stop status sync cleanup; do
    reject "task uses the old workspace layout: $legacy" "$action" 'Test Task'
    contains "$OUTPUT" 'Sync and clean it up with the previous code-agent version first'
    equal "$(git -C "$HOST" branch --show-current)" feature
    equal "$(git -C "$HOST" show-ref)" "$refs"
  done
  absent "$CASE/workspaces/.code-agent"
  absent "$CASE/upstream"
  equal "$(count_command ls)" 0
  exists "$legacy/state"
  # Other tasks in the same repository are unaffected.
  setup other
  exists "$CLONE/.git"
}

main_task() {
  git -C "$HOST" switch -q main
  local action source
  source="$(git -C "$HOST" rev-parse HEAD)"
  for action in setup start resume stop status sync cleanup; do
    reject 'main cannot be used as a task branch' "$action" main
    reject 'main cannot be used as a task branch' "$action" 'MAIN!'
  done
  for action in resume stop status sync cleanup; do
    reject 'on main; switch to the task branch or provide its name' "$action" </dev/null
  done
  equal "$(git -C "$HOST" branch --show-current)" main
  equal "$(git -C "$HOST" rev-parse HEAD)" "$source"
  absent "$CASE/workspaces"
  equal "$(count_command ls)" 0
}

optional_task() {
  if [ "$CASE_NAME" = slash_branch ]; then git -C "$HOST" switch -qc 'Feature/Slash-Task'; fi
  local branch source clone sandbox
  branch="$(git -C "$HOST" branch --show-current)"
  source="$(git -C "$HOST" rev-parse HEAD)"
  ok start
  task_fields
  clone="$CLONE"
  sandbox="$SANDBOX"
  equal "$TASK" "$branch"
  equal "$BRANCH" "$branch"
  equal "$(git config --file "$META" --get task.sourceBranch)" "$branch"
  equal "$(git config --file "$META" --get task.sourceCommit)" "$source"
  equal "$(git -C "$CLONE" branch --show-current)" "$branch"
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  ok status
  equal "$(field Workspace)" "$clone"
  equal "$(field Sandbox)" "$sandbox"
  ok stop
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Stopped
  ok resume
  equal "$(field Workspace)" "$clone"
  equal "$(< "$FAKE_MSB_STATE/$SANDBOX")" Running
  commit_work
  ok sync
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  ok cleanup
  removed
  absent "$FAKE_MSB_STATE/$SANDBOX"
  equal "$(git -C "$HOST" branch --show-current)" "$branch"
}

main_prompt() {
  git -C "$HOST" switch -q main
  local action="${CASE_NAME#main_prompt_}" source
  source="$(git -C "$HOST" rev-parse HEAD)"
  reject 'no branch name provided; pass a task name explicitly' "$action" </dev/null
  contains "$OUTPUT" 'On main. Enter a new task branch name:'
  reject 'task name must contain at least one ASCII letter or number' "$action" <<< '!!!'
  reject 'task name must contain at least one ASCII letter or number' "$action" <<< ''
  reject 'main cannot be used as a task branch' "$action" <<< 'Main!'
  equal "$(git -C "$HOST" branch --show-current)" main
  equal "$(git -C "$HOST" rev-parse HEAD)" "$source"
  absent "$CASE/workspaces"
  ok "$action" <<< 'Prompt Task/Name'
  contains "$OUTPUT" 'On main. Enter a new task branch name:'
  task_fields
  equal "$BRANCH" prompt_task_name
  equal "$(git -C "$HOST" branch --show-current)" "$BRANCH"
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$(git config --file "$META" --get task.sourceBranch)" "$BRANCH"
  equal "$(git config --file "$META" --get task.sourceCommit)" "$source"
  if [ "$action" = start ]; then equal "$(count_command create)" 1; fi
}

explicit_branch() {
  local action="${CASE_NAME#explicit_branch_}" source existing
  source="$(git -C "$HOST" rev-parse HEAD)"
  git -C "$HOST" branch existing_task main
  existing="$(git -C "$HOST" rev-parse existing_task)"
  ok "$action" 'New Task!'
  task_fields
  equal "$BRANCH" new_task
  equal "$(git -C "$HOST" branch --show-current)" "$BRANCH"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$source"
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$(git config --file "$META" --get task.sourceBranch)" "$BRANCH"
  if [ "$action" = start ]; then ok stop "$TASK"; fi
  ok "$action" 'Existing Task'
  task_fields
  equal "$BRANCH" existing_task
  equal "$(git -C "$HOST" branch --show-current)" "$BRANCH"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$existing"
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$existing"
  equal "$(git config --file "$META" --get task.sourceBranch)" "$BRANCH"
  equal "$(git config --file "$META" --get task.sourceCommit)" "$existing"
  equal "$(< "$HOST/tracked")" base
}

missing_task() {
  local action task head refs
  head="$(git -C "$HOST" rev-parse HEAD)"
  git -C "$HOST" branch existing_task main
  refs="$(git -C "$HOST" show-ref)"
  for action in resume stop status sync cleanup; do
    for task in 'Missing Task' 'Existing Task'; do
      reject 'task is not set up' "$action" "$task"
      equal "$(git -C "$HOST" branch --show-current)" feature
      equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
      equal "$(git -C "$HOST" show-ref)" "$refs"
    done
  done
  absent "$CASE/workspaces"
  absent "$CASE/upstream"
  equal "$(count_command ls)" 0
}

dirty_handover() {
  setup
  ok start "$TASK"
  commit_work
  git -C "$HOST" switch -q feature
  case "$CASE_NAME" in
    dirty_handover) printf 'dirty\n' >> "$HOST/tracked" ;;
    staged_handover) printf 'staged\n' >> "$HOST/tracked"; git -C "$HOST" add tracked ;;
    untracked_handover) printf 'untracked\n' > "$HOST/untracked" ;;
  esac
  local action task before refs status files
  before="$(snapshot)"
  refs="$(git -C "$HOST" show-ref)"
  status="$(git -C "$HOST" status --porcelain)"
  files="$(sha256sum "$HOST/tracked")"
  for action in setup start resume sync; do
    for task in "$TASK" 'Missing Task'; do
      reject 'commit or stash host changes before handover or sync' "$action" "$task"
      equal "$(git -C "$HOST" branch --show-current)" feature
      equal "$(git -C "$HOST" show-ref)" "$refs"
      equal "$(git -C "$HOST" status --porcelain)" "$status"
      equal "$(sha256sum "$HOST/tracked")" "$files"
      equal "$(snapshot)" "$before"
    done
    reject 'commit or stash host changes before handover or sync' "$action"
  done
  equal "$(count_command create)" 1
  equal "$(count_command exec)" 1
  preserved
}

incoming_ref() {
  local hash
  hash="$(printf '%s' "$BRANCH" | sha256sum)"
  printf 'refs/code-agent/incoming/%s/%s\n' "${hash:0:12}" "$(git -C "$CLONE" rev-parse HEAD)"
}

divergent_sync() {
  setup
  commit_work
  printf 'host work\n' >> "$HOST/tracked"
  git -C "$HOST" commit -qam 'host divergence'
  local head files incoming
  head="$(git -C "$HOST" rev-parse HEAD)"
  files="$(sha256sum "$HOST/tracked")"
  incoming="$(incoming_ref)"
  reject 'host branch cannot fast-forward' sync "$TASK"
  contains "$OUTPUT" "agent work retained at $incoming"
  equal "$(git -C "$HOST" rev-parse "$incoming")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
  equal "$(sha256sum "$HOST/tracked")" "$files"
  equal "$(git -C "$HOST" status --porcelain)" ''
  preserved
  reject 'host branch cannot fast-forward' sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$incoming")" "$(git -C "$CLONE" rev-parse HEAD)"
}

noncurrent_sync() {
  setup
  commit_work
  git -C "$HOST" switch -q main
  local head files
  head="$(git -C "$HOST" rev-parse HEAD)"
  files="$(sha256sum "$HOST/tracked")"
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$BRANCH")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse "$(incoming_ref)")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" branch --show-current)" main
  equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
  equal "$(sha256sum "$HOST/tracked")" "$files"
  equal "$(git -C "$HOST" status --porcelain)" ''
}

other_worktree_sync() {
  setup
  commit_work
  git -C "$HOST" switch -q feature
  git -C "$HOST" worktree add -q "$CASE/other-worktree" "$BRANCH"
  local head destination files
  head="$(git -C "$HOST" rev-parse HEAD)"
  destination="$(git -C "$HOST" rev-parse "$BRANCH")"
  files="$(sha256sum "$CASE/other-worktree/tracked")"
  reject 'checked out' sync "$TASK"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
  equal "$(git -C "$HOST" rev-parse "$BRANCH")" "$destination"
  equal "$(git -C "$CASE/other-worktree" rev-parse HEAD)" "$destination"
  equal "$(sha256sum "$CASE/other-worktree/tracked")" "$files"
  equal "$(git -C "$HOST" rev-parse "$(incoming_ref)")" "$(git -C "$CLONE" rev-parse HEAD)"
  preserved
}

dirty_clone_sync() {
  setup
  commit_work
  local kind before refs
  refs="$(git -C "$HOST" show-ref)"
  for kind in dirty staged untracked ignored; do
    case "$kind" in
      dirty|staged) printf 'dirty\n' >> "$CLONE/tracked" ;;
      untracked|ignored) printf '%s\n' "$kind" > "$CLONE/$kind" ;;
    esac
    if [ "$kind" = staged ]; then git -C "$CLONE" add tracked; fi
    before="$(snapshot)"
    reject 'workspace has modified, untracked, or ignored files' sync "$TASK"
    equal "$(snapshot)" "$before"
    equal "$(git -C "$HOST" show-ref)" "$refs"
    git -C "$CLONE" restore --staged --worktree tracked
    if [ "$kind" = untracked ] || [ "$kind" = ignored ]; then rm -- "$CLONE/$kind"; fi
  done
}

repeated_sync() {
  setup
  local incoming refs
  commit_work
  incoming="$(incoming_ref)"
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$incoming")" "$(git -C "$CLONE" rev-parse HEAD)"
  refs="$(git -C "$HOST" show-ref)"
  ok sync "$TASK"
  equal "$(git -C "$HOST" show-ref)" "$refs"
  commit_work 'second sync'
  ok sync "$TASK"
  git -C "$HOST" show-ref --verify --quiet "$incoming"
  equal "$(git -C "$HOST" rev-parse "$(incoming_ref)")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  ok sync "$TASK"
  equal "$(git -C "$HOST" status --porcelain)" ''
  ok cleanup "$TASK"
  removed
}

ignored_switch_collision() {
  git -C "$HOST" switch -qc collision
  printf 'destination content\n' > "$HOST/ignored"
  git -C "$HOST" add -f ignored
  git -C "$HOST" commit -qm 'track ignored destination'
  git -C "$HOST" switch -q feature
  printf 'precious ignored host content\n' > "$HOST/ignored"
  local action refs files
  refs="$(git -C "$HOST" show-ref)"
  files="$(sha256sum "$HOST/ignored" "$HOST/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
  for action in setup start; do
    reject 'would be overwritten by checkout' "$action" collision
    equal "$(git -C "$HOST" symbolic-ref HEAD)" refs/heads/feature
    equal "$(git -C "$HOST" show-ref)" "$refs"
    equal "$(sha256sum "$HOST/ignored" "$HOST/tracked")" "$files"
  done
  equal "$(count_command create)" 0
  local states=("$CASE/workspaces"/**/*.state) locks=("$CASE/upstream"/**/*.lock)
  equal "${#states[@]}" 0
  equal "${#locks[@]}" 0
}

ignored_sync_collision() {
  setup
  printf 'agent tracked content\n' > "$CLONE/ignored"
  git -C "$CLONE" add -f ignored
  git -C "$CLONE" commit -qm 'track ignored agent file'
  printf 'precious ignored host content\n' > "$HOST/ignored"
  local head files
  head="$(git -C "$HOST" rev-parse HEAD)"
  files="$(sha256sum "$HOST/ignored" "$HOST/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
  reject 'would be overwritten by merge' sync "$TASK"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$head"
  equal "$(git -C "$HOST" rev-parse "refs/heads/$BRANCH")" "$head"
  equal "$(sha256sum "$HOST/ignored" "$HOST/tracked")" "$files"
  equal "$(git -C "$HOST" status --porcelain)" ''
  equal "$(git -C "$HOST" rev-parse "$(incoming_ref)")" "$(git -C "$CLONE" rev-parse HEAD)"
  absent "${UPSTREAM%.git}.lock"
  preserved
}

host_tag_collision() {
  local unrelated source
  source="$(git -C "$HOST" rev-parse HEAD)"
  unrelated="$(git -C "$HOST" commit-tree 'HEAD^{tree}' -m 'unrelated tag commit')"
  git -C "$HOST" tag feature "$unrelated"
  ok start
  task_fields
  equal "$TASK" feature
  equal "$BRANCH" feature
  equal "$(git config --file "$META" --get task.sourceBranch)" feature
  equal "$(git -C "$HOST" symbolic-ref HEAD)" refs/heads/feature
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  commit_work
  ok sync
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse refs/tags/feature)" "$unrelated"
  equal "$(git -C "$HOST" status --porcelain)" ''
  commit_work 'noncurrent collision sync'
  git -C "$HOST" switch -q main
  ok sync feature
  equal "$(git -C "$HOST" rev-parse refs/heads/feature)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" symbolic-ref HEAD)" refs/heads/main
  equal "$(git -C "$HOST" rev-parse refs/tags/feature)" "$unrelated"
}

main_tag_prompt() {
  git -C "$HOST" tag main HEAD
  git -C "$HOST" switch -q main
  local action source
  source="$(git -C "$HOST" rev-parse HEAD)"
  for action in setup start; do
    reject 'no branch name provided; pass a task name explicitly' "$action" </dev/null
    contains "$OUTPUT" 'On main. Enter a new task branch name:'
    equal "$(git -C "$HOST" symbolic-ref HEAD)" refs/heads/main
  done
  ok start <<< 'Main Tag Task'
  contains "$OUTPUT" 'On main. Enter a new task branch name:'
  task_fields
  equal "$BRANCH" main_tag_task
  equal "$(git -C "$HOST" symbolic-ref HEAD)" refs/heads/main_tag_task
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
}

clone_tag_collision() {
  setup
  git -C "$CLONE" tag "$BRANCH" HEAD
  commit_work
  ok sync "$TASK"
  equal "$(git -C "$CLONE" symbolic-ref HEAD)" "refs/heads/$BRANCH"
  equal "$(git -C "$HOST" rev-parse "refs/heads/$BRANCH")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
}

squash_merge_options() {
  setup
  git -C "$HOST" config "branch.$BRANCH.mergeOptions" --squash
  commit_work
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(git -C "$HOST" rev-parse "refs/heads/$BRANCH")" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
  equal "$(git -C "$HOST" config "branch.$BRANCH.mergeOptions")" --squash
}

sync_repo_lock() {
  setup
  commit_work
  local lock="${UPSTREAM%.git}.lock" refs files holder
  refs="$(git -C "$HOST" show-ref)"
  files="$(sha256sum "$HOST/tracked")"
  mkdir "$lock"
  (
    trap 'rmdir -- "$lock"' EXIT
    # Wait for sync to take its task lock, then verify it stays blocked.
    for ((attempt = 0; attempt < 100; attempt++)); do
      [ ! -d "$LOCK" ] || break
      sleep 0.05
    done
    exists "$LOCK"
    sleep 1
    exists "$LOCK"
    equal "$(git -C "$HOST" show-ref)" "$refs"
    equal "$(sha256sum "$HOST/tracked")" "$files"
    printf 'verified\n' > "$CASE/lock-verified"
  ) > "$CASE/lock-holder.out" 2>&1 &
  holder=$!
  ok sync "$TASK"
  if ! wait "$holder"; then OUTPUT="$(< "$CASE/lock-holder.out")"; fail 'sync did not wait for repo lock'; fi
  exists "$CASE/lock-verified"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
  absent "$lock"
  preserved
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
    dirty_host) printf 'dirty\n' >> "$HOST/tracked"; reject 'commit or stash host changes before handover or sync' setup rejected ;;
    untracked_host) printf 'untracked\n' > "$HOST/untracked"; reject 'commit or stash host changes before handover or sync' setup rejected ;;
  esac
  equal "$(count_command create)" 0
  local states=("$CASE/workspaces"/**/*.state)
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
  removed
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
  if [ "$operation" != rm ]; then
    reject "${operation} failure" stop "$TASK"
  fi
  if [ "$operation" != rm ]; then equal "$(count_command rm)" 0; fi
  if [ "$operation" = ls ]; then
    equal "$(count_command stop)" 0
    equal "$(snapshot)" "$before"
    reject 'cannot list microsandboxes' cleanup "$TASK" --dry-run
    reject 'cannot list microsandboxes' start "$TASK"
    equal "$(count_command create)" 1
  fi
  unset FAKE_MSB_FAIL
  ok stop "$TASK"
  ok cleanup "$TASK" --discard
  removed
}

symlink_refusal() {
  setup
  local target link
  case "$CASE_NAME" in
    symlink_parent) link="$STATE_DIR" ;;
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
  commit_work 'second commit'
  ok sync "$TASK"
  equal "$(git -C "$HOST" rev-parse HEAD)" "$(git -C "$CLONE" rev-parse HEAD)"
  equal "$(< "$HOST/tracked")" "$(< "$CLONE/tracked")"
  equal "$(git -C "$HOST" status --porcelain)" ''
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
  removed
}

lock_refusal() {
  setup
  mkdir "$LOCK"
  local action
  for action in setup start resume stop status sync cleanup; do
    reject 'task is locked' "$action" "$TASK"
    exists "$LOCK"
    exists "$META"
  done
  reject 'task is locked' cleanup "$TASK" --discard
  reject 'task is locked' cleanup "$TASK" --dry-run
  equal "$(count_command ls)" 0
  rmdir "$LOCK"
  ok cleanup "$TASK"
}

wrong_branch() {
  setup
  local head
  head="$(git -C "$HOST" rev-parse "$BRANCH")"
  git -C "$CLONE" switch -qc wrong
  commit_work
  reject 'not on the expected task branch' sync "$TASK"
  equal "$(git -C "$HOST" rev-parse "$BRANCH")" "$head"
  equal "$(git -C "$HOST" for-each-ref refs/code-agent/incoming)" ''
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
  removed
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
  ok stop "$TASK"
  ok cleanup "$TASK" --discard
}

transition_verification() {
  setup
  ok start "$TASK"
  export FAKE_MSB_NO_TRANSITION=stop
  reject 'sandbox did not stop' cleanup "$TASK" --discard
  reject 'sandbox did not stop' stop "$TASK"
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
  printf 'Running\n' > "$FAKE_MSB_STATE/$SANDBOX"
  ok stop "$TASK"
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
  equal "$(field Branch)" concurrent_first
  equal "$(git config --file "$(meta_of "$first_clone")" --get task.sourceBranch)" concurrent_first
  equal "$(git -C "$HOST" rev-parse concurrent_first)" "$source"
  equal "$(git -C "$first_clone" rev-parse HEAD)" "$source"
  OUTPUT="$(< "$CASE/second.out")"
  CLONE="$(field Workspace)"
  UPSTREAM="$(field Upstream)"
  equal "$(field Branch)" concurrent_second
  equal "$(git config --file "$(meta_of "$CLONE")" --get task.sourceBranch)" concurrent_second
  equal "$(git -C "$HOST" rev-parse concurrent_second)" "$source"
  case "$(git -C "$HOST" branch --show-current)" in
    concurrent_first|concurrent_second) ;;
    *) fail 'concurrent setup did not select a task branch' ;;
  esac
  equal "$(git -C "$HOST" rev-parse HEAD)" "$source"
  equal "$(git -C "$HOST" status --porcelain)" ''
  [ "$CLONE" != "$first_clone" ] || fail 'concurrent tasks share workspace'
  equal "$(git -C "$CLONE" rev-parse HEAD)" "$source"
  equal "$(git -C "$UPSTREAM" rev-parse "refs/heads/snapshot-$source")" "$source"
  git -C "$UPSTREAM" fsck --no-dangling >/dev/null 2>&1
  absent "${UPSTREAM%.git}.lock"
  absent "$(lock_of "$first_clone")"
  absent "$(lock_of "$CLONE")"
}

interactive_lock() {
  setup
  export FAKE_MSB_EXEC_LOCK="$LOCK"
  export FAKE_MSB_EXEC_SCRIPT="$SCRIPT" FAKE_MSB_EXEC_TASK="$TASK"
  ok start "$TASK"
  logged ls
  preserved
  ok resume "$TASK"
  equal "$(count_command exec)" 2
  equal "$(count_command ls)" 6
  equal "$(count_command start)" 0
  equal "$(count_command create)" 1
}

configured_settings() {
  # Ambient variables must not override the packaged configuration.
  export CODE_AGENT_WORKSPACES_DIR=/wrong CODE_AGENT_UPSTREAM_DIR=/wrong
  export CODE_AGENT_SANDBOX_PREFIX=wrong CODE_AGENT_CPUS=99 CODE_AGENT_MEMORY=99G
  export CODE_AGENT_IMAGE=wrong:latest
  export CODE_AGENT_CACHE_DIR=/wrong CODE_AGENT_CACHE_DIRECTORY=/wrong
  OUTPUT="$(bash "$SCRIPT" --print-image)"
  equal "$OUTPUT" 'custom-agent:configured'
  OUTPUT="$(FAKE_MSB_IMAGE=custom-agent:configured bash "$TEST_DIR/../../../make.sh" image 2>&1)" || fail 'image build integration failed'
  contains "$OUTPUT" 'Microsandbox image already registered: custom-agent:configured'
  logged images -q
  setup configured
  contains "$CLONE" "$CASE/workspaces with ' quotes/"
  contains "$UPSTREAM" "$CASE/upstream with spaces/"
  contains "$SANDBOX" custom-prefix-
  ok start "$TASK"
  equal "$CACHE" "$CASE/package cache with ' quotes"
  expected_create "$SANDBOX" "$CLONE" 2 512M custom-agent:configured
  exists "$CACHE"
  ok cleanup "$TASK"
  exists "$CACHE"
}

command_help() {
  local command form before
  before="$(git -C "$HOST" show-ref)"
  # Help and argument validation must work without a repository or msb.
  HOST="$CASE/home"
  export FAKE_MSB_FAIL=ls
  for form in '' help --help -h; do
    if [ -z "$form" ]; then ok; else ok "$form"; fi
    contains "$OUTPUT" 'Usage: code-agent COMMAND'
    contains "$OUTPUT" 'Commands:'
    contains "$OUTPUT" 'Configuration comes from dotfiles.agentSandbox'
  done
  for command in setup start resume stop status sync cleanup help; do
    ok help "$command"
    contains "$OUTPUT" "Usage: code-agent $command"
    for form in --help -h help; do
      ok "$command" "$form"
      contains "$OUTPUT" "Usage: code-agent $command"
    done
    if [ "$command" != help ]; then
      ok "$command" 'Example Task' --help
      contains "$OUTPUT" "Usage: code-agent $command"
    fi
  done
  ok cleanup --help
  contains "$OUTPUT" '--discard'
  contains "$OUTPUT" '--dry-run'
  contains "$OUTPUT" 'Irreversible'
  ok sync --help
  contains "$OUTPUT" 'Divergence'
  contains "$OUTPUT" 'host tracked, staged, and untracked changes'
  reject 'Unknown command: missing' missing
  reject 'Unknown command: missing' help missing
  reject 'Usage: code-agent start' start --invalid
  reject 'Usage: code-agent cleanup' cleanup example --invalid
  unset FAKE_MSB_FAIL
  equal "$(count_command ls)" 0
  absent "$CASE/workspaces"
  absent "$CASE/upstream"
  absent "$CACHE"
  equal "$(git -C "$CASE/repositories/project" show-ref)" "$before"
}

if [ "${1:-}" = --case ]; then
  CASE_NAME="$2"
  CASE="$3"
  shopt -s globstar nullglob dotglob
  mkdir -p "$CASE/bin" "$CASE/msb-state" "$CASE/home" "$CASE/tmp"
  export HOME="$CASE/home" TMPDIR="$CASE/tmp" GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$CASE/gitconfig"
  # Render the same shell-escaped settings that Home Manager bakes into the command.
  SCRIPT="$CASE/bin/code-agent"
  keys=(workspaceDirectory upstreamDirectory sandboxPrefix image cpus memory cacheDirectory)
  values=("$CASE/workspaces" "$CASE/upstream" code-agent dotfiles-agent:latest 4 8G "$CASE/package-cache")
  if [ "$CASE_NAME" = configured_settings ]; then
    values=("$CASE/workspaces with ' quotes" "$CASE/upstream with spaces" custom-prefix custom-agent:configured 2 512M "$CASE/package cache with ' quotes")
  fi
  CACHE="${values[6]}"
  render
  export FAKE_MSB_STATE="$CASE/msb-state" FAKE_MSB_LOG="$CASE/msb.log"
  unset FAKE_MSB_FAIL FAKE_MSB_FAIL_INSPECT_NAME FAKE_MSB_NO_TRANSITION FAKE_MSB_EXEC_LOCK FAKE_MSB_EXEC_SCRIPT FAKE_MSB_EXEC_TASK
  : > "$FAKE_MSB_LOG"
  # The tracked fixture need not have its executable bit set.
  cp -- "$TEST_DIR/fake-msb" "$CASE/bin/msb"
  chmod +x "$CASE/bin/msb"
  export PATH="$CASE/bin:$PATH"
  new_repo "$CASE/repositories/project"
  case "$CASE_NAME" in
    detached_host|dirty_host|untracked_host) host_rejection ;;
    optional_task|slash_branch) optional_task ;;
    main_prompt_setup|main_prompt_start) main_prompt ;;
    explicit_branch_setup|explicit_branch_start) explicit_branch ;;
    dirty_handover|staged_handover|untracked_handover) dirty_handover ;;
    dirty_cleanup|untracked_cleanup|ignored_cleanup|unsynced_cleanup|other_branch_cleanup|reflog_cleanup|stash_cleanup|annotated_tag_cleanup) cleanup_work ;;
    ls_failure|stop_failure|rm_failure) lifecycle_failure ;;
    inspect_failure|start_failure|resume_failure) transition_failure ;;
    symlink_parent|symlink_clone|symlink_git) symlink_refusal ;;
    cache_overlap_*) cache_overlap ;;
    cache_start_failure_*) cache_start_failure ;;
    *) "$CASE_NAME" ;;
  esac
  exit 0
fi

[ "$#" = 0 ] || fail 'usage: bash modules/agent-sandbox/tests/lifecycle.sh'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/code-agent-lifecycle.XXXXXXXX")"
trap 'rm -rf -- "$ROOT"' EXIT
tests=(roundtrip reuse mount_isolation cache_sharing cache_reuse cache_lazy_creation
  cache_missing_resume cache_start_failure_ls cache_start_failure_create
  cache_start_failure_inspect cache_start_failure_exec
  cache_overlap_repo_equal cache_overlap_repo_descendant cache_overlap_repo_ancestor
  cache_overlap_workspace_equal cache_overlap_workspace_descendant cache_overlap_workspace_ancestor
  cache_overlap_upstream_equal cache_overlap_upstream_descendant cache_overlap_upstream_ancestor
  repo_identity task_identity readable_layout task_name_clash long_task_names legacy_layout main_task rebased_source
  optional_task slash_branch main_prompt_setup main_prompt_start explicit_branch_setup explicit_branch_start
  missing_task dirty_handover staged_handover untracked_handover divergent_sync noncurrent_sync
  other_worktree_sync dirty_clone_sync repeated_sync
  ignored_switch_collision ignored_sync_collision host_tag_collision main_tag_prompt
  clone_tag_collision squash_merge_options sync_repo_lock
  detached_host dirty_host untracked_host dirty_cleanup untracked_cleanup ignored_cleanup
  unsynced_cleanup other_branch_cleanup ls_failure stop_failure rm_failure
  symlink_parent symlink_clone symlink_git dry_run partial_initialization
  checked_out_destination no_main lock_refusal wrong_branch paused_lifecycle
  inspect_failure start_failure resume_failure transition_verification reflog_cleanup
  stash_cleanup annotated_tag_cleanup signed_push concurrent_setup interactive_lock configured_settings command_help)
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
