#!/usr/bin/env bash
# SessionStart hook: emit prior session state so agent resumes in context.
# Emits a <restored-state> block with a CRISP RESUME line synthesized at the top,
# followed by a behavioral directive, then the full current.md.
# A fresh session IMMEDIATELY knows what to do -- no menu, no guessing.
# Exit 0 always -- silence is correct if no state exists.
set -uo pipefail

. "$HOME/.claude/hooks/_resolve-agent.sh"
if [ -z "$CONT_AGENT" ]; then
  echo "CONTINUITY DISABLED: agent name unresolved (CLAUDE_AGENT_NAME unset). This session is NOT restoring or saving durable state. Launch via claude-as <agent> or export CLAUDE_AGENT_NAME. Do NOT trust /handover here."
  exit 0
fi
AGENT="$CONT_AGENT"
HOST="$(hostname -s 2>/dev/null || echo unknown)"
STATE_DIR="$HOME/.claude/state/$AGENT"
CUR="$STATE_DIR/current.md"
LOG="$STATE_DIR/compact-save.log"

[ -f "$CUR" ] || exit 0

# CV2-C4: use git commit timestamp (not mtime) for freshness gate.
# After git clone/checkout mtime is "now" -- which would make a stale file look fresh.
# Fall back to mtime if the file has no git history (new/untracked).
NOW=$(date +%s)
_git_ct=$(git -C "$(dirname "$CUR")" log -1 --format="%ct" -- "$(basename "$CUR")" 2>/dev/null | grep -E '^[0-9]+$' | head -1 || echo "")
if [ -n "$_git_ct" ] && [ "$_git_ct" -gt 0 ]; then
  MTIME="$_git_ct"
else
  MTIME=$(stat -c %Y "$CUR" 2>/dev/null || python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$CUR" 2>/dev/null || echo 0)
fi
AGE=$(( NOW - MTIME ))
# Age check: skip if current.md older than 48h (dead agent, start fresh)
[ "$AGE" -gt 172800 ] && exit 0

# Freshness gate (Pelle V2 #5, CV2-C4): act-mode if <1h; verify-mode if 1-6h; warn if >6h
FRESHNESS_MODE="act"
if [ "$AGE" -gt 21600 ]; then
  FRESHNESS_MODE="stale"
elif [ "$AGE" -gt 3600 ]; then
  FRESHNESS_MODE="verify"
fi

# Build and emit the restored-state block via Python for clean extraction
python3 - "$CUR" "$AGENT" "$HOST" "$LOG" "$MTIME" "$FRESHNESS_MODE" <<'PY'
import sys, re, os, time, datetime
from pathlib import Path

cur, agent, host, log_path, mtime_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
freshness = sys.argv[6] if len(sys.argv) > 6 else 'act'
text = Path(cur).read_text()

# Timestamp
try:
    updated_ts = datetime.datetime.utcfromtimestamp(int(mtime_str)).strftime('%Y-%m-%dT%H:%M:%SZ')
except Exception:
    updated_ts = 'unknown'

# Extract explicit RESUME HERE line if present
m = re.search(r'^RESUME HERE:.*$', text, re.M)
resume_explicit = m.group(0) if m else None

# Synthesize from NEXT_ACTION and DONE sections
next_act = ''
m = re.search(r'(?:## NEXT_ACTION|NEXT_ACTION:)[^\n]*\n(.*?)(?:\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines:
        next_act = lines[0][:140]

last_done = ''
m = re.search(r'## DONE[^\n]*\n(.*?)(?:\n##|\Z)', text, re.DOTALL)
if m:
    lines = [l.strip() for l in m.group(1).strip().splitlines() if l.strip()]
    if lines:
        last_done = lines[0].lstrip('-').strip()[:120]

# Host/instance mismatch check (normalize to alphanumeric for comparison)
host_warning = ''
m = re.search(r'^INSTANCE:\s*(.+)$', text, re.M)
if m:
    inst = m.group(1).strip()
    host_norm = re.sub(r'[^a-z0-9]', '', host.lower())
    inst_norm = re.sub(r'[^a-z0-9]', '', inst.lower())
    if host_norm and host_norm not in inst_norm and 'unknown' not in host.lower():
        host_warning = f'  WARNING: state INSTANCE="{inst}" but current host="{host}". Confirm you loaded the right slot.\n'

# Build crisp RESUME line
if resume_explicit:
    resume_line = resume_explicit
else:
    parts = [f"you are {agent} on {host}"]
    if last_done:
        parts.append(f"LAST: {last_done}")
    if next_act:
        parts.append(f"NEXT: {next_act}")
    resume_line = "RESUME HERE: " + "; ".join(parts)

print("<restored-state>")
print(f"# Prior session state for agent: {agent}")
print(f"# State file last updated: {updated_ts}")
print()
print("## CRISP RESUME (act on this immediately -- no menu)")
print(resume_line)
if host_warning:
    print(host_warning.rstrip())
# Freshness gate (Pelle V2 #5)
if freshness == 'stale':
    print()
    print("## FRESHNESS WARNING: state is >6h old -- treat as hypothesis")
    print("  VERIFY-MODE: confirm the recorded task is still valid before acting.")
    print("  Do NOT auto-resume into sends, deploys, or destructive operations.")
elif freshness == 'verify':
    print()
    print("## FRESHNESS NOTE: state is 1-6h old -- light verify recommended")
    print("  Confirm NEXT_ACTION is still current before proceeding.")
print()
print("==================== RESUME DIRECTIVE ====================")
print(f'You are agent "{agent}" and you JUST RESTARTED. Your saved state is below.')
print("Do NOT present a menu. Do NOT ask what to continue. Do NOT guess from OPEN-WORK.")
print("IMMEDIATELY act on the NEXT_ACTION line above. If it needs a Bjorn decision, state it in ONE line and wait.")
print("==========================================================")
print()
print(text.rstrip())

# Append recent compact log
now = time.time()
if Path(log_path).exists() and os.path.getsize(log_path) > 0:
    try:
        log_age = now - os.path.getmtime(log_path)
        if log_age < 86400:
            lines = Path(log_path).read_text().splitlines()
            print()
            print("## Last compacted context summary (tail):")
            print('\n'.join(lines[-20:]))
    except Exception:
        pass

print("</restored-state>")
PY
exit 0
