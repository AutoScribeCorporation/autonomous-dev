#!/usr/bin/env bash
# autonomous-dev entrypoint: bootstrap (clone target, wire hooks/labels) then tick loop.
# Claude auth = subscription creds seeded into /root/.claude; Anthropic via HTTPS_PROXY
# (France ts-exit); GitHub direct (NO_PROXY) as the App bot.
set -euo pipefail

SKILLS=/opt/autonomous-dev/skills
SCRIPTS="$SKILLS/autonomous-dispatcher/scripts"
export AUTONOMOUS_CONF="$SCRIPTS/autonomous.conf"
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
# Commit identity = the GitHub App bot. Without this, git falls back to
# root@<hostname> and errors ("hostname contains invalid characters") the moment
# a hook/agent touches git; it also gives PRs proper bot attribution.
git config --global user.name "autoscribe-dev[bot]"
git config --global user.email "293492157+autoscribe-dev[bot]@users.noreply.github.com"

# --- 2. wire the `hooks` symlink only ---
# We do NOT symlink `scripts` at the repo root: the target repo (backend) owns its
# own scripts/ dir, so the toolkit's spawn sites were patched to use LIB_DIR (the
# real /opt scripts dir) instead of $PROJECT_DIR/scripts. `hooks` is safe to symlink
# (backend has no hooks/ dir) and is needed by the Claude TDD hooks ($CLAUDE_PROJECT_DIR/hooks).
ln -sfn "$SKILLS/autonomous-common/hooks" "$PROJECT_DIR/hooks"

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

# --- 3b. seed ~/.claude.json (cosmetic) ---
# Claude's top-level config lives at $HOME/.claude.json — a SIBLING of the mounted
# .claude/ volume, so it's absent after every recreate. Claude then restores it
# from a backup inside the volume and logs a "config file not found" notice on
# every invocation. Restore it once at startup from the newest backup to silence
# that noise. (If no backup exists yet, Claude creates it on first run.)
if [ ! -f "$HOME/.claude.json" ]; then
  _cfg_bak=$(ls -t "$HOME"/.claude/backups/.claude.json.backup.* 2>/dev/null | head -1)
  if [ -n "$_cfg_bak" ]; then
    cp "$_cfg_bak" "$HOME/.claude.json" && log "seeded ~/.claude.json from backup ($(basename "$_cfg_bak"))"
  fi
fi

# --- 4. tick loop (state lives in GitHub labels; box is crash-restartable) ---
log "claude: $(claude --version 2>/dev/null || echo MISSING) | gh: $(gh --version 2>/dev/null | head -1)"
log "entering dispatch loop (every ${TICK_SECONDS:-300}s); auto-merge ON, gated by branch protection"
while true; do
  # Keep the base clone current so every new worktree branches off the LATEST
  # origin/<default> — otherwise sequential PRs fall BEHIND and strict branch
  # protection blocks their merge (root cause of the #62 stall). The primary
  # worktree sits on the default branch and is never edited by agents (they work
  # in .worktrees/), so a hard reset to origin is safe.
  # Refresh origin auth with a FRESH App installation token first: the clone's
  # embedded token expires after 1h, which silently breaks fetch AND the agent's
  # push (observed on #61). Re-setting the URL every tick keeps both working.
  _tok=$(mint_token 2>/dev/null || true)
  if [ -n "$_tok" ]; then
    git -C "$PROJECT_DIR" remote set-url origin "https://x-access-token:${_tok}@github.com/${REPO}.git" 2>/dev/null || true
    if git -C "$PROJECT_DIR" fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null; then
      git -C "$PROJECT_DIR" reset --hard -q "origin/$DEFAULT_BRANCH" 2>/dev/null \
        || log "WARN: could not fast-forward $DEFAULT_BRANCH to origin"
    else
      log "WARN: git fetch failed even after token refresh"
    fi
  else
    log "WARN: token mint failed; skipping clone sync this tick"
  fi
  bash "$SCRIPTS/dispatcher-tick.sh" || log "tick returned non-zero (non-fatal; will retry)"
  sleep "${TICK_SECONDS:-300}"
done
