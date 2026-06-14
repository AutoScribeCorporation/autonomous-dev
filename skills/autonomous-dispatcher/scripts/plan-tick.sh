#!/usr/bin/env bash
# plan-tick.sh — DAG planner DRY-RUN (Option B, Phase P0).
#
# For each `autonomous-plan`-labelled OPEN issue that has neither `plan-proposed`
# nor `plan-error`, run a READ-ONLY planner (claude --permission-mode plan, so it
# cannot mutate anything) that explores the repo, classifies complexity, and emits
# a RIGHT-SIZED DAG plan as JSON. We validate the JSON and POST it to the issue.
#
# This executes NOTHING and opens NO PR — it is a pure proposal so plan quality and
# right-sizing can be reviewed before the DAG executor (P1) is built. Completely
# isolated from the working dev->review pipeline (different label, read-only worktree).
set -uo pipefail

_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/autonomous.conf" ] && source "$SCRIPT_DIR/autonomous.conf"
: "${REPO:?}" "${REPO_OWNER:?}" "${REPO_NAME:?}" "${PROJECT_DIR:?}"
# shellcheck source=gh-app-token.sh
source "$LIB_DIR/gh-app-token.sh"

log() { echo "[plan-tick] $(date -u +%H:%M:%S) $*"; }

GH_TOKEN="$(get_gh_app_token "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" "$REPO_OWNER" "$REPO_NAME" 2>/dev/null)" || { log "token mint failed; skipping"; exit 0; }
export GH_TOKEN

# Ensure the P0 labels exist (idempotent, best-effort).
for L in "autonomous-plan:#5319e7:DAG planner dry-run (Option B P0)" \
         "plan-proposed:#0e8a16:a DAG plan was posted" \
         "plan-error:#b60205:planner failed to emit a valid plan"; do
  name="${L%%:*}"; rest="${L#*:}"; color="${rest%%:*}"; desc="${rest#*:}"
  gh label view "$name" --repo "$REPO" >/dev/null 2>&1 || \
    gh label create "$name" --repo "$REPO" --color "${color#\#}" --description "$desc" >/dev/null 2>&1 || true
done

# Candidate issues: labelled autonomous-plan, not yet proposed/errored.
mapfile -t ISSUES < <(gh issue list --repo "$REPO" --label autonomous-plan --state open --json number,labels \
  --jq '.[] | select([.labels[].name] | (contains(["plan-proposed"]) or contains(["plan-error"])) | not) | .number' 2>/dev/null)
[ "${#ISSUES[@]}" -eq 0 ] && exit 0

for NUM in "${ISSUES[@]}"; do
  log "planning issue #$NUM (dry-run)"
  TITLE=$(gh issue view "$NUM" --repo "$REPO" --json title --jq .title 2>/dev/null)
  BODY=$(gh issue view "$NUM" --repo "$REPO" --json body --jq .body 2>/dev/null)

  # Read-only detached worktree snapshot so the planner can explore the repo without
  # racing the per-tick clone-sync (reset --hard) on the primary worktree.
  WT="/tmp/plan-$NUM"
  rm -rf "$WT"
  git -C "$PROJECT_DIR" worktree add -q --detach "$WT" HEAD 2>/dev/null || { log "#$NUM worktree add failed"; continue; }

  PROMPT=$(cat <<EOF
You are the PLANNING agent of an autonomous software pipeline working on a Python
quantitative-trading backend (Interactive Brokers; real money). You are READ-ONLY —
do not modify any files.

Your job: analyse GitHub issue #${NUM} and emit a RIGHT-SIZED execution plan as a
DAG of agent stages. Explore the repo as needed to understand scope and impact.

ISSUE #${NUM}: ${TITLE}
---
${BODY}
---

Available node types (the final GitHub PR review+merge is a FIXED stage you must NOT include):
- implementer            — writes the code change (writes:true)
- test-author            — adds/updates tests (writes:true)
- refactor               — structural cleanup only (writes:true)
- integration-validator  — runs lint/typecheck/tests, reports pass/fail (writes:false)
- financial-correctness  — checks look-ahead bias / PnL accounting / risk-limit bypass (writes:false)
- secret-scanner         — deterministic secret/dep scan (writes:false)
- self-reviewer          — critiques the diff before PR (writes:false)

RIGHT-SIZING (critical — cost matters):
- trivial (docstring/typo/1-liner) -> a SINGLE implementer node. Do NOT over-engineer.
- small  -> implementer (+ maybe one validator).
- medium/large -> a fuller pipeline with validation gates + iteration.
- If the change touches risk/execution/strategy code, INCLUDE a financial-correctness node.

Output ONLY a single JSON object inside one \`\`\`json fenced block — no prose outside it —
matching this schema:
{
  "issue": ${NUM},
  "complexity": "trivial|small|medium|large",
  "impact": { "modules": ["path/..."], "touches_domain": ["risk"|"execution"|"strategy"|...] },
  "rationale": "one or two sentences on why this shape",
  "nodes": [
    { "id": "impl", "type": "implementer", "depends_on": [], "writes": true,
      "gate": { "kind": "none" } },
    { "id": "validate", "type": "integration-validator", "depends_on": ["impl"], "writes": false,
      "gate": { "kind": "verdict", "on_fail": "loop", "loop_target": "impl", "max_iter": 3 } }
  ]
}
Node ids unique; depends_on must reference existing node ids; no cycles.
EOF
)

  RAW=$(cd "$WT" && printf '%s' "$PROMPT" | timeout 600 env -u CLAUDECODE claude --permission-mode plan -p --output-format json 2>/dev/null)
  git -C "$PROJECT_DIR" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"

  # Extract the assistant text -> the ```json plan -> validate -> format a comment.
  RESULT=$(python3 - "$NUM" <<'PY'
import json, re, sys
num = sys.argv[1]
raw = sys.stdin.read()
try:
    text = json.loads(raw).get("result", "")
except Exception:
    text = raw
m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.S) or re.search(r"(\{.*\})", text, re.S)
if not m:
    print("ERROR\tno JSON plan found in planner output"); sys.exit(0)
try:
    plan = json.loads(m.group(1))
except Exception as e:
    print(f"ERROR\tplan JSON did not parse: {e}"); sys.exit(0)

ALLOWED = {"implementer","test-author","refactor","integration-validator",
           "financial-correctness","secret-scanner","self-reviewer"}
errs = []
nodes = plan.get("nodes")
if plan.get("complexity") not in {"trivial","small","medium","large"}:
    errs.append(f"bad complexity: {plan.get('complexity')!r}")
if not isinstance(nodes, list) or not nodes:
    errs.append("nodes must be a non-empty list")
else:
    ids = [n.get("id") for n in nodes]
    if len(ids) != len(set(ids)): errs.append("duplicate node ids")
    for n in nodes:
        if n.get("type") not in ALLOWED: errs.append(f"node {n.get('id')!r}: bad type {n.get('type')!r}")
        for d in n.get("depends_on", []):
            if d not in ids: errs.append(f"node {n.get('id')!r}: depends_on missing id {d!r}")
if errs:
    print("ERROR\t" + "; ".join(errs)); sys.exit(0)

# Render a human-readable plan comment.
lines = [f"### Proposed DAG plan for #{num} (dry-run — nothing executed)",
         f"**Complexity:** `{plan.get('complexity')}`  ",
         f"**Impact:** modules={plan.get('impact',{}).get('modules')} · domains={plan.get('impact',{}).get('touches_domain')}  ",
         f"**Rationale:** {plan.get('rationale','')}", "", "| node | type | depends_on | writes | gate |", "|---|---|---|---|---|"]
for n in nodes:
    g = n.get("gate", {})
    gs = g.get("kind","none") + (f" → {g.get('on_fail')}→{g.get('loop_target')} (≤{g.get('max_iter')})" if g.get("kind")=="verdict" else "")
    lines.append(f"| `{n['id']}` | {n['type']} | {', '.join(n.get('depends_on',[])) or '—'} | {'yes' if n.get('writes') else 'no'} | {gs} |")
lines += ["", "<details><summary>raw plan.json</summary>", "", "```json", json.dumps(plan, indent=2), "```", "</details>",
          "", "_P0 dry-run: the executor (P1) is not built yet, so this plan is proposed only._"]
print("OK\t" + "\n".join(lines))
PY
<<<"$RAW")

  STATUS="${RESULT%%$'\t'*}"; COMMENT="${RESULT#*$'\t'}"
  if [ "$STATUS" = "OK" ]; then
    gh issue comment "$NUM" --repo "$REPO" --body "$COMMENT" >/dev/null 2>&1 || log "#$NUM comment failed"
    gh issue edit "$NUM" --repo "$REPO" --add-label plan-proposed >/dev/null 2>&1 || true
    log "#$NUM plan posted"
  else
    gh issue comment "$NUM" --repo "$REPO" --body "⚠️ Planner could not produce a valid plan: ${COMMENT}" >/dev/null 2>&1 || true
    gh issue edit "$NUM" --repo "$REPO" --add-label plan-error >/dev/null 2>&1 || true
    log "#$NUM plan-error: ${COMMENT}"
  fi
done
