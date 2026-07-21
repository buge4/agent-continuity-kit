#!/usr/bin/env bash
# seats-push.sh — merge THIS box's OAuth seats into the shared encrypted store and
# push, so every other box picks them up on its next seats-sync. Called by add-seat.sh.
# 2026-07-16 claude2. Merge rule: store ∪ local, LOCAL wins on same slot. Never prints a token.
set -uo pipefail
PASS="${VERITON_SEATS_PASS:-$HOME/.config/veriton/seats-pass}"
REPO="${VERITON_SEATS_REPO:-$HOME/.config/veriton/veriton-seats}"
ENV="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
LOG="${VERITON_SEATS_LOG:-/tmp/seats-sync.log}"
ts="$(date -u +%FT%TZ)"
[ -f "$PASS" ] || { echo "no passphrase at $PASS"; exit 1; }
if [ ! -d "$REPO/.git" ]; then gh repo clone buge4/veriton-seats "$REPO" >/dev/null 2>&1 || { echo "clone failed"; exit 1; }; fi
git -C "$REPO" fetch -q origin 2>/dev/null && git -C "$REPO" reset -q --hard origin/HEAD 2>/dev/null || true
store="$(mktemp)"; loc="$(mktemp)"; merged="$(mktemp)"
[ -f "$REPO/seats.env.gpg" ] && gpg --batch --quiet --passphrase-file "$PASS" -d "$REPO/seats.env.gpg" 2>/dev/null | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN" > "$store" || true
{ cat "$ENV" 2>/dev/null || sudo -n cat "$ENV" 2>/dev/null; } | grep -E "^export CLAUDE_CODE_OAUTH_TOKEN" > "$loc"
awk -F= '
  { key=$1; if(!(key in seen)){order[++n]=key; seen[key]=1}; val[key]=$0 }
  END { for(i=1;i<=n;i++) print val[order[i]] }
' "$store" "$loc" > "$merged"   # store first (base), local lines override same slot, new slots appended
gpg --batch --yes --passphrase-file "$PASS" --cipher-algo AES256 -c -o "$REPO/seats.env.gpg" "$merged"
nseats="$(grep -c . "$merged")"
shred -u "$store" "$loc" "$merged" 2>/dev/null || rm -f "$store" "$loc" "$merged"
git -C "$REPO" add seats.env.gpg
git -C "$REPO" -c user.email=noreply@arctx.tech -c user.name=claude2 commit -q -m "seats: update ($nseats) $ts" 2>/dev/null || { echo "$ts push: nothing changed" >>"$LOG"; exit 0; }
git -C "$REPO" pull -q --rebase 2>/dev/null || true
git -C "$REPO" push -q && echo "$ts PUSHED store ($nseats seats) — other boxes will sync" >>"$LOG" || echo "$ts push FAILED" >>"$LOG"
