#!/usr/bin/env bash
# PreCompact hook: save session summary before context compaction.
# Mandatory fixes applied: chmod 700/600, secret-strip, 300-line cap, flock.
# Exit 0 on ALL errors -- never block a Claude turn.
set -uo pipefail

. "$HOME/.claude/hooks/_resolve-agent.sh"
[ -z "$CONT_AGENT" ] && exit 0
AGENT="$CONT_AGENT"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE_DIR="$HOME/.claude/state/$AGENT"
GIT_LOCK="/tmp/claude-state-git.lock"

# Secure directory creation
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

LOG="$STATE_DIR/compact-save.log"

# Parse stdin JSON from Claude Code (format not guaranteed -- graceful fallback)
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

# Strip obvious secret patterns before writing
if [ -n "$SUMMARY" ]; then
    SUMMARY=$(echo "$SUMMARY" | python3 -c "
import sys, re
patterns = [
    r'sk-[A-Za-z0-9\-_]{20,}',
    r'eyJ[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+',
    r'[A-Za-z0-9]{32,}',  # generic long tokens - conservative
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

# Append to log with header
{
    echo "=== COMPACT $TS agent=$AGENT ==="
    [ -n "$SUMMARY" ] && echo "$SUMMARY" || echo "(no summary available)"
    echo ""
} >> "$LOG"

# Secure log permissions
chmod 600 "$LOG" 2>/dev/null || true

# Rotate: keep last 300 lines
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 350 ]; then
    tail -300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG" && chmod 600 "$LOG" 2>/dev/null || true
fi

# Update LAST_COMPACTED in current.md
CUR="$STATE_DIR/current.md"
if [ -f "$CUR" ]; then
    python3 -c "
import sys, re
p, ts = sys.argv[1], sys.argv[2]
s = open(p).read()
if 'LAST_COMPACTED:' in s:
    s = re.sub(r'^LAST_COMPACTED:.*\$', 'LAST_COMPACTED: '+ts, s, flags=re.M)
else:
    s = 'LAST_COMPACTED: '+ts+'\n' + s
open(p,'w').write(s)
" "$CUR" "$TS" 2>/dev/null || true
    chmod 600 "$CUR" 2>/dev/null || true
fi

# Hollow NEXT_ACTION guard: skip commit if NEXT_ACTION is hollow (Hugo's finding 2026-07-15)
SKIP_COMMIT=0
if [ -f "$CUR" ]; then
    next_val=$(python3 -c "
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r'(?:## NEXT_ACTION|NEXT_ACTION:)[^\n]*\n(.*?)(?=\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines: print(lines[0][:200])
" "$CUR" 2>/dev/null || echo "")
    is_hollow=$(echo "$next_val" | python3 -c "
import sys, re
val = sys.stdin.read().strip()
# CV2-H5: 'IDLE: <anything>' is intentional idle state -- never hollow even if short.
if re.match(r'^idle\s*:', val, re.I):
    print('0')
    raise SystemExit(0)
hollow = bool(re.match(r'^(await\b|idle\$|waiting|standby|turn.complet|n/?a\$|tbd\$|\(none\)|\(not.specified\)|\.?\$)', val, re.I))
print('1' if not val or len(val) < 20 or hollow else '0')
" 2>/dev/null || echo "0")
    if [ "$is_hollow" = "1" ]; then
        SKIP_COMMIT=1
        echo "pre-compact: WARNING -- NEXT_ACTION is hollow for $AGENT -- skipping commit" >> "$LOG"
    fi
fi

if [ "$SKIP_COMMIT" = "0" ]; then
    # Background commit with flock (non-blocking to the agent turn)
    (
        exec 9>"$GIT_LOCK"
        if flock -x -w 10 9 2>/dev/null; then
            "$HOME/.claude/state/bin/state-commit.sh" "$AGENT" "pre-compact $TS" 2>/dev/null || true
        fi
    ) &
fi

exit 0
