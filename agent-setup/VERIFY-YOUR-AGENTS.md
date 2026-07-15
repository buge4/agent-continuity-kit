# Verify YOUR multi-agent setup (run this, paste the output to your chat)
After the agent-name isolation fix. Confirm ALL your Claude aliases/agents are correctly isolated on the fixed continuity system.
1. **Fix installed:** `ls ~/.claude/hooks/_resolve-agent.sh ~/.claude/bin/claude-as` — both must exist.
2. **Hooks are fail-loud:** `grep -L _resolve-agent ~/.claude/hooks/session-start-restore.sh ~/.claude/hooks/post-stop-save.sh ~/.claude/hooks/pre-compact-save.sh` — must print NOTHING (all 3 source _resolve-agent).
3. **Every alias sets its identity:** for EACH of your claude aliases, confirm the session exports `CLAUDE_AGENT_NAME=<its own name>` (via `claude-as <name>` or an export in its launcher). List every alias + its name.
4. **Distinct state, NO collision:** `ls ~/.claude/state/` — one dir per agent, and CRITICALLY **no `state/unknown/`** (that dir existing = your agents were colliding).
5. **Cross-bleed test:** launch two different agents -> each writes its own `state/<name>/current.md`; run a hook with the name UNSET -> it must REFUSE (fail-loud), not write to `unknown`.
6. **Paste steps 1-5 output into your chat** so it's provably green for you. Fix anything that isn't, then re-run.
