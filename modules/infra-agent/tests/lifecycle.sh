#!/usr/bin/env bash
# infra-agent lifecycle tests with a fake msb and the real infra-credd.
# Run: bash modules/infra-agent/tests/lifecycle.sh
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$TEST_DIR/lifecycle.sh"
TEMPLATE="$TEST_DIR/../scripts/infra-agent"
CREDD_SOURCE="$TEST_DIR/../credd/infra_credd.py"
# shellcheck disable=SC2016
ATTACH_SCRIPT='if [ -n "${OPENCODE_CONFIG:-}" ] && [ ! -r "$OPENCODE_CONFIG" ]; then printf "%s\n" "infra-agent: this sandbox image has no agent profile ${AGENT_PROFILE:-} ($OPENCODE_CONFIG). Rebuild the image with make.sh image --force, then recreate the incident sandbox." >&2; exit 1; fi; if [ ! -r /run/infra-agent/mcp-token ]; then printf "%s\n" "infra-agent: the incident token is missing; run infra-agent resume on the host." >&2; exit 1; fi; INFRA_MCP_TOKEN="$(cat /run/infra-agent/mcp-token)"; export INFRA_MCP_TOKEN; cd /workspace && exec "$@"'

fail() { printf 'FAIL: %s\n%s\n' "$*" "${OUTPUT:-}" >&2; exit 1; }
equal() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
contains() { [[ "$1" == *"$2"* ]] || fail "missing [$2] in [$1]"; }
lacks() { [[ "$1" != *"$2"* ]] || fail "unexpected [$2] in [$1]"; }
exists() { [ -e "$1" ] || fail "missing path: $1"; }
absent() { if [ -e "$1" ] || [ -L "$1" ]; then fail "unexpected path: $1"; fi; }
mode() { stat -c %a -- "$1"; }

ia() { bash "$SCRIPT" "$@"; }
ok() { OUTPUT="$(ia "$@" 2>&1)" || fail "command failed: $*"; }
reject() {
  local reason="$1"
  shift
  if OUTPUT="$(ia "$@" 2>&1)"; then fail "command unexpectedly succeeded: $*"; fi
  contains "$OUTPUT" "$reason"
}
logged() {
  local expected line
  printf -v expected '%q ' "$@"
  while IFS= read -r line; do [ "$line" != "$expected" ] || return 0; done < "$FAKE_MSB_LOG"
  fail "missing msb invocation: $expected
$(cat "$FAKE_MSB_LOG")"
}
count_command() {
  local line count=0
  while IFS= read -r line; do
    if [[ "$line" == "$1 "* ]]; then count=$((count + 1)); fi
  done < "$FAKE_MSB_LOG"
  printf '%s\n' "$count"
}
line_of() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$1 "* ]]; then printf '%s\n' "$line"; fi
  done < "$FAKE_MSB_LOG"
}
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

STATE_DIRS() {
  PRIVATE="$STATE/.infra-agent"
  BROKER_DIR="$PRIVATE/brokers/prod"
  RUN_DIR="$BROKER_DIR/run"
  SOCKET="$BROKER_DIR/credd.sock"
  AUDIT="$PRIVATE/audit/prod.jsonl"
}

write_config() {
  local hash="${1:-hash-1}"
  jq -n --arg state "$STATE" --arg token "$COPILOT_FILE" --argjson port "$PORT" --argjson other "$OTHER_PORT" \
    --arg brokerConfig "$CASE/broker-config" --arg creddConfig "$CASE/credd.json" --arg hash "$hash" \
    --arg ddCommand "$DD_COMMAND" '{
    stateDirectory: $state, sandboxPrefix: "infra-agent", defaultEnvironment: "prod",
    llmHosts: ["api.githubcopilot.com"], copilotTokenFile: $token,
    agent: {image: "dotfiles-agent:latest", cpus: 4, memory: "8G", rootDisk: "12G", profile: "infra",
            opencodeConfig: {autoupdate: false, share: "disabled", model: "github-copilot/claude"}},
    broker: {image: "dotfiles-infra-broker:latest", cpus: 2, memory: "4G", rootDisk: "8G"},
    environments: {
      prod: {
        port: $port, dnsPort: null, description: "production",
        brokerSandbox: "infra-broker-prod", brokerConfig: $brokerConfig, creddConfig: $creddConfig,
        netRules: ["allow@logs.eu-west-1.amazonaws.com:tcp:443", "allow@mcp.datadoghq.eu:tcp:443",
                   "allow@10.20.0.0/16:tcp:443", "allow@payments.internal.example:tcp:443"],
        tlsBypass: ["payments.internal.example"], tlsUpstreamCaCerts: ["/etc/corp-ca.pem"], dnsForwarders: {},
        secrets: [{name: "INFRA_DD_API_KEY", command: $ddCommand, hosts: ["mcp.datadoghq.eu"]},
                  {name: "INFRA_DD_APP_KEY", command: "printf app-secret", hosts: ["mcp.datadoghq.eu"]}],
        servers: ["aws", "datadog", "k8s"],
        preflight: {awsProfiles: ["sso-prod"], azureTenant: "tenant-1", vpns: {tailscale: "true", fortinet: "false"},
                    targets: [{name: "k8s payments", host: "127.0.0.1", port: 1, via: "tailscale"}]},
        configHash: $hash
      },
      staging: {
        port: $other, dnsPort: null, description: "", brokerSandbox: "infra-broker-staging",
        brokerConfig: $brokerConfig, creddConfig: $creddConfig, netRules: [], tlsBypass: [], tlsUpstreamCaCerts: [],
        dnsForwarders: {}, secrets: [], servers: [],
        preflight: {awsProfiles: [], azureTenant: null, vpns: {}, targets: []}, configHash: "staging"
      }
    }}' > "$CASE/infra-agent.json"
}

render() {
  local template
  template="$(< "$TEMPLATE")"
  template="${template//@config@/$(printf '%q' "$CASE/infra-agent.json")}"
  template="${template//@credd@/$(printf '%q' "$CASE/bin/infra-credd")}"
  template="${template//@dnsmasq@/$(printf '%q' "$CASE/bin/dnsmasq")}"
  printf '%s\n' "$template" > "$SCRIPT"
}

expected_broker_run() {
  logged run -d --name infra-broker-prod --cpus 2 --memory 4G --root-disk 8G \
    --net-default-egress deny \
    --net-rule "allow@logs.eu-west-1.amazonaws.com:tcp:443,allow@mcp.datadoghq.eu:tcp:443,allow@10.20.0.0/16:tcp:443,allow@payments.internal.example:tcp:443" \
    --tls-intercept --tls-bypass payments.internal.example --tls-upstream-ca-cert /etc/corp-ca.pem \
    --secret INFRA_DD_API_KEY@mcp.datadoghq.eu --secret INFRA_DD_APP_KEY@mcp.datadoghq.eu \
    -p "127.0.0.1:$PORT:8080" \
    --vsock "$SOCKET:9100" \
    --volume "$CASE/broker-config:/etc/infra-broker:ro" \
    --volume "$RUN_DIR:/run/infra:ro,uid=1000,gid=1000" \
    dotfiles-infra-broker:latest
}

expected_agent_create() {
  local incident="$1"
  logged create --name "infra-agent-$incident" --cpus 4 --memory 8G --root-disk 12G \
    --net-default-egress deny \
    --net-rule "allow@api.githubcopilot.com:tcp:443,allow@host.microsandbox.internal:tcp:$PORT,allow@host:tcp:$PORT" \
    --tls-intercept --secret CODE_AGENT_COPILOT_TOKEN@api.githubcopilot.com \
    --volume "$STATE/incidents/$incident:/workspace" \
    --volume "$PRIVATE/incidents/$incident.run:/run/infra-agent:ro,uid=1000,gid=1000" \
    --env "OPENCODE_CONFIG=/home/adamr/.config/agent-profiles/infra/opencode.json" \
    --env AGENT_PROFILE=infra \
    --env 'OPENCODE_CONFIG_CONTENT={"autoupdate":false,"share":"disabled","model":"github-copilot/claude"}' \
    --env "INFRA_MCP_URL=http://host.microsandbox.internal:$PORT/mcp" \
    --env INFRA_ENVIRONMENT=prod \
    --env "INFRA_INCIDENT=$incident" \
    --env OPENCODE_DISABLE_MODELS_FETCH=1 \
    --env OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
    dotfiles-agent:latest
}

# ---- cases ---------------------------------------------------------------------

start_creates_broker_and_agent() {
  ok start INC-123
  contains "$OUTPUT" 'Incident: inc_123'
  contains "$OUTPUT" 'ok    aws profile sso-prod'
  contains "$OUTPUT" 'ok    vpn tailscale'
  contains "$OUTPUT" 'DOWN  vpn fortinet'
  contains "$OUTPUT" 'DOWN  k8s payments (127.0.0.1:1) via tailscale'
  expected_broker_run
  expected_agent_create inc_123
  logged exec --tty infra-agent-inc_123 -- zsh -c "$ATTACH_SCRIPT" infra-agent opencode
  # Secrets reach msb through its environment only.
  contains "$(< "$FAKE_MSB_LOG.env")" 'run INFRA_DD_API_KEY=dd-secret'
  contains "$(< "$FAKE_MSB_LOG.env")" 'run INFRA_DD_APP_KEY=app-secret'
  contains "$(< "$FAKE_MSB_LOG.env")" 'create CODE_AGENT_COPILOT_TOKEN=copilot-token'
  lacks "$(< "$FAKE_MSB_LOG")" dd-secret
  lacks "$(< "$FAKE_MSB_LOG")" app-secret
  lacks "$(< "$FAKE_MSB_LOG")" copilot-token
  # infra-credd is running on a private socket.
  [ -S "$SOCKET" ] || fail 'credd socket missing'
  equal "$(mode "$SOCKET")" 600
  equal "$(mode "$BROKER_DIR")" 700
  equal "$(mode "$RUN_DIR/credd-token")" 600
  equal "$(mode "$STATE/incidents/inc_123")" 700
  curl --unix-socket "$SOCKET" -fsS http://credd/healthz > /dev/null || fail 'credd not healthy'
  # The incident token is shared by the broker's token directory and the agent's mount.
  equal "$(< "$RUN_DIR/tokens/inc_123")" "$(< "$PRIVATE/incidents/inc_123.run/mcp-token")"
  [[ "$(< "$RUN_DIR/tokens/inc_123")" =~ ^[0-9a-f]{64}$ ]] || fail 'token format'
  equal "$(jq -r .environment "$PRIVATE/incidents/inc_123.json")" prod
  contains "$(< "$AUDIT")" '"event":"start"'
  contains "$(< "$AUDIT")" '"event":"token"'
}

agent_isolation() {
  ok start first
  ok start second
  local line
  while IFS= read -r line; do
    lacks "$line" --vsock
    lacks "$line" credd
    lacks "$line" "$RUN_DIR"
    lacks "$line" broker-config
    lacks "$line" amazonaws.com
    lacks "$line" datadoghq
    lacks "$line" 10.20.0.0
    lacks "$line" "allow@host:tcp:$OTHER_PORT"
    lacks "$line" ' --net '
    lacks "$line" public
  done < <(line_of create)
  while IFS= read -r line; do
    lacks "$line" githubcopilot
    lacks "$line" "$STATE/incidents"
    lacks "$line" ' --net '
  done < <(line_of run)
}

broker_reuse() {
  ok start first
  ok start second
  equal "$(count_command run)" 1
  equal "$(count_command create)" 2
  # Preflight only runs when the broker is (re)started.
  lacks "$OUTPUT" 'Preflight'
  ok broker up
  equal "$(count_command run)" 1
}

broker_recreated_on_change() {
  ok start first
  write_config hash-2
  ok resume first
  equal "$(count_command run)" 2
  logged rm --force infra-broker-prod
  contains "$OUTPUT" 'Recreating broker'
  # An unhealthy gateway is also replaced.
  kill "$(< "$FAKE_MSB_STATE.pids/infra-broker-prod")"
  sleep 0.2
  ok resume first
  equal "$(count_command run)" 3
}

resume_stop_cleanup() {
  ok start inc-9
  ok stop inc-9
  logged stop infra-agent-inc_9
  equal "$(< "$FAKE_MSB_STATE/infra-agent-inc_9")" Stopped
  : > "$FAKE_MSB_LOG.env"
  ok resume inc-9
  logged start infra-agent-inc_9
  contains "$(< "$FAKE_MSB_LOG.env")" 'start CODE_AGENT_COPILOT_TOKEN=copilot-token'
  ok status inc-9
  contains "$OUTPUT" 'Status: Running'
  printf 'customer data\n' > "$STATE/incidents/inc_9/report.md"
  ok cleanup inc-9 --dry-run
  contains "$OUTPUT" "delete $STATE/incidents/inc_9"
  exists "$STATE/incidents/inc_9/report.md"
  ok cleanup inc-9
  logged rm --force infra-agent-inc_9
  absent "$STATE/incidents/inc_9"
  absent "$RUN_DIR/tokens/inc_9"
  absent "$PRIVATE/incidents/inc_9.run"
  absent "$PRIVATE/incidents/inc_9.json"
  reject 'does not exist' resume inc-9
  ok start inc-10
  ok cleanup inc-10 --keep-workspace
  exists "$STATE/incidents/inc_10"
  absent "$RUN_DIR/tokens/inc_10"
}

environment_binding() {
  ok start inc-1 --env prod
  reject 'belongs to environment prod' start inc-1 --env staging
  reject 'unknown environment' start inc-2 --env nowhere
}

revoke() {
  ok start inc-1
  local old
  old="$(< "$RUN_DIR/tokens/inc_1")"
  local credd_token
  credd_token="$(< "$RUN_DIR/credd-token")"
  ok revoke
  logged rm --force infra-broker-prod
  absent "$RUN_DIR/tokens/inc_1"
  absent "$PRIVATE/incidents/inc_1.run/mcp-token"
  absent "$SOCKET"
  absent "$RUN_DIR/credd-token"
  contains "$(< "$AUDIT")" '"event":"revoke"'
  ok resume inc-1
  [ "$(< "$RUN_DIR/tokens/inc_1")" != "$old" ] || fail 'token not rotated'
  [ "$(< "$RUN_DIR/credd-token")" != "$credd_token" ] || fail 'credd token not rotated'
  equal "$(< "$RUN_DIR/tokens/inc_1")" "$(< "$PRIVATE/incidents/inc_1.run/mcp-token")"
}

secret_command_failure() {
  DD_COMMAND='exit 3'
  write_config
  reject 'secret command for INFRA_DD_API_KEY failed' start inc-1
  equal "$(count_command run)" 0
  equal "$(count_command create)" 0
}

unhealthy_broker() {
  export FAKE_BROKER_UNHEALTHY=1
  # Avoid the 90-second wait: the script's loop is bounded by attempts.
  # shellcheck disable=SC2016
  sed -i 's/\[ "$attempts" -ge 90 \]/[ "$attempts" -ge 2 ]/' "$SCRIPT"
  reject 'did not become healthy' start inc-1
  contains "$OUTPUT" 'fake broker log'
  equal "$(count_command create)" 0
}

expired_sso() {
  export FAKE_AWS_FAIL=1
  reject 'aws sso login --profile sso-prod' start inc-1 < /dev/null
  equal "$(count_command run)" 0
  ok start inc-1 --skip-preflight < /dev/null
  equal "$(count_command run)" 1
}

copilot_token_checks() {
  chmod 640 "$COPILOT_FILE"
  reject 'must not be accessible by group or others' start inc-1
  chmod 600 "$COPILOT_FILE"
  printf 'two tokens\n' > "$COPILOT_FILE"
  reject 'must contain a single token' start inc-2
}

creds_and_audit() {
  ok start inc-1
  ok creds
  equal "$(jq -r .environment <<< "$OUTPUT")" prod
  ok broker status
  contains "$OUTPUT" 'Gateway: healthy'
  contains "$OUTPUT" 'infra-credd: running'
  ok audit inc-1
  contains "$OUTPUT" '"detail":"inc_1"'
  ok audit
  contains "$OUTPUT" '"event":"start"'
  ok broker logs
  contains "$OUTPUT" 'fake broker log'
  ok broker doctor
  logged exec infra-broker-prod -- infra-broker-credential doctor
  ok broker down
  absent "$SOCKET"
  logged rm --force infra-broker-prod
  reject 'infra-credd is not running' creds
}

attach_command() {
  ok start inc-1 -- bash -l
  logged exec --tty infra-agent-inc_1 -- zsh -c "$ATTACH_SCRIPT" infra-agent bash -l
}

command_help() {
  ok help
  contains "$OUTPUT" 'Usage: infra-agent COMMAND'
  for command in start resume stop status cleanup broker creds audit revoke; do
    ok help "$command"
    contains "$OUTPUT" "Usage: infra-agent $command"
    ok "$command" --help
  done
  ok --print-image
  equal "$OUTPUT" dotfiles-agent:latest
  ok --print-broker-image
  equal "$OUTPUT" dotfiles-infra-broker:latest
  reject 'Unknown command' nonsense
  reject 'Usage: infra-agent stop' stop inc --keep-workspace
  reject 'Usage: infra-agent broker' broker sideways
  equal "$(count_command ls)" 0
}

if [ "${1:-}" = --case ]; then
  CASE_NAME="$2"
  CASE="$3"
  mkdir -p "$CASE/bin" "$CASE/home" "$CASE/tmp" "$CASE/broker-config"
  export HOME="$CASE/home" TMPDIR="$CASE/tmp"
  STATE="$CASE/state"
  STATE_DIRS
  SCRIPT="$CASE/bin/infra-agent"
  PORT="$(free_port)"
  OTHER_PORT="$(free_port)"
  COPILOT_FILE="$CASE/copilot-token"
  printf 'copilot-token\n' > "$COPILOT_FILE"
  chmod 600 "$COPILOT_FILE"
  DD_COMMAND='printf dd-secret'
  printf '{"environment": "prod", "aws": {"accounts": {}}}\n' > "$CASE/credd.json"
  write_config
  render
  { printf '#!%s\n' "$(command -v python3)"; tail -n +2 "$CREDD_SOURCE"; } > "$CASE/bin/infra-credd"
  chmod +x "$CASE/bin/infra-credd"
  # Explicit interpreters: some sandboxes have no /usr/bin/env.
  { printf '#!%s\n' "$(command -v bash)"; tail -n +2 "$TEST_DIR/fake-msb"; } > "$CASE/bin/msb"
  # shellcheck disable=SC2016
  printf '#!%s\n[ -z "${FAKE_AWS_FAIL:-}" ] || exit 1\n' "$(command -v bash)" > "$CASE/bin/aws"
  printf '#!%s\nexit 0\n' "$(command -v bash)" > "$CASE/bin/az"
  chmod +x "$CASE/bin/msb" "$CASE/bin/aws" "$CASE/bin/az"
  export PATH="$CASE/bin:$PATH"
  export FAKE_MSB_STATE="$CASE/msb-state" FAKE_MSB_LOG="$CASE/msb.log"
  : > "$FAKE_MSB_LOG"
  : > "$FAKE_MSB_LOG.env"
  # shellcheck disable=SC2329 # invoked by the EXIT trap
  cleanup_case() {
    local pid_file
    for pid_file in "$FAKE_MSB_STATE.pids"/* "$BROKER_DIR/credd.pid"; do
      [ -f "$pid_file" ] && kill "$(< "$pid_file")" 2>/dev/null || true
    done
  }
  trap cleanup_case EXIT
  "$CASE_NAME"
  exit 0
fi

[ "$#" = 0 ] || fail 'usage: bash modules/infra-agent/tests/lifecycle.sh'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/infra-agent-lifecycle.XXXXXXXX")"
trap 'rm -rf -- "$ROOT"' EXIT
tests=(start_creates_broker_and_agent agent_isolation broker_reuse broker_recreated_on_change resume_stop_cleanup
  environment_binding revoke secret_command_failure unhealthy_broker expired_sso copilot_token_checks
  creds_and_audit attach_command command_help)
passed=0
failed=0
index=0
for test in "${tests[@]}"; do
  # Short case directories: Unix socket paths are limited to about 100 bytes.
  index=$((index + 1))
  if bash "$SELF" --case "$test" "$ROOT/$index"; then
    printf 'PASS %s\n' "$test"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test"
    failed=$((failed + 1))
  fi
done
printf '\nResults: %d passed, %d failed, %d total\n' "$passed" "$failed" "${#tests[@]}"
[ "$failed" = 0 ]
