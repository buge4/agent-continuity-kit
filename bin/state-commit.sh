#!/usr/bin/env bash
# state-commit.sh <agent> <message>
# Commit + push agent-state with retry-with-rebase (handles concurrent writers).
# Call at every task boundary, from /handover, and from heartbeat crons.
set -uo pipefail
AGENT="${1:-unknown}"
MSG="${2:-state: $AGENT $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
REPO="$HOME/.claude/state"
GIT_LOCK="/tmp/claude-state-git.lock"
cd "$REPO" || { echo "no $REPO" >&2; exit 1; }

exec 9>"$GIT_LOCK"
if ! flock -x -w 30 9 2>/dev/null; then
  echo "state-commit: could not acquire git lock after 30s, skipping" >&2
  exit 0
fi

CUR="$REPO/$AGENT/current.md"
if [ -f "$CUR" ]; then
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 - "$CUR" "$ts" <<'PY' 2>/dev/null || true
import sys,re
p,ts=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'^UPDATED:.*$', 'UPDATED: '+ts, s, count=1, flags=re.M)
open(p,'w').write(s)
PY
fi

git add -A
git diff --cached --quiet && { echo "state-commit: nothing to commit"; exit 0; }
git commit -q -m "$MSG"
for i in 1 2 3 4 5; do
  if git push -q origin main 2>/dev/null; then echo "state-commit: pushed ($MSG)"; exit 0; fi
  git pull -q --rebase origin main 2>/dev/null || { git rebase --abort 2>/dev/null; git pull -q --no-rebase -X ours origin main 2>/dev/null; }
done
echo "state-commit: push FAILED after retries (committed locally)" >&2
exit 1
