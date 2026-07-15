#!/usr/bin/env bash
# Stop hook: stamp UPDATED on every agent turn end. Lightweight, no git.
# Exit 0 on ALL errors -- never block.
. "$HOME/.claude/hooks/_resolve-agent.sh"
[ -z "$CONT_AGENT" ] && exit 0
AGENT="$CONT_AGENT"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CUR="$HOME/.claude/state/$AGENT/current.md"
[ -f "$CUR" ] || exit 0
python3 -c "
import sys, re
p, ts = sys.argv[1], sys.argv[2]
try:
    s = open(p).read()
    if 'UPDATED:' in s:
        s = re.sub(r'^UPDATED:.*\$', 'UPDATED: '+ts, s, count=1, flags=re.M)
    else:
        s = 'UPDATED: '+ts+'\n' + s
    open(p,'w').write(s)
except Exception:
    pass
" "$CUR" "$TS" 2>/dev/null || true
exit 0
