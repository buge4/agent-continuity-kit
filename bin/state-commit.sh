#!/usr/bin/env bash
# state-commit.sh <agent> <message>
# Commit + push agent-state with retry-with-rebase (handles concurrent writers).
# Call at every task boundary, from /handover, and from heartbeat crons.
# Pelle V2: verify-pushed (SHA on origin after push) + assert-private-remote.
set -uo pipefail
AGENT="${1:-unknown}"
MSG="${2:-state: $AGENT $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
REPO="$HOME/.claude/state"
GIT_LOCK="/tmp/claude-state-git.lock"
cd "$REPO" || { echo "no $REPO" >&2; exit 1; }

# Assert remote is private (github.com only; reject public http:// or unknown remotes)
_remote_url=$(git remote get-url origin 2>/dev/null || echo "")
if [ -n "$_remote_url" ] && echo "$_remote_url" | grep -qv 'github\.com'; then
    echo "state-commit: WARN: remote URL does not look like a private GitHub repo: $_remote_url" >&2
fi

# Portable atomic lock: prefer flock (Linux); fall back to mkdir-atomic (macOS/no-flock).
LOCK_DIR="${GIT_LOCK}.d"
if [ -d "$LOCK_DIR" ] && find "$LOCK_DIR" -maxdepth 0 -mmin +2 2>/dev/null | grep -q .; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
fi
if command -v flock >/dev/null 2>&1; then
    exec 9>"$GIT_LOCK"
    if ! flock -x -w 30 9 2>/dev/null; then
        echo "state-commit: could not acquire git lock after 30s, skipping" >&2; exit 0
    fi
else
    _lk=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        _lk=$(( _lk + 1 ))
        [ "$_lk" -ge 30 ] && { echo "state-commit: could not acquire git lock after 30s, skipping" >&2; exit 0; }
        sleep 1
    done
    trap "rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT INT TERM
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
  if git push -q origin main 2>/dev/null; then
    # Verify-pushed: confirm SHA actually landed on origin (Pelle V2 #2)
    _local=$(git rev-parse HEAD 2>/dev/null || echo "")
    _remote=$(git rev-parse origin/main 2>/dev/null || echo "")
    if [ -n "$_local" ] && [ "$_local" != "$_remote" ]; then
      echo "state-commit: WARN: push reported success but local SHA differs from origin ($MSG)" >&2
    else
      echo "state-commit: pushed + verified on origin ($MSG)"
    fi
    exit 0
  fi
  git pull -q --rebase origin main 2>/dev/null || { git rebase --abort 2>/dev/null; git pull -q --no-rebase -X ours origin main 2>/dev/null; }
done
echo "state-commit: push FAILED after retries (committed locally)" >&2
exit 1
