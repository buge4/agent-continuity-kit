#!/usr/bin/env bash
# seats-sync.sh — pull the shared encrypted seat store (buge4/veriton-seats) and
# rewrite THIS box's OAuth seats into the local auth env. Runs on every box (cron).
# 2026-07-16 claude2. GitHub-mediated (works across separate Hetzner boxes).
# Preserves all non-OAuth lines (ANTHROPIC_API_KEY_*, flags). Never prints a token.
set -uo pipefail
PASS="${VERITON_SEATS_PASS:-$HOME/.config/veriton/seats-pass}"
REPO="${VERITON_SEATS_REPO:-$HOME/.config/veriton/veriton-seats}"
ENV="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
LOG="${VERITON_SEATS_LOG:-/tmp/seats-sync.log}"
ts="$(date -u +%FT%TZ)"
[ -f "$PASS" ] || { echo "$ts SKIP no passphrase at $PASS" >>"$LOG"; exit 0; }
if [ ! -d "$REPO/.git" ]; then gh repo clone buge4/veriton-seats "$REPO" >/dev/null 2>&1 || { echo "$ts FAIL clone" >>"$LOG"; exit 1; }; fi
git -C "$REPO" fetch -q origin 2>/dev/null && git -C "$REPO" reset -q --hard origin/HEAD 2>/dev/null || { echo "$ts WARN fetch failed, using cached" >>"$LOG"; }
STORE="$REPO/seats.env.gpg"; [ -f "$STORE" ] || { echo "$ts SKIP no store file" >>"$LOG"; exit 0; }
dec="$(gpg --batch --quiet --passphrase-file "$PASS" -d "$STORE" 2>/dev/null | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN")"
[ -z "$dec" ] && { echo "$ts ABORT decrypt empty/failed — kept current env" >>"$LOG"; exit 1; }
tmp="$(mktemp)"
{ sudo cat "$ENV" 2>/dev/null || cat "$ENV"; } | grep -vE "^export CLAUDE_CODE_OAUTH_TOKEN" > "$tmp"   # keep API key + flags + comments
printf '%s\n' "$dec" >> "$tmp"
# only write if the OAuth block actually changed (avoid needless churn)
cur_oauth="$( { sudo cat "$ENV" 2>/dev/null || cat "$ENV"; } | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN" | sort)"
new_oauth="$(printf '%s\n' "$dec" | sort)"
if [ "$cur_oauth" != "$new_oauth" ]; then
  sudo cp "$tmp" "$ENV"; sudo chmod 640 "$ENV"; sudo chown root:veriton "$ENV"
  echo "$ts UPDATED env: $(printf '%s\n' "$dec" | grep -c .) seats from store" >>"$LOG"
else
  echo "$ts noop (already $(printf '%s\n' "$dec" | grep -c .) seats)" >>"$LOG"
fi
shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
