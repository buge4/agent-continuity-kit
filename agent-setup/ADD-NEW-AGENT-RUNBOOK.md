# Add a new fleet agent (thin Mac client + box orchestrator) — runbook
Pattern = exactly how claude2/floor/collab run. NO phone-remote for new agents.
1. Box orchestrator: mkdir ~/projects/<name>-orchestrator + write CLAUDE.md (persona + sibling map, "PM under claude2/saas").
2. Box loop: mkdir ~/<name>-pipeline; cp ~/rsc-analysis/queue-runner.sh ~/<name>-pipeline/<name>-runner.sh; sed-retarget (Q/LOCK/LOG -> <name>-pipeline, CLAUDE_AGENT_NAME=<name>, --agent <name>, state-commit.sh <name>); create <NAME>-QUEUE.md.
3. Cron: */10 <name>-runner.sh + */12 haiku-refresh.sh <name>.
4. Continuity: ~/.claude/state/<name>/current.md (snapshot cron auto-covers it). Auth+4-model inherited via claude-auth-exec.sh + fleet-run.sh.
5. Git repo: gh repo create buge4/<name>-collab (or -project) --private; push CLAUDE.md + current.md + README + HANDOVER + material.
6. Mac alias (~/.zshrc): claude<name>(){ _claude_remote <name> /home/veriton/projects/<name>-orchestrator <name> "Read CLAUDE.md + current.md then continue."; }  (_claude_remote now exports CLAUDE_AGENT_NAME=<title>.)
7. Verify: bash -n the runner; check cron; launch the alias once; confirm the loop reads the queue + posts a notice.
