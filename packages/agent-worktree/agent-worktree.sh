#!/usr/bin/env bash
set -euo pipefail

# agent-worktree <task-name> [base-ref]
TASK="${1:?usage: agent-worktree <task-name> [base-ref]}"
BASE_REF="${2:-HEAD}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
WORKTREES_DIR="${AGENT_WORKTREES_DIR:-$HOME/agent-worktrees}"
WT_PATH="$WORKTREES_DIR/${REPO_NAME}-${TASK}"
BRANCH="agent/${TASK}"

mkdir -p "$WORKTREES_DIR"

if [ ! -d "$WT_PATH" ]; then
  git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT_PATH" "$BASE_REF"
fi
[ -f "$WT_PATH/.env" ] && rm -f "$WT_PATH/.env"

SETTINGS_DIR="$(mktemp -d)"
SETTINGS_FILE="$SETTINGS_DIR/srt-settings.json"
trap 'rm -rf "$SETTINGS_DIR"' EXIT

# --- credentials: resolve host-side only, export into this process's env ---
OP_SERVICE_ACCOUNT_TOKEN="$(pass show meta/op-service-account-token 2>/dev/null || true)"
export OP_SERVICE_ACCOUNT_TOKEN

MANIFEST="$HOME/.agent-credentials/${TASK}.manifest"
if [ -f "$MANIFEST" ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    backend_ref="${line%% -> *}"
    var_name="${line##* -> }"
    backend="${backend_ref%%:*}"
    ref="${backend_ref#*:}"

    case "$backend" in
      pass) value="$(pass show "$ref" | head -n1)" ;;
      op)   value="$(op read "op://$ref" 2>/dev/null || op item get "$ref" --fields credential --reveal)" ;;
      *)    echo "unknown credential backend: $backend" >&2; continue ;;
    esac
    export "$var_name=$value"
  done < "$MANIFEST"
fi
# ----------------------------------------------------------------------------

allowedDomains="${AGENT_ALLOWED_DOMAINS:-[\"api.anthropic.com\"]}"
cat > "$SETTINGS_FILE" <<JSON
{
  "network": {
    "allowedDomains": $allowedDomains,
    "deniedDomains": []
  },
  "filesystem": {
    "denyRead": [
      "$REPO_ROOT",
      "$HOME/.ssh",
      "$HOME/.aws",
      "$HOME/.config/gh",
      "$HOME/agent-worktrees",
      "$HOME/.password-store",
      "$HOME/.gnupg",
      "$HOME/.config/op",
      "$HOME/.1password",
      "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password"
    ],
    "allowWrite": ["$WT_PATH", "/tmp", "$HOME/.pi"],
    "denyWrite": ["$WT_PATH/.env", "$WT_PATH/.git/config"]
  }
}
JSON

cd "$WT_PATH"
exec srt --settings "$SETTINGS_FILE" pi "$@"
