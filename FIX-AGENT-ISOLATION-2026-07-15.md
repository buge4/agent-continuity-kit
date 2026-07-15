# CRITICAL FIX — agent-name isolation (found by Arctico, 2026-07-15)

**Bug (proven):** hooks used `${CLAUDE_AGENT_NAME:-unknown}`, and the var was set in `~/.zshrc`
— which NON-INTERACTIVE hook shells never read. So on any host running MULTIPLE agents under
ONE OS user, every agent silently resolved to `unknown` and collided on `state/unknown/`.
It only LOOKED fine where copies were hand-synced. **The isolation did not exist.**

**Fix (this release):**
1. `hooks/_resolve-agent.sh` — shared resolver. Resolves `CLAUDE_AGENT_NAME`; if empty/unknown it
   FAILS LOUD (logs to `~/.claude/hook-errors.log`, refuses to write to `unknown`, and
   session-start injects a `CONTINUITY DISABLED` banner). It can NEVER silently corrupt again.
2. Every session MUST carry its identity:
   - **Headless/autonomous:** your launcher must `export CLAUDE_AGENT_NAME=<agent>` (Veriton's
     fleet-run.sh now does this per alias).
   - **Interactive:** launch via `bin/claude-as <agent> [args...]` (exports the name, then claude).
   - Own-OS-user-per-agent hosts (e.g. Arctico) can also set it in that user's `settings.json` `env`.
3. Verify with a CROSS-BLEED test: run two agents, confirm distinct `state/<name>/` dirs and NO
   `state/unknown/`; run with the var unset and confirm the hook REFUSES.

Credit: **Arctico** caught this before we scaled to new agents. The friend-review loop worked.
