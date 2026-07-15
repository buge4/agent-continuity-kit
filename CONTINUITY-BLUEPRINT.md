# Veriton Agent Continuity + Auth + Security — Blueprint & Audit

**Canonical as of 2026-07-16.** This is the "what we have" document for the agent
continuity / durable-memory / auth system that every Veriton box agent — and every
friend/Arctico setup that adopted the kit — should run. Verify your box matches it by
running **`continuity-audit.sh`** (ships alongside this file). Target: `0 FAIL`.

Design principle: **verify, don't assume.** Every component below is checkable by a
script, not by a claim. The 2026-07-15/16 outage is why: two independent faults
(a weekly-cap AND a silently-broken `claude` binary) each looked identical from the
alarm's view. The audit exists so "it's fine" is a measured fact.

---

## The 8 pillars (each = one audit section)

### 1. Auth — token POOL rotation + secure seat management
- **`claude-auth-exec.sh` v2** — single reader of the auth env; runs `claude` on an
  **N-seat OAuth pool** (`CLAUDE_CODE_OAUTH_TOKEN`, `_2`..`_9`, `_FALLBACK`). Each seat
  = one Team/Max weekly cap; pooling multiplies weekly capacity at **$0**. On a
  401/429/usage-limit/"credit balance" error a seat is marked capped (cooldown, default
  1h) and rotation moves to the next live seat. Real task errors are NOT rotated.
- **Paid API-key backstop is OFF by default** — engages only when *all* OAuth seats are
  capped AND `VERITON_ALLOW_PAID_BACKSTOP=1`. Never spends silently (cost-safety law).
- **`add-seat.sh [auto|fallback|primary]`** — add a seat's token via a SILENT prompt;
  never in chat/argv/history. `claude setup-token` on the seat → paste → done.
- Auth env (`/etc/veriton/claude-auth.env`) has **no world access**; group must be
  single-member or explicitly trusted. Friends/Arctico use their OWN env + OWN seats —
  **never Veriton's keys.**

### 2. Binary health — the guard that would have prevented the outage
- **`claude-binary-guard.sh`** (cron `*/30`) — if `claude --version` ever returns
  *"native binary not installed"* (a claude-code update that skipped its postinstall),
  it re-runs `node install.cjs` automatically. This single fault took the whole fleet
  dark on 2026-07-16; the guard makes it self-heal.

### 3. Identity — fail-loud, never silent
- **`~/.claude/hooks/_resolve-agent.sh`** resolves the agent name and FAILS LOUD rather
  than defaulting to `unknown`/`main` (which would cross-write another agent's state).
- Every long-lived unit carries a non-empty `CLAUDE_AGENT_NAME` (`/etc/claude-assistant/*.env`,
  `launch-agent.sh`, Mac aliases). Empty name = wrong state save/restore on restart.
- Guard hooks: `block-secrets-read.sh`, `block-prod-write.sh`.

### 4. State — per-agent handover, git-backed off-box
- `~/.claude/state/<agent>/current.md` (+ `history.md`, `MASTER-LEDGER.md`); must have
  `NEXT_ACTION` and real content. Backed by a **private git repo** (`buge4/agent-state`)
  so memory survives the box.

### 5. Snapshot + refresh — the 3-layer keepers
- **`state-snapshot.sh`** (cron `*/5`) commits state off-box.
- **`haiku-refresh.sh`** (Layer C) — MUST carry the anti-hallucination guard
  (reproduce state VERBATIM; never invent/borrow a NEXT_ACTION). The 2026-07-16 fix.

### 6. Nightly restart — clear long-lived sessions once/night
- **`nightly-restart.sh <agent>`** — state-commit → backup → `systemctl restart` → verify,
  for **long-lived remote-control sessions** (assistant/books/claudeweb-type).
- **Important:** stateless cron RUNNERS (`claude -p` oneshot per fire) need NO nightly
  clear — they start fresh every fire. Only long-lived remote-control/tmux sessions do.
  Don't bolt a pointless restart onto stateless runners.

### 7. Secret hygiene
- No secrets world-readable under `~/.claude`/`~/.config`; auth env `600`/`640`-trusted.
- No secret committed in the state repo; `.gitignore` + secret-scan guard in place.

### 8. Watchdogs (optional but recommended)
- `stuck-git-watchdog.sh` + a cron watchdog for wedged pushes / dead sessions.

---

## How to adopt / verify (friends + Arctico)
1. Copy the kit scripts into `~/.claude/bin` (+ `hooks/`), wire the crons.
2. Use your OWN auth env + OWN OAuth seats (`add-seat.sh`). Never Veriton's keys.
3. Run **`continuity-audit.sh`** → drive it to **0 FAIL**; address WARNs when convenient.
4. Re-run the audit after any change. It's read-only and safe.

**Baseline achieved on veriton-prod 2026-07-16: 30 PASS / 0 WARN / 0 FAIL.**
