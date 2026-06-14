# quantflows × autonomous-dev — production integration runbook

How this fork (AutoScribeCorporation/autonomous-dev, a fork of zxkane/autonomous-dev-team)
runs the autonomous issue→PR→review→merge loop against **`QuantFlowsCorporation/backend`**
(a real Interactive-Brokers trading system), on the autoscribe homelab, with Kimi as the
worker — **cleanly and safely for production.**

> Status: the **Kimi adapter is implemented + unit-tested** (`tests/unit/test-lib-agent-kimi.sh`,
> 21/21). Everything below the line marked **HUMAN-ONLY** requires credentials/UI only the
> operator can create. **The loop ships in human-merge / no-auto-merge posture** — auto-merge
> into money-moving trading code is OFF until the gates below are proven on throwaway issues.

## Three planes (unchanged from the design)
- **GitHub = state machine.** Labels (`autonomous → in-progress → pending-review → reviewing → merged`,
  fail → `pending-dev`, exhausted → `stalled`) hold loop state. The homelab box is stateless/crash-restartable.
- **OpenClaw = deterministic dispatcher.** `dispatcher-tick.sh` on a 5-min cron (your existing OpenClaw cron,
  or plain `*/5`). Outbound-only (gh API + Kimi API) — fits CGNAT; no inbound webhook.
- **Kimi = worker**, in an isolated git worktree, via the new `kimi)` adapter in `lib-agent.sh`.

## What this fork adds over upstream
1. `kimi)` branches in `run_agent`/`resume_agent` (`skills/autonomous-dispatcher/scripts/lib-agent.sh`) —
   `--print --session <uuid>` structural; `--yolo --output-format stream-json` via EXTRA_ARGS (gemini contract).
2. `tests/unit/test-lib-agent-kimi.sh` (21 assertions; run with bash ≥4: `bash tests/unit/test-lib-agent-kimi.sh`).
3. The "kimi block" in `autonomous.conf.example` (canonical EXTRA_ARGS + headless-auth notes).
4. This runbook.

## Production hardening you MUST add on top (NOT shipped by upstream — verified absent)
| Control | Why | How |
|---|---|---|
| **Required status checks** | upstream merges on the LLM verdict + merge-conflict only — a red-CI/hallucinated PASS can merge | On `QuantFlowsCorporation/backend` `main`: branch protection → require `CI` + `Verify` (the repo's existing workflows: ruff, mypy, pytest) as **required** checks. The platform then refuses merge on red — never trust the agent's self-report. |
| **Container sandbox** | `--print` implies auto-approve = full shell/file writes; upstream spawns agents via `nohup` on the host | Run each Kimi stage in a hardened Docker container, worktree mounted, **no IB/broker/Postgres creds in env**, egress allowlist = Kimi API + api.github.com only. |
| **Privilege separation** | dev agent holding a write token + prompt-injection = token theft | `GH_AUTH_MODE=app` (already supported): a dedicated **GitHub App** mints 1h installation tokens; the deterministic dispatcher (not the agent) opens/merges PRs. |
| **Per-attempt isolation** | worktrees isolate code only; shared DB/ports collide → corrupt backtests | Ephemeral Postgres + unique ports (hash branch) per attempt; `MAX_CONCURRENT=2–3` on one box. |
| **Cost circuit breaker** | a Ralph/retry loop can burn tokens unwatched | parse Kimi `stream-json` token counts → per-attempt + daily $ caps → auto-kill + **ntfy page** (reuse the homelab bus); finite `--max-ralph-iterations`; `MAX_RETRIES=3 → stalled` (never auto-merges). |
| **Convergence detection** | not in any reference — unanimous panel + non-deterministic reviewers can burn the retry budget | hash each round's reviewer findings; short-circuit to `stalled` + ntfy when findings repeat, before exhausting retries. |
| **Diverse reviewers** | two identical Kimi sessions share blind spots | `AGENT_REVIEW_AGENTS`: Kimi (correctness) + a different-model quality reviewer + a deterministic non-LLM gate (ruff/mypy/pytest/gitleaks as a required check). |
| **Financial CODEOWNERS** | passing tests ≠ financially correct (look-ahead bias, PnL/risk-limit bugs) | `CODEOWNERS` requiring **human approval** on `src/engines/{risk,execution,strategy}` + `src/domain/*`. `no-auto-close` on these paths indefinitely. |

## HUMAN-ONLY setup (operator must do; cannot be scripted headlessly)
1. **Create a GitHub App** for the loop, install it on `QuantFlowsCorporation/backend` only, least-privilege
   (`contents:write`, `pull_requests:write`, `issues:write`, `checks:read`). Download the private key →
   store as a SOPS secret. Set `GH_AUTH_MODE=app`, `DISPATCHER_APP_ID`, `DISPATCHER_APP_PEM` in the conf.
2. **Kimi API key** → `~/.kimi/config.toml` for the worker container (SOPS-rendered at deploy). Lab-verify
   headless auth in a clean non-interactive shell (no credential env vars) against the pinned CLI version.
3. **Branch protection** on `main`: required checks (`CI`, `Verify`), required human review on CODEOWNERS paths,
   no force-push. (The loop's `refactor/loop-redesign` work should land first or the loop should target `main`.)
4. **Restrict the `autonomous` label** to the operator (issue text is untrusted input → prompt-injection surface).

## Bring-up sequence (safe → trusted)
1. **Adapter proof (done):** `bash tests/unit/test-lib-agent-kimi.sh` → 21/21.
2. **Lab spike:** in the worker container, confirm `kimi --print --session <uuid>` (stdin prompt) + auth +
   `--yolo` vs `--afk` against the pinned build. Fix the EXTRA_ARGS value if needed (no code change).
3. **Dry run, human-merge:** one throwaway `autonomous` issue on a sandbox branch; watch dev→review;
   merge by hand. No auto-merge, no sandbox-bypass.
4. **Harden:** add the container sandbox, App tokens, required checks, per-attempt DB/ports, cost breaker→ntfy.
5. **Graduate:** auto-merge only on non-critical paths once required checks have proven themselves over several
   real issues. Trading-critical paths (risk/execution/strategy) stay human-merge — by design, not as a limitation.

## Pinning
Fork pinned to upstream `8ea5a47` (2026-06-14). Upstream moves fast (multi-merge/day; adapter refactor #232) —
review before rebasing; do NOT auto-pull. Re-run `tests/unit/test-lib-agent-kimi.sh` after any rebase and after
any Kimi CLI version bump.
