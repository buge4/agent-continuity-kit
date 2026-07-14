#!/usr/bin/env bash
# install-durable-memory.sh
# Portable installer for the Claude Code durable memory / continuity system.
# Gives every Claude Code agent (cron-runner or interactive) persistent state
# that survives /clear, context compaction, cron restarts, and box reboots.
#
# Requires: bash, python3, git, crontab
# Safe to re-run: idempotent everywhere.
#
# Usage:
#   AGENT_NAME=myagent STATE_REPO_URL=git@github.com:you/agent-state.git bash install-durable-memory.sh
#
# Or for interactive-only use (no cron runner, no git remote):
#   AGENT_NAME=myagent bash install-durable-memory.sh

set -euo pipefail

AGENT_NAME="${AGENT_NAME:-myagent}"
STATE_REPO_URL="${STATE_REPO_URL:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOOKS_DIR="$HOME/.claude/hooks"
BIN_DIR="$HOME/.claude/bin"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.claude/state"

echo "=== agent-continuity-kit installer ==="
echo "Agent name : $AGENT_NAME"
echo "State dir  : $STATE_DIR"
echo ""

# --- 1. Copy hooks ---
echo "[1/6] Installing hooks..."
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/pre-compact-save.sh"     "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/post-stop-save.sh"       "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/session-start-restore.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/pre-compact-save.sh" "$HOOKS_DIR/post-stop-save.sh" "$HOOKS_DIR/session-start-restore.sh"
echo "    hooks installed: pre-compact-save, post-stop-save, session-start-restore"

# --- 2. Copy bin scripts ---
echo "[2/6] Installing bin scripts..."
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/bin/state-snapshot.sh" "$BIN_DIR/"
cp "$SCRIPT_DIR/bin/state-commit.sh"   "$BIN_DIR/state-commit.sh"
chmod +x "$BIN_DIR/state-snapshot.sh" "$BIN_DIR/state-commit.sh"
mkdir -p "$STATE_DIR/bin"
ln -sf "$BIN_DIR/state-commit.sh" "$STATE_DIR/bin/state-commit.sh" 2>/dev/null || cp "$BIN_DIR/state-commit.sh" "$STATE_DIR/bin/state-commit.sh"
chmod +x "$STATE_DIR/bin/state-commit.sh"
echo "    state-snapshot.sh + state-commit.sh installed"

# --- 3. Wire settings.json ---
echo "[3/6] Registering hooks in settings.json..."
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOKS_DIR" <<'PY'
import json, sys, os

settings_path, hooks_dir = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    s = json.load(f)

hooks = s.setdefault("hooks", {})

def add_hook(hooks, event, script, extra=None):
    """Add script to event's hook list, idempotent. extra = extra fields on the hook cmd dict."""
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        entries = []
    # Purge any legacy bare {} entries left by old installer versions
    entries = [e for e in entries if isinstance(e, dict) and "hooks" in e]
    existing_cmds = [h.get("command", "") for e in entries for h in e.get("hooks", [])]
    if script not in existing_cmds:
        cmd = {"type": "command", "command": script}
        if extra:
            cmd.update(extra)
        entries.append({"matcher": "", "hooks": [cmd]})
    hooks[event] = entries

add_hook(hooks, "PreCompact",    os.path.join(hooks_dir, "pre-compact-save.sh"),    {"timeout": 15})
add_hook(hooks, "Stop",          os.path.join(hooks_dir, "post-stop-save.sh"),       {"timeout": 5})
add_hook(hooks, "SessionStart",  os.path.join(hooks_dir, "session-start-restore.sh"), {"timeout": 10})

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print("    settings.json updated")
PY

# --- 3b. Post-install validation ---
python3 - "$SETTINGS" <<'PYVAL'
import json, sys
settings_path = sys.argv[1]
with open(settings_path) as f:
    s = json.load(f)
hooks = s.get("hooks", {})
errors = []
for event, entries in hooks.items():
    if not isinstance(entries, list):
        errors.append(f"{event}: expected list, got {type(entries).__name__}")
        continue
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"{event}[{i}]: expected dict, got {type(entry).__name__}")
            continue
        if "hooks" not in entry:
            errors.append(f"{event}[{i}]: missing 'hooks' key (keys={list(entry.keys())})")
        elif not isinstance(entry["hooks"], list):
            errors.append(f"{event}[{i}].hooks: expected array, got {type(entry['hooks']).__name__}")
if errors:
    print("ERROR: settings.json hook schema INVALID:")
    for e in errors:
        print(f"  {e}")
    sys.exit(1)
else:
    print("    post-install validation PASSED: all hook entries well-formed")
PYVAL

# --- 4. Init state directory + agent current.md ---
echo "[4/6] Initialising state directory..."
mkdir -p "$STATE_DIR/$AGENT_NAME"
chmod 700 "$STATE_DIR/$AGENT_NAME" 2>/dev/null || true
CUR="$STATE_DIR/$AGENT_NAME/current.md"
if [ ! -f "$CUR" ]; then
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$CUR" <<EOF
LAST_COMPACTED: never
UPDATED: $TS
# $AGENT_NAME -- session-continuity STATE

## NEXT_ACTION
(fill in after first real session)

## BLOCKERS
None yet.

## DONE (recent)
Agent continuity installed $TS.
EOF
    chmod 600 "$CUR"
    echo "    created $CUR"
else
    echo "    $CUR already exists, skipping"
fi

# --- 5. Git init or clone ---
echo "[5/6] Setting up git state repo..."
cd "$STATE_DIR"
if [ ! -d ".git" ]; then
    git init -q
    git -c user.email="state@local" -c user.name="StateSystem" add -A
    git -c user.email="state@local" -c user.name="StateSystem" commit -qm "init: agent-continuity-kit"
    if [ -n "$STATE_REPO_URL" ]; then
        git remote add origin "$STATE_REPO_URL"
        git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || echo "    warning: push failed (check remote + SSH key)"
        echo "    git repo pushed to $STATE_REPO_URL"
    else
        echo "    git repo initialised locally (no remote -- set STATE_REPO_URL to add one)"
    fi
else
    if [ -n "$STATE_REPO_URL" ]; then
        git remote get-url origin &>/dev/null || git remote add origin "$STATE_REPO_URL"
    fi
    echo "    git repo already exists, skipping init"
fi

# --- 6. /handover slash command ---
echo "[6/7] Installing /handover slash command..."
COMMANDS_DIR="$HOME/.claude/commands"
mkdir -p "$COMMANDS_DIR"
if [ -f "$SCRIPT_DIR/commands/handover.md" ]; then
    cp "$SCRIPT_DIR/commands/handover.md" "$COMMANDS_DIR/handover.md"
    echo "    /handover command installed: $COMMANDS_DIR/handover.md"
else
    echo "    warning: commands/handover.md not found in kit, skipping"
fi

# --- 7. Cron ---
echo "[7/7] Wiring cron snapshot (*/5)..."
CRON_LINE="*/5 * * * * $BIN_DIR/state-snapshot.sh >> /tmp/state-snapshot.log 2>&1 # agent-continuity-snapshot"
if crontab -l 2>/dev/null | grep -q "agent-continuity-snapshot"; then
    echo "    cron already wired, skipping"
else
    ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
    echo "    cron added: $CRON_LINE"
fi

echo ""
echo "=== DONE ==="
echo ""
echo "Next step: make sure CLAUDE_AGENT_NAME=$AGENT_NAME is exported in your runner script"
echo "before the 'claude ...' invocation, e.g.:"
echo ""
echo "  export CLAUDE_AGENT_NAME=$AGENT_NAME"
echo "  claude -p 'your prompt' --dangerously-skip-permissions"
echo ""
echo "State file: $CUR"
echo "Snapshot  : every 5 min -> $STATE_DIR/MASTER-LEDGER.md"
echo "Hooks     : PreCompact / Stop / SessionStart registered in $SETTINGS"
echo "Command   : /handover installed at $COMMANDS_DIR/handover.md"
