#!/usr/bin/env bash
# ~/.claude/bin/nightly-restart.sh <agent> [--dry-run]
# Per NIGHTLY-RESTART-AND-REFRESH-PLAN.md: state-commit -> backup -> systemctl restart -> verify.
# Deny-list: main-runner books-runner patent-heartbeat heartbeat-main heartbeat-books queue-runner claude2 arctico-*
# Lock: /tmp/nightly-restart-<agent>.lock (stale if >30 min old, removed at entry).
# Timeout: 15 min per slot. Logs every action to MASTER-LEDGER.
set -uo pipefail

# --- parse args ---
DRY=0
AGENT=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    *) AGENT="$arg" ;;
  esac
done

if [ -z "$AGENT" ]; then
  echo "Usage: nightly-restart.sh <agent> [--dry-run]" >&2
  exit 1
fi

# --- deny-list ---
for denied in main-runner books-runner patent-heartbeat heartbeat-main heartbeat-books queue-runner claude2; do
  if [ "$AGENT" = "$denied" ]; then
    echo "nightly-restart: DENIED -- $AGENT is on deny-list" >&2
    exit 1
  fi
done
case "$AGENT" in arctico-*)
  echo "nightly-restart: DENIED -- $AGENT matches arctico-* deny-list" >&2
  exit 1
  ;;
esac

# --- agent -> systemd unit mapping ---
case "$AGENT" in
  assistant|veriton) UNIT="claude-assistant@veriton" ;;
  books)             UNIT="claude-assistant@books" ;;
  claudeweb)         UNIT="claude-assistant@claudeweb" ;;
  entropy)           UNIT="" ;;
  *)
    echo "nightly-restart: unknown agent '$AGENT' -- valid: assistant books claudeweb entropy" >&2
    exit 1
    ;;
esac

STATE="$HOME/.claude/state"
CUR="$STATE/$AGENT/current.md"
HIST="$STATE/$AGENT/history.md"
LEDGER="$STATE/MASTER-LEDGER.md"
LOCK="/tmp/nightly-restart-${AGENT}.lock"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TIMEOUT=900  # 15 min per slot

# --- stale lock cleanup (>30 min old) ---
if [ -f "$LOCK" ]; then
  lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt 1800 ]; then
    rm -f "$LOCK"
    echo "nightly-restart: removed stale lock for $AGENT (${lock_age}s old)"
  else
    echo "nightly-restart: lock exists for $AGENT (${lock_age}s old) -- skip (slot may still be running)"
    exit 0
  fi
fi

# --- acquire lock ---
touch "$LOCK"
trap 'rm -f '"$LOCK"'' EXIT INT TERM

# --- MASTER-LEDGER append helper ---
ledger_append() {
  local action="$1" sha="$2" outcome="$3" notes="${4:-}"
  local lines=0
  [ -f "$CUR" ] && lines=$(wc -l < "$CUR" 2>/dev/null || echo 0)
  printf '%s | %s | %s | %s | %s | lines=%d %s\n' \
    "$TS" "$AGENT" "$action" "$sha" "$outcome" "$lines" "$notes" >> "$LEDGER"
  local total
  total=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
  if [ "$total" -gt 500 ]; then
    tail -500 "$LEDGER" > "${LEDGER}.tmp" && mv "${LEDGER}.tmp" "$LEDGER"
  fi
}

SHA=$(git -C "$STATE" rev-parse HEAD 2>/dev/null || echo "none")

# --- dry-run: static checks only, no restart ---
if [ "$DRY" -eq 1 ]; then
  echo "DRY-RUN nightly-restart $AGENT"
  if [ ! -f "$CUR" ]; then
    echo "DRY-RUN FAIL: $CUR does not exist"
    ledger_append "dry-run" "$SHA" "FAIL" "no current.md"
    exit 1
  fi
  lines=$(wc -l < "$CUR")
  if [ "$lines" -lt 5 ]; then
    echo "DRY-RUN FAIL: current.md too short ($lines lines, need >=5)"
    ledger_append "dry-run" "$SHA" "FAIL" "current.md short lines=$lines"
    exit 1
  fi
  if ! grep -q 'NEXT_ACTION' "$CUR"; then
    echo "DRY-RUN FAIL: NEXT_ACTION not found in current.md"
    ledger_append "dry-run" "$SHA" "FAIL" "no NEXT_ACTION"
    exit 1
  fi
  resume_count=$(grep -c 'RESUME HERE' "$CUR" 2>/dev/null || echo 0)
  next_val=$(python3 -c "
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r'(?:## NEXT_ACTION|NEXT_ACTION:)[^\n]*\n(.*?)(?=\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines: print(lines[0][:200])
" "$CUR" 2>/dev/null || echo "")
  hollow_flag=""
  if [ -z "$next_val" ] || echo "$next_val" | python3 -c "
import sys, re
val = sys.stdin.read().strip()
import sys as _s; _s.exit(0 if re.match(r'^(await\b|idle$|waiting|standby|turn.complet|n/?a$|tbd$)', val, re.I) or len(val) < 20 else 1)
" 2>/dev/null; then
    hollow_flag=" WARN:hollow-next-action"
    echo "DRY-RUN WARN: NEXT_ACTION is hollow ('$next_val') -- haiku-refresh needed"
    ledger_append "dry-run" "$SHA" "WARN" "hollow-next-action"
  fi
  echo "DRY-RUN PASS: $AGENT current.md OK (lines=$lines NEXT_ACTION=yes RESUME-HERE=$resume_count${hollow_flag})"
  ledger_append "dry-run" "$SHA" "PASS" "lines=$lines resume_here=$resume_count${hollow_flag}"
  exit 0
fi

# --- step 1: state-commit ---
echo "nightly-restart: step1 state-commit $AGENT ($TS)"
"$STATE/bin/state-commit.sh" "$AGENT" "nightly-restart: pre-clear $AGENT $TS" 2>/dev/null || true
SHA=$(git -C "$STATE" rev-parse HEAD 2>/dev/null || echo "none")
ledger_append "state-commit" "$SHA" "PASS"

# --- step 2: backup current.md -> history.md (rollback target) ---
if [ -f "$CUR" ]; then
  cp "$CUR" "$HIST"
  echo "nightly-restart: backed up $CUR -> $HIST"
fi

# --- entropy is tmux-only: hold until systemd path added ---
if [ -z "$UNIT" ]; then
  echo "nightly-restart: $AGENT is tmux-only -- HOLD (manual restart needed)"
  ledger_append "restart-skip" "$SHA" "HOLD" "tmux-only agent"
  exit 0
fi

# --- overlap guard: skip if previous slot lock still exists ---
for slot in assistant books claudeweb; do
  [ "$slot" = "$AGENT" ] && continue
  slot_lock="/tmp/nightly-restart-${slot}.lock"
  if [ -f "$slot_lock" ]; then
    slot_age=$(( $(date +%s) - $(stat -c %Y "$slot_lock" 2>/dev/null || echo 0) ))
    if [ "$slot_age" -lt 1800 ]; then
      echo "nightly-restart: overlap guard -- $slot still running (lock ${slot_age}s old), skipping $AGENT"
      ledger_append "skip-overlap" "$SHA" "SKIP" "slot $slot lock age=${slot_age}s"
      exit 0
    fi
  fi
done

# --- step 3: systemctl restart ---
echo "nightly-restart: restarting ${UNIT}.service"
systemctl restart "${UNIT}.service"
ledger_append "restart" "$SHA" "PASS" "systemctl restart ${UNIT}"

# --- step 4: verify service active (poll, timeout 15 min) ---
echo "nightly-restart: polling for ${UNIT} to become active"
start=$(date +%s)
while true; do
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -gt "$TIMEOUT" ]; then
    echo "nightly-restart: TIMEOUT -- $AGENT service not active after ${TIMEOUT}s"
    ledger_append "verify" "$SHA" "FAIL" "timeout elapsed=${elapsed}s"
    # CV2-H1: alert so the board surfaces a failed restart.
    NOTICE_BIN="$HOME/.claude/bin/notice"
    [ -x "$NOTICE_BIN" ] && "$NOTICE_BIN" post --agent claude2 --type alert \
        --title "nightly-restart: TIMEOUT ($AGENT)" \
        --body "Service $UNIT did not become active after ${TIMEOUT}s. Manual check needed." 2>/dev/null || true
    exit 1
  fi
  if systemctl is-active --quiet "${UNIT}.service" 2>/dev/null; then
    echo "nightly-restart: $AGENT ACTIVE (elapsed ${elapsed}s)"
    ledger_append "verify" "$SHA" "PASS" "service active elapsed=${elapsed}s"
    exit 0
  fi
  sleep 10
done
