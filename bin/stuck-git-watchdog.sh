#!/usr/bin/env bash
# stuck-git-watchdog.sh
# Pelle V2 #3: detect + auto-abort a stuck git rebase/merge in the state repo.
# If .git/rebase-merge or MERGE_HEAD has existed for >10 min, abort and flag DEGRADED.
# Runs via cron every 5 min alongside state-snapshot (install-durable-memory wires it).
# Exit 0 always -- never block cron.
set -uo pipefail

REPO="$HOME/.claude/state"
LEDGER="$REPO/MASTER-LEDGER.md"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DEGRADED_FLAG="$REPO/.git-degraded"

[ -d "$REPO/.git" ] || exit 0
cd "$REPO" || exit 0

_stuck=0
_reason=""

# Check for stuck rebase
if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
    _dir=".git/rebase-merge"
    [ -d ".git/rebase-apply" ] && _dir=".git/rebase-apply"
    _age_min=$(( ( $(date +%s) - $(stat -c %Y "$_dir" 2>/dev/null || echo $(date +%s)) ) / 60 ))
    if [ "$_age_min" -gt 10 ]; then
        _stuck=1
        _reason="rebase stuck for ${_age_min}min"
    fi
fi

# Check for stuck merge
if [ -f ".git/MERGE_HEAD" ]; then
    _age_min=$(( ( $(date +%s) - $(stat -c %Y ".git/MERGE_HEAD" 2>/dev/null || echo $(date +%s)) ) / 60 ))
    if [ "$_age_min" -gt 10 ]; then
        _stuck=1
        _reason="${_reason:+${_reason}; }merge stuck for ${_age_min}min"
    fi
fi

if [ "$_stuck" -eq 1 ]; then
    echo "stuck-git-watchdog: DEGRADED detected at $TS -- $_reason -- auto-aborting" >&2
    git rebase --abort 2>/dev/null || true
    git merge --abort 2>/dev/null || true
    # Write DEGRADED flag (session-start will see it)
    echo "DEGRADED: $_reason ($TS)" > "$DEGRADED_FLAG"
    # Append to MASTER-LEDGER
    mkdir -p "$(dirname "$LEDGER")"
    printf '%s | stuck-git-watchdog | DEGRADED | %s\n' "$TS" "$_reason" >> "$LEDGER"
    echo "stuck-git-watchdog: aborted + flagged DEGRADED ($TS)"
else
    # Clear stale DEGRADED flag if git is now clean
    [ -f "$DEGRADED_FLAG" ] && rm -f "$DEGRADED_FLAG" && \
        printf '%s | stuck-git-watchdog | RECOVERED | git clean\n' "$TS" >> "$LEDGER"
fi
exit 0
