#!/bin/bash
# test-lib-agent-kimi.sh — Unit tests for the kimi branches of lib-agent.sh
# (AutoScribeCorporation fork addition).
#
# Kimi Code CLI (Moonshot) is gemini-style: a caller-minted --session <UUID>
# round-trips, and Kimi creates the session if the id does not exist — so the
# SAME --session id on a later run resumes it, with no sidecar capture. This
# means run_agent AND resume_agent share one argv shape:
#
#   kimi --print --output-format stream-json --session <uuid> \
#        [--model <m>] [<EXTRA_ARGS>...]            (prompt via stdin, INV-34)
#
# The auto-approve flag (--yolo / --afk; version-dependent — verify in the
# lab spike) is operator-tunable via AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS,
# NOT hardcoded — mirroring the post-#140 gemini contract.
#
# Run: bash tests/unit/test-lib-agent-kimi.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      expected='$expected'"; echo "      actual=  '$actual'"; FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle='$needle'"; echo "      haystack='${haystack:0:300}'"; FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      should not contain: '$needle'"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-KIMI-STATIC-001: source-of-truth grep — kimi branch shape ==="
# ---------------------------------------------------------------------------
if grep -qE '^[[:space:]]*kimi\)[[:space:]]*$' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: kimi case label present in lib-agent.sh"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: kimi case label missing in lib-agent.sh"; FAIL=$((FAIL + 1))
fi
kimi_case_count=$(grep -cE '^[[:space:]]*kimi\)[[:space:]]*$' "$LIB" || echo 0)
assert_eq "lib-agent.sh has kimi case in both run_agent and resume_agent" "2" "$kimi_case_count"

# ---------------------------------------------------------------------------
# Behavioral sandbox
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
PID_DIR="$TMPROOT/pid"; mkdir -p "$PID_DIR"; chmod 700 "$PID_DIR"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"

# Stub kimi: record argv + stdin, emit a known JSONL stream (incl. a
# tool-denial error event to prove the stdout pass-through preserves it).
cat > "$BIN/kimi" <<'EOF'
#!/bin/bash
echo "$@" > "$KIMI_ARGS_FILE"
cat > "${KIMI_STDIN_FILE:-/dev/null}"
cat <<JSONL
{"type":"init","session_id":"replayed-by-stub","model":"kimi-k2.6"}
{"type":"tool_use","name":"RunShell","args":{"command":"git commit -m test"}}
{"type":"error","message":"Unauthorized tool call: RunShell denied."}
{"type":"result","status":"success","stats":{"total_tokens":100}}
JSONL
EOF
chmod +x "$BIN/kimi"

cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/kimi-args"
STDIN_FILE="$TMPROOT/kimi-stdin"
SESSION_ID="a1b2c3d4-1111-2222-3333-444444444444"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-001..005: run_agent default invocation ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"
run_agent_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=kimi \
  AGENT_PERMISSION_MODE=auto \
  AGENT_DEV_EXTRA_ARGS="--yolo --output-format stream-json" \
  KIMI_ARGS_FILE="$ARGS_FILE" \
  KIMI_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
  ' 2>&1
)
run_agent_rc=$?

assert_eq "run_agent kimi returns 0 on success" 0 "$run_agent_rc"

# Hallucination defense: stdout pass-through preserves all event types incl. denial.
assert_contains "stdout includes init event" '"type":"init"' "$run_agent_output"
assert_contains "stdout PRESERVES tool-denial error event" "Unauthorized tool call" "$run_agent_output"
assert_contains "stdout includes result event" '"type":"result"' "$run_agent_output"

kimi_argv=$(cat "$ARGS_FILE")

# TC-KIMI-001: structural --print headless flag.
assert_contains "TC-KIMI-001 argv contains --print" "--print" "$kimi_argv"
# TC-KIMI-002: stream-json arrives via EXTRA_ARGS (NOT hardcoded — post-#140
# contract, enforced by test-lib-agent-extra-args.sh TC-EXTRA-002).
assert_contains "TC-KIMI-002 argv contains --output-format stream-json (via EXTRA_ARGS)" "--output-format stream-json" "$kimi_argv"
# TC-KIMI-003: caller-minted --session UUID round-trips.
assert_contains "TC-KIMI-003 argv pairs --session with the dispatcher UUID" "--session $SESSION_ID" "$kimi_argv"
# TC-KIMI-004: auto-approve flag arrives via EXTRA_ARGS passthrough.
assert_contains "TC-KIMI-004 argv contains --yolo (via AGENT_DEV_EXTRA_ARGS)" "--yolo" "$kimi_argv"
# TC-KIMI-004b: stream-json is NOT hardcoded on an EXECUTABLE line of the kimi
# branch (comments may mention it as the canonical EXTRA_ARGS value). The global
# invariant is also enforced by test-lib-agent-extra-args.sh TC-EXTRA-002.
kimi_exec_lines=$(sed -n '/^    kimi)/,/^    kiro)/p' "$LIB" | grep -vE '^\s*#' | head -40)
assert_not_contains "TC-KIMI-004b kimi branch does not hardcode stream-json (executable lines)" \
  "--output-format stream-json" "$kimi_exec_lines"
# TC-KIMI-005: empty model → no --model.
assert_not_contains "TC-KIMI-005 argv does NOT contain --model when model empty" "--model" "$kimi_argv"

# Prompt via stdin (INV-34), not argv.
kimi_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "stdin contains the prompt (INV-34 channel)" "implement the thing" "$kimi_stdin"
assert_not_contains "argv does NOT carry the prompt as a positional" "implement the thing" "$kimi_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-006: run_agent with model passes --model ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kimi \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--yolo" \
KIMI_ARGS_FILE="$ARGS_FILE" \
KIMI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "with model" "kimi-k2.6" ""
' >/dev/null 2>&1
model_argv=$(cat "$ARGS_FILE")
assert_contains "TC-KIMI-006 argv contains --model kimi-k2.6" "--model kimi-k2.6" "$model_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-007,008: resume_agent reuses --session <id> (NOT --resume) ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kimi \
AGENT_PERMISSION_MODE=auto \
AGENT_REVIEW_EXTRA_ARGS="--yolo --output-format stream-json" \
KIMI_ARGS_FILE="$ARGS_FILE" \
KIMI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "follow-up: address review feedback" "" ""
' >/dev/null 2>&1
resume_argv=$(cat "$ARGS_FILE")
resume_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)

# TC-KIMI-007: resume keeps the caller-minted --session id (the id round-trip IS the resume).
assert_contains "TC-KIMI-007 resume argv pairs --session with the dispatcher UUID" "--session $SESSION_ID" "$resume_argv"
# Kimi resume must NOT use a --resume flag (the session-id round-trip carries state).
assert_not_contains "TC-KIMI-007 resume argv does NOT use --resume" "--resume" "$resume_argv"
# Structural flags survive on resume.
assert_contains "TC-KIMI-008 resume argv keeps --print" "--print" "$resume_argv"
assert_contains "TC-KIMI-008 resume argv keeps --output-format stream-json" "--output-format stream-json" "$resume_argv"
assert_contains "TC-KIMI-008 resume argv keeps --yolo (via REVIEW_EXTRA_ARGS)" "--yolo" "$resume_argv"
# Prompt via stdin on resume too.
assert_eq "TC-KIMI-008 resume stdin contains follow-up prompt" "follow-up: address review feedback" "$resume_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
