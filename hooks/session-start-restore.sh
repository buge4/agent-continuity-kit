#!/usr/bin/env bash
# SessionStart hook: emit prior session state so agent resumes in context.
# Emits a <restored-state> block injected into the new session's system context.
# Exit 0 always -- silence is correct if no state exists.
set -uo pipefail

AGENT="${CLAUDE_AGENT_NAME:-unknown}"
STATE_DIR="$HOME/.claude/state/$AGENT"
CUR="$STATE_DIR/current.md"
LOG="$STATE_DIR/compact-save.log"

[ -f "$CUR" ] || exit 0

# Age check: skip if current.md older than 48h (dead agent, start fresh)
NOW=$(date +%s)
MTIME=$(stat -c %Y "$CUR" 2>/dev/null || python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$CUR" 2>/dev/null || echo 0)
AGE=$(( NOW - MTIME ))
[ "$AGE" -gt 172800 ] && exit 0

echo "<restored-state>"
echo "# Prior session state for agent: $AGENT"
echo "# State file last updated: $(date -r "$CUR" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
cat "$CUR"

if [ -f "$LOG" ] && [ -s "$LOG" ]; then
    LOG_MTIME=$(stat -c %Y "$LOG" 2>/dev/null || echo 0)
    LOG_AGE=$(( NOW - LOG_MTIME ))
    if [ "$LOG_AGE" -lt 86400 ]; then
        echo ""
        echo "## Last compacted context summary (tail):"
        tail -20 "$LOG"
    fi
fi
echo "</restored-state>"
exit 0
