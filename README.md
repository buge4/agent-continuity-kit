# agent-continuity-kit

Zero-cloud, $0-cost durable memory for Claude Code agents.

Gives any Claude Code session (cron-runner or interactive) persistent state that
survives `/clear`, context compaction, cron restarts, and machine reboots.

## What it does

Three Claude Code hooks + one snapshot cron + one git state repo:

- **SessionStart hook**: injects prior session state as `<restored-state>` context
  at the top of every new session. Agent picks up exactly where it left off.
- **Stop hook**: stamps `UPDATED:` timestamp after every agent turn.
- **PreCompact hook**: saves the compaction summary before context is trimmed,
  and triggers a background git commit so state survives `/clear`.
- **state-snapshot cron** (*/5): rebuilds `MASTER-LEDGER.md` (one-line summary
  per agent) and commits to git. Flock-guarded against concurrent writers.

## Requirements

- bash, python3, git
- `crontab` (standard Linux/macOS)
- A git remote is optional but recommended (any private repo works)

## Install

```bash
# Minimal (local git only, interactive use):
AGENT_NAME=myagent bash install-durable-memory.sh

# With git remote (recommended for cron runners):
AGENT_NAME=myagent STATE_REPO_URL=git@github.com:you/agent-state.git \
  bash install-durable-memory.sh
```

Re-running is safe. All steps are idempotent.

## One mandatory step: set AGENT_NAME in your runner

After install, add one line to whatever launches Claude:

```bash
export CLAUDE_AGENT_NAME=myagent
# then your normal claude invocation:
claude -p "$(cat prompt.txt)" --dangerously-skip-permissions
```

Without this, the hooks use `CLAUDE_AGENT_NAME=unknown` and state is siloed
under `~/.claude/state/unknown/`. Set it and all three hooks wire up instantly.

## State file convention

Edit `~/.claude/state/<agent>/current.md` to hold the agent's working state.
The hooks read and update this file. Suggested sections:

```markdown
LAST_COMPACTED: 2026-07-14T01:00:00Z
UPDATED: 2026-07-14T01:30:00Z
# myagent -- session-continuity STATE

## NEXT_ACTION
What to do next time this agent fires.

## BLOCKERS
Anything waiting on a human or external system.

## DONE (recent)
Last 3-5 completed milestones.
```

## Multiple agents on one machine

Install once. Each agent sets a different `CLAUDE_AGENT_NAME`. State is isolated
under `~/.claude/state/<agent>/`. The snapshot cron collects all agents into
one `MASTER-LEDGER.md` so you see fleet-wide status at a glance.

## Files installed

```
~/.claude/hooks/pre-compact-save.sh       # PreCompact
~/.claude/hooks/post-stop-save.sh         # Stop
~/.claude/hooks/session-start-restore.sh  # SessionStart
~/.claude/bin/state-snapshot.sh           # cron target
~/.claude/bin/state-commit.sh             # git commit helper
~/.claude/state/<agent>/current.md        # agent state (you edit this)
~/.claude/state/MASTER-LEDGER.md          # auto-generated fleet index
```

## License

MIT. No dependencies beyond bash + python3 + git.
