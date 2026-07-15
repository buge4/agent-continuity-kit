#!/usr/bin/env bash
# ~/.claude/bin/haiku-refresh.sh <agent>
# Layer C: regenerate current.md via Haiku OAuth every 12 min.
# Guards: blackout (within 10 min of nightly-restart slots), SHA skip-if-no-change,
#         flock on current.md.lock, OAuth-failure -> exit 1 no write, .dirty flag support.
# Slots (UTC): 17:20 17:40 18:00 18:20 -> blackout 17:10-18:30.
set -uo pipefail

AGENT="${1:-}"
if [ -z "$AGENT" ]; then
  echo "Usage: haiku-refresh.sh <agent>" >&2
  exit 1
fi

STATE="$HOME/.claude/state"
CUR="$STATE/$AGENT/current.md"
LOCK_FILE="$STATE/$AGENT/current.md.lock"
DIRTY_FLAG="$STATE/$AGENT/.dirty"
LEDGER="$STATE/MASTER-LEDGER.md"
AUTH_EXEC="/opt/veriton-fleet/bin/claude-auth-exec.sh"
CLAUDE_BIN="/home/veriton/.npm-global/bin/claude"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ ! -f "$CUR" ]; then
  echo "haiku-refresh: no current.md for $AGENT, skipping"
  exit 0
fi

# --- blackout window: within 10 min of any nightly-restart slot ---
# Slots (UTC minutes from midnight): 17:20=1040, 17:40=1060, 18:00=1080, 18:20=1100
now_h=$(date -u +%H); now_m=$(date -u +%M)
now_min=$(( 10#$now_h * 60 + 10#$now_m ))
for slot_min in 1040 1060 1080 1100; do
  diff=$(( now_min - slot_min ))
  [ "$diff" -lt 0 ] && diff=$(( -diff ))
  if [ "$diff" -le 10 ]; then
    echo "haiku-refresh: blackout window for $AGENT (within 10 min of slot at ${slot_min}min)"
    exit 0
  fi
done

# --- acquire flock on current.md.lock (10s timeout) ---
touch "$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -x -w 10 9 2>/dev/null; then
    echo "haiku-refresh: could not acquire lock for $AGENT in 10s -- skipping"
    exit 0
  fi
fi

old_sha=$(sha256sum "$CUR" 2>/dev/null | awk '{print $1}' || echo "")
old_content=$(cat "$CUR")

# --- recent MASTER-LEDGER lines for context ---
ledger_ctx=""
[ -f "$LEDGER" ] && ledger_ctx=$(tail -10 "$LEDGER" 2>/dev/null || echo "")

# --- build prompt ---
PROMPT=$(cat <<ENDPROMPT
You are a state-management assistant. You receive the current state summary for an AI agent named "$AGENT" running on veriton-prod.

Task: produce a refreshed, concise version of the state summary in the SAME format as the input.
- CRITICAL: NEVER invent, add, reword, or borrow NEXT_ACTION / blockers / done items. Reproduce them VERBATIM from the input. If there is no genuinely new information, output the input UNCHANGED. Do NOT pull tasks from other agents or generic templates (no 'overnight job', no borrowed project names). A fresh/seeded state must survive untouched.
- Preserve ALL key facts: AGENT line, UPDATED line, INSTANCE, RESUME HERE directive, NEXT_ACTION, blockers, done items, LAST_VERIFIED_STATE.
- Update the UPDATED line to: $TS
- Condense repeated entries without losing facts.
- Keep output under 150 lines.
- Do NOT use em-dashes (--) or hyphens as em-dashes.
- Output ONLY the refreshed state content -- no explanation, no wrapper, no preamble.
- NEXT_ACTION RULE (critical): the NEXT_ACTION section MUST contain a specific action, file path, artifact, or command. Values like "Await Bjorn", "idle", "turn completed", "waiting", "(not specified)", "(none)" are FORBIDDEN. If the agent is genuinely waiting, write WHAT SPECIFICALLY to check or do on wake (e.g., "Check notice board + queue-runner; await Bjorn decision on X"). Copy the previous NEXT_ACTION verbatim if no better value exists.

Current state:
$old_content

Recent MASTER-LEDGER context:
$ledger_ctx
ENDPROMPT
)

# --- run Haiku via auth-exec ---
RUNNER="$CLAUDE_BIN"
[ -x "$AUTH_EXEC" ] && RUNNER="$AUTH_EXEC"

new_content=$(timeout 90 "$RUNNER" \
  --model claude-haiku-4-5-20251001 \
  --dangerously-skip-permissions \
  -p "$PROMPT" \
  --output-format text 2>/dev/null || echo "")

# --- OAuth failure guard ---
if [ -z "$new_content" ]; then
  echo "haiku-refresh: OAuth returned empty for $AGENT -- NOT writing"
  printf '%s | %s | haiku-refresh | none | FAIL | oauth-empty\n' "$TS" "$AGENT" >> "$LEDGER"
  exit 1
fi

# Sanity: output must contain NEXT_ACTION (not a runaway completion)
if ! echo "$new_content" | grep -q 'NEXT_ACTION'; then
  echo "haiku-refresh: output missing NEXT_ACTION for $AGENT -- NOT writing (safety guard)"
  printf '%s | %s | haiku-refresh | none | FAIL | missing-NEXT_ACTION\n' "$TS" "$AGENT" >> "$LEDGER"
  exit 1
fi

# --- hollow NEXT_ACTION guard (Hugo's finding 2026-07-15) ---
# Detects hollow values ("Await Bjorn", "turn completed", etc.) and preserves the last
# known non-hollow value. Staleness ceiling: refuse after 3 consecutive hollow refreshes.
# CV2-C2: use STATE/$AGENT (STATE_DIR was undefined in this scope).
HOLLOW_CTR_FILE="$STATE/$AGENT/.hollow-count"
new_next_val=$(echo "$new_content" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'(?:## NEXT_ACTION|NEXT_ACTION:)[^\n]*\n(.*?)(?=\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines: print(lines[0][:200])
" 2>/dev/null || echo "")

is_hollow=$(echo "$new_next_val" | python3 -c "
import sys, re
val = sys.stdin.read().strip()
# CV2-H5: 'IDLE: <anything>' with a colon is intentional -- never hollow even if short.
if re.match(r'^idle\s*:', val, re.I):
    print('0')
    raise SystemExit(0)
hollow = bool(re.match(r'^(await\b|idle\$|waiting|standby|turn.complet|n/?a\$|tbd\$|\(none\)|\(not.specified\)|\.?\$)', val, re.I))
print('1' if not val or len(val) < 20 or hollow else '0')
" 2>/dev/null || echo "0")

if [ "$is_hollow" = "1" ]; then
  hollow_count=0
  [ -f "$HOLLOW_CTR_FILE" ] && hollow_count=$(cat "$HOLLOW_CTR_FILE" 2>/dev/null || echo 0)
  hollow_count=$(( hollow_count + 1 ))

  if [ "$hollow_count" -ge 3 ]; then
    echo "haiku-refresh: hollow NEXT_ACTION x${hollow_count} for $AGENT -- refusing (staleness ceiling)"
    printf '%s | %s | haiku-refresh | none | FAIL | hollow-ceiling-x%d\n' "$TS" "$AGENT" "$hollow_count" >> "$LEDGER"
    # CV2-C5: alert on ceiling trip so Bjorn can see it; manual reset: echo 0 > $STATE/$AGENT/.hollow-count
    NOTICE_BIN="$HOME/.claude/bin/notice"
    [ -x "$NOTICE_BIN" ] && "$NOTICE_BIN" post --agent claude2 --type alert \
        --title "haiku-refresh: hollow ceiling hit ($AGENT)" \
        --body "NEXT_ACTION has been hollow for ${hollow_count} consecutive refreshes. State frozen. Manual reset: echo 0 > $STATE/$AGENT/.hollow-count" 2>/dev/null || true
    exit 1
  fi

  old_next_body=$(echo "$old_content" | python3 -c "
import sys, re
text = sys.stdin.read()
m = re.search(r'(?:## NEXT_ACTION|NEXT_ACTION:)[^\n]*\n(.*?)(?=\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines: print(lines[0][:200])
" 2>/dev/null || echo "")

  old_is_hollow=$(echo "$old_next_body" | python3 -c "
import sys, re
val = sys.stdin.read().strip()
if re.match(r'^idle\s*:', val, re.I):
    print('0')
    raise SystemExit(0)
hollow = bool(re.match(r'^(await\b|idle\$|waiting|standby|turn.complet|n/?a\$|tbd\$|\(none\)|\(not.specified\)|\.?\$)', val, re.I))
print('1' if not val or len(val) < 20 or hollow else '0')
" 2>/dev/null || echo "1")

  if [ "$old_is_hollow" = "0" ] && [ -n "$old_next_body" ]; then
    new_content=$(echo "$new_content" | python3 -c "
import sys, re
old_body = sys.argv[1]
text = sys.stdin.read()
text = re.sub(
    r'(## NEXT_ACTION[^\n]*\n)(.*?)(?=\n##|\Z)',
    lambda m: m.group(1) + old_body + '\n',
    text, count=1, flags=re.DOTALL
)
sys.stdout.write(text)
" "$old_next_body" 2>/dev/null || echo "$new_content")
    echo "$hollow_count" > "$HOLLOW_CTR_FILE"
    echo "haiku-refresh: hollow NEXT_ACTION for $AGENT (count=$hollow_count) -- preserved old value"
    printf '%s | %s | haiku-refresh | none | WARN | hollow-preserved-x%d\n' "$TS" "$AGENT" "$hollow_count" >> "$LEDGER"
  else
    echo "haiku-refresh: hollow NEXT_ACTION + no non-hollow fallback for $AGENT -- NOT writing"
    printf '%s | %s | haiku-refresh | none | FAIL | hollow-no-fallback\n' "$TS" "$AGENT" >> "$LEDGER"
    exit 1
  fi
else
  rm -f "$HOLLOW_CTR_FILE"
fi

# --- SHA comparison: skip if identical ---
new_sha=$(echo "$new_content" | sha256sum 2>/dev/null | awk '{print $1}' || echo "")
if [ "$new_sha" = "$old_sha" ]; then
  echo "haiku-refresh: SHA unchanged for $AGENT -- no write needed"
  rm -f "$DIRTY_FLAG"
  exit 0
fi

# --- write refreshed current.md ---
echo "$new_content" > "$CUR"
rm -f "$DIRTY_FLAG"
echo "haiku-refresh: refreshed $AGENT current.md (sha $old_sha -> $new_sha)"
printf '%s | %s | haiku-refresh | none | PASS | sha-changed\n' "$TS" "$AGENT" >> "$LEDGER"

# --- commit refreshed state ---
"$STATE/bin/state-commit.sh" "$AGENT" "haiku-refresh: $AGENT $TS" 2>/dev/null || true
exit 0
