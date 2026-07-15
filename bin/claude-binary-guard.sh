#!/usr/bin/env bash
# claude-binary-guard.sh — 2026-07-16 claude2.
# The whole fleet went dark once because a claude-code UPDATE ran without its
# postinstall, leaving "claude native binary not installed". This guard detects
# that state and re-runs the postinstall automatically. Cheap, idempotent, safe.
set -uo pipefail
PKG=/home/veriton/.npm-global/lib/node_modules/@anthropic-ai/claude-code
LOG=/tmp/claude-binary-guard.log
ts="$(date -u +%FT%TZ)"
if bash -lc 'claude --version' >/dev/null 2>&1; then exit 0; fi   # healthy — silent
echo "$ts native binary missing — running postinstall" >> "$LOG"
( cd "$PKG" && node install.cjs ) >> "$LOG" 2>&1 || true
if bash -lc 'claude --version' >/dev/null 2>&1; then
  echo "$ts RECOVERED via postinstall" >> "$LOG"
else
  echo "$ts STILL BROKEN — needs: npm install -g @anthropic-ai/claude-code" >> "$LOG"
fi
