#!/usr/bin/env bash
# autonomous-dev entrypoint: bootstrap (clone target, wire hooks/labels) then tick loop.
# Claude auth = subscription creds seeded into /root/.claude; Anthropic via HTTPS_PROXY
# (France ts-exit); GitHub direct (NO_PROXY) as the App bot.
set -euo pipefail

SKILLS=/opt/autonomous-dev/skills
SCRIPTS="$SKILLS/autonomous-dispatcher/scripts"
export AUTONOMOUS_CONF=/opt/autonomous-dev/autonomous.conf
# shellcheck source=/dev/null
source "$AUTONOMOUS_CONF"

log() { echo "[entrypoint] $*"; }

# --- mint a GitHub App installation token (self-contained; used only for bootstrap clone) ---
mint_token() {
  local now header payload si sig jwt inst_url inst_id tok
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$DISPATCHER_APP_ID" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  si="${header}.${payload}"
  sig=$(printf '%s' "$si" | openssl dgst -sha256 -sign "$DISPATCHER_APP_PEM" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  jwt="${si}.${sig}"
  inst_id=$(curl -s -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/installation" | jq -r '.id')
  tok=$(curl -s -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${inst_id}/access_tokens" | jq -r '.token')
  printf '%s' "$tok"
}

# --- 1. clone target repo into the work volume if absent ---
if [ ! -d "$PROJECT_DIR/.git" ]; then
  log "cloning $REPO -> $PROJECT_DIR"
  tok=$(mint_token)
  git clone --branch "$DEFAULT_BRANCH" \
    "https://x-access-token:${tok}@github.com/${REPO}.git" "$PROJECT_DIR"
fi
git config --global --add safe.directory "$PROJECT_DIR"

# --- 2. wire zxkane's project-side symlinks (hooks + scripts) ---
ln -sfn "$SKILLS/autonomous-common/hooks" "$PROJECT_DIR/hooks"
ln -sfn "$SCRIPTS" "$PROJECT_DIR/scripts"

# --- 3. install Claude TDD hooks + create pipeline labels (idempotent, best-effort) ---
# Keep the runtime-generated files (hooks config + symlinks) out of git so the agent
# can never commit them into a PR against the target repo.
for _ex in ".claude/" "hooks" "scripts"; do
  grep -qxF "$_ex" "$PROJECT_DIR/.git/info/exclude" 2>/dev/null || echo "$_ex" >> "$PROJECT_DIR/.git/info/exclude"
done
# Run from INSIDE the repo with NO arg: the installer resolves project_root via
# `git rev-parse --show-toplevel`, and the wrapper launches Claude from PROJECT_DIR
# (so $CLAUDE_PROJECT_DIR/hooks -> the symlink above, resolving correctly).
if [ -f "$SKILLS/autonomous-common/scripts/install-claude-hooks.sh" ]; then
  ( cd "$PROJECT_DIR" && bash "$SKILLS/autonomous-common/scripts/install-claude-hooks.sh" ) \
    && log "Claude TDD hooks installed" \
    || log "WARN: claude hook install failed (non-fatal)"
fi
# setup-labels calls gh directly — give it a freshly minted App token (scoped to
# this one command; the dispatcher loop mints its own per tick, so we do NOT export
# a global GH_TOKEN that would go stale after 1h).
GH_TOKEN="$(mint_token)" bash "$SCRIPTS/setup-labels.sh" "$REPO" || log "WARN: label setup failed (non-fatal)"

# --- 4. tick loop (state lives in GitHub labels; box is crash-restartable) ---
log "claude: $(claude --version 2>/dev/null || echo MISSING) | gh: $(gh --version 2>/dev/null | head -1)"
log "entering dispatch loop (every ${TICK_SECONDS:-300}s); auto-merge ON, gated by branch protection"
while true; do
  bash "$SCRIPTS/dispatcher-tick.sh" || log "tick returned non-zero (non-fatal; will retry)"
  sleep "${TICK_SECONDS:-300}"
done
