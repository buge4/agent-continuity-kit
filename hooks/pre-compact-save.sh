#!/usr/bin/env bash
# PreCompact hook: save session summary before context compaction.
# Mandatory security fixes applied: chmod 700/600, secret-strip, 300-line cap, flock.
# Exit 0 on ALL errors -- never block a Claude turn.
set -uo pipefail

AGENT="${CLAUDE_AGENT_NAME:-unknown}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_DIR="$HOME/.claude/state/$AGENT"
GIT_LOCK="/tmp/claude-state-git.lock"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

LOG="$STATE_DIR/compact-save.log"

SUMMARY=""
if [ -t 0 ]; then
    SUMMARY=""
else
    SUMMARY=$(timeout 3 python3 -c "
import sys, json
try:
    raw = sys.stdin.read()
    if raw.strip():
        d = json.loads(raw)
        s = d.get('summary','') or d.get('compact_summary','') or d.get('context','')
        if isinstance(s, str):
            print(s[:4000])
except Exception:
    pass
" 2>/dev/null || echo "")
fi

if [ -n "$SUMMARY" ]; then
    SUMMARY=$(echo "$SUMMARY" | python3 -c "
import sys, re
patterns = [
    r'sk-[A-Za-z0-9\-_]{20,}',
    r'eyJ[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+',
    r'(?i)(password|secret|token|api.?key)\s*[:=]\s*\S+',
]
lines = []
for line in sys.stdin:
    for p in patterns:
        line = re.sub(p, '[REDACTED]', line)
    lines.append(line)
sys.stdout.write(''.join(lines))
" 2>/dev/null || echo "$SUMMARY")
fi

{
    echo "=== COMPACT $TS agent=$AGENT ==="
    [ -n "$SUMMARY" ] && echo "$SUMMARY" || echo "(no summary available)"
    echo ""
} >> "$LOG"

chmod 600 "$LOG" 2>/dev/null || true

if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 350 ]; then
    tail -300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG" && chmod 600 "$LOG" 2>/dev/null || true
fi

CUR="$STATE_DIR/current.md"
if [ -f "$CUR" ]; then
    python3 -c "
import sys, re
p, ts = sys.argv[1], sys.argv[2]
s = open(p).read()
if 'LAST_COMPACTED:' in s:
    s = re.sub(r'^LAST_COMPACTED:.*$', 'LAST_COMPACTED: '+ts, s, flags=re.M)
else:
    s = 'LAST_COMPACTED: '+ts+'\n' + s
open(p,'w').write(s)
" "$CUR" "$TS" 2>/dev/null || true
    chmod 600 "$CUR" 2>/dev/null || true
fi

(
    exec 9>"$GIT_LOCK"
    if flock -x -w 10 9 2>/dev/null; then
        "$HOME/.claude/state/bin/state-commit.sh" "$AGENT" "pre-compact $TS" 2>/dev/null || true
    fi
) &

exit 0
