#!/usr/bin/env bash
# seats-sync.sh — pull the shared encrypted seat store (buge4/veriton-seats) and
# rewrite THIS box's OAuth seats into the local auth env. Runs on every box (cron).
# 2026-07-16 claude2. v2: sudo-OPTIONAL + owner-PRESERVING (root-owned OR user-owned
# envs; never forces root ownership). GitHub-mediated. Never prints a token.
set -uo pipefail
PASS="${VERITON_SEATS_PASS:-$HOME/.config/veriton/seats-pass}"
REPO="${VERITON_SEATS_REPO:-$HOME/.config/veriton/veriton-seats}"
ENV="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
LOG="${VERITON_SEATS_LOG:-/tmp/seats-sync.log}"
ts="$(date -u +%FT%TZ)"

_S=""
_pick_sudo(){ local f="$1"
  if [ -e "$f" ]; then { [ -r "$f" ] && [ -w "$f" ]; } && { _S=""; return 0; }
  else [ -w "$(dirname "$f")" ] && { _S=""; return 0; }; fi
  sudo -n true 2>/dev/null && { _S="sudo"; return 0; }; return 1; }
env_read(){ cat "$ENV" 2>/dev/null || sudo -n cat "$ENV" 2>/dev/null; }
env_write(){ local tmp="$1" owner mode
  _pick_sudo "$ENV" || { echo "$ts ABORT no access to $ENV (no perm+no sudo)" >>"$LOG"; return 1; }
  if [ -e "$ENV" ]; then owner="$($_S stat -c %U:%G "$ENV" 2>/dev/null)"; mode="$($_S stat -c %a "$ENV" 2>/dev/null)"; else owner=""; mode=600; fi
  $_S cp "$tmp" "$ENV" && $_S chmod "${mode:-600}" "$ENV"
  [ -n "$owner" ] && $_S chown "$owner" "$ENV" 2>/dev/null || true; }

[ -f "$PASS" ] || { echo "$ts SKIP no passphrase at $PASS" >>"$LOG"; exit 0; }
if [ ! -d "$REPO/.git" ]; then gh repo clone buge4/veriton-seats "$REPO" >/dev/null 2>&1 || { echo "$ts FAIL clone" >>"$LOG"; exit 1; }; fi
git -C "$REPO" fetch -q origin 2>/dev/null && git -C "$REPO" reset -q --hard origin/HEAD 2>/dev/null || echo "$ts WARN fetch failed, using cached" >>"$LOG"
STORE="$REPO/seats.env.gpg"; [ -f "$STORE" ] || { echo "$ts SKIP no store file" >>"$LOG"; exit 0; }
dec="$(gpg --batch --quiet --passphrase-file "$PASS" -d "$STORE" 2>/dev/null | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN")"
[ -z "$dec" ] && { echo "$ts ABORT decrypt empty/failed — kept current env" >>"$LOG"; exit 1; }

cur_oauth="$(env_read | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN" | sort)"
new_oauth="$(printf '%s\n' "$dec" | sort)"
if [ "$cur_oauth" = "$new_oauth" ]; then echo "$ts noop (already $(printf '%s\n' "$dec" | grep -c .) seats)" >>"$LOG"; exit 0; fi
tmp="$(mktemp)"
env_read | grep -vE "^export CLAUDE_CODE_OAUTH_TOKEN" > "$tmp"   # keep API key + flags + comments
printf '%s\n' "$dec" >> "$tmp"
if env_write "$tmp"; then echo "$ts UPDATED env: $(printf '%s\n' "$dec" | grep -c .) seats from store" >>"$LOG"; fi
shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
