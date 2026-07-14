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

# PreCompact: save before compaction
pc = hooks.setdefault("PreCompact", [{}])
if not isinstance(pc, list):
    pc = [{}]
    hooks["PreCompact"] = pc
existing_pc = [h.get("command","") for block in pc for h in block.get("hooks", [])]
pc_script = os.path.join(hooks_dir, "pre-compact-save.sh")
if pc_script not in existing_pc:
    pc.append({"hooks": [{"type": "command", "command": pc_script, "timeout": 15}]})

# Stop: stamp UPDATED
stop = hooks.setdefault("Stop", [{}])
if not isinstance(stop, list):
    stop = [{}]
    hooks["Stop"] = stop
existing_stop = [h.get("command","") for block in stop for h in block.get("hooks", [])]
stop_script = os.path.join(hooks_dir, "post-stop-save.sh")
if stop_script not in existing_stop:
    stop.append({"hooks": [{"type": "command", "command": stop_script, "timeout": 5}]})

# SessionStart: restore prior state
ss = hooks.setdefault("SessionStart", [{}])
if not isinstance(ss, list):
    ss = [{}]
    hooks["SessionStart"] = ss
existing_ss = [h.get("command","") for block in ss for h in block.get("hooks", [])]
ss_script = os.path.join(hooks_dir, "session-start-restore.sh")
if ss_script not in existing_ss:
    ss.append({"hooks": [{"type": "command", "command": ss_script, "timeout": 10}]})

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print("    settings.json updated")
PY

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

# --- 6. Cron ---
echo "[6/6] Wiring cron snapshot (*/5)..."
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
