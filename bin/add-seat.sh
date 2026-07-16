#!/usr/bin/env bash
# =============================================================================
# add-seat.sh — securely add a Claude Code OAuth seat token to the fleet POOL.
# 2026-07-16 claude2. Pairs with claude-auth-exec.sh v2 rotation.
#
#   1) On any machine logged into the desired Claude seat:  claude setup-token
#   2) Copy the token it prints, then on the box run:        add-seat.sh [slot]
#   3) Paste the token at the SILENT prompt (not echoed, not in argv/history).
#
# slot (optional):
#   (none)     -> next free numbered slot CLAUDE_CODE_OAUTH_TOKEN_2.._9  (Team seats)
#   fallback   -> CLAUDE_CODE_OAUTH_TOKEN_FALLBACK  (e.g. bvhauge@gmail overflow)
#   primary    -> CLAUDE_CODE_OAUTH_TOKEN           (re-key seat 1 after a reset)
# The token is written to /etc/veriton/claude-auth.env (root:600) via sudo and is
# NEVER echoed. The rotation cooldown for the new seat is cleared so it is tried
# on the very next fleet fire.
# =============================================================================
set -uo pipefail
ENV_FILE="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
STATE_DIR="${VERITON_CLAUDE_STATE_DIR:-$HOME/.cache/veriton-auth}"
slot="${1:-auto}"

val_of(){ sudo grep -E "^export $1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"; }

case "$slot" in
  primary)  VAR=CLAUDE_CODE_OAUTH_TOKEN ;;
  fallback) VAR=CLAUDE_CODE_OAUTH_TOKEN_FALLBACK ;;
  auto)
    VAR=""
    for i in 2 3 4 5 6 7 8 9; do
      if [ -z "$(val_of "CLAUDE_CODE_OAUTH_TOKEN_$i")" ]; then VAR="CLAUDE_CODE_OAUTH_TOKEN_$i"; break; fi
    done
    [ -z "$VAR" ] && { echo "All numbered slots _2.._9 are full. Use: add-seat.sh fallback"; exit 1; } ;;
  *) echo "usage: add-seat.sh [ auto | fallback | primary ]"; exit 2 ;;
esac

echo "Target slot: $VAR"
[ -n "$(val_of "$VAR")" ] && { printf 'That slot is already SET. Overwrite? [y/N] '; read -r yn; [ "$yn" = y ] || { echo aborted; exit 0; }; }

printf 'Paste the seat token (input hidden), then Enter: '
IFS= read -rs TOK; echo
[ -z "$TOK" ] && { echo "empty — aborted"; exit 1; }
case "$TOK" in *[![:print:]]*) echo "token has non-printable chars — aborted"; exit 1;; esac
[ "${#TOK}" -lt 20 ] && { echo "token looks too short (${#TOK} chars) — aborted"; exit 1; }

# write: replace existing line if present, else append. Done atomically via sudo.
TMP="$(mktemp)"; sudo cat "$ENV_FILE" > "$TMP" 2>/dev/null || true
if grep -qE "^export $VAR=" "$TMP"; then
  # rewrite that line without exposing TOK on argv (use awk with env var)
  VAR="$VAR" TOK="$TOK" awk 'BEGIN{v=ENVIRON["VAR"];t=ENVIRON["TOK"]}
    $0 ~ "^export " v "=" {print "export " v "=\"" t "\""; next} {print}' "$TMP" | sudo tee "$ENV_FILE" >/dev/null
else
  { cat "$TMP"; printf 'export %s="%s"\n' "$VAR" "$TOK"; } | sudo tee "$ENV_FILE" >/dev/null
fi
shred -u "$TMP" 2>/dev/null || rm -f "$TMP"
sudo chmod 600 "$ENV_FILE"; sudo chown root:root "$ENV_FILE"

# clear this seat's cooldown so it's tried immediately
h="$(printf '%s' "$TOK" | cksum | cut -d' ' -f1)"
[ -f "$STATE_DIR/rotation.state" ] && { grep -v -E "^cap:$h:" "$STATE_DIR/rotation.state" > "$STATE_DIR/rotation.state.tmp" 2>/dev/null; mv -f "$STATE_DIR/rotation.state.tmp" "$STATE_DIR/rotation.state" 2>/dev/null; }
unset TOK

echo "Seat written to $VAR. Current pool (names + set/empty, no values):"
while IFS='=' read -r k v; do case "$k" in export\ CLAUDE_CODE_OAUTH_TOKEN*) n="${k#export }"; [ -n "$v" ] && echo "  $n = [SET]" || echo "  $n = [empty]";; esac; done < <(sudo cat "$ENV_FILE")
echo "Done. Next fleet fire will rotate through all SET seats."

# propagate the new seat to the shared store so other boxes sync it
[ -x "$HOME/.claude/bin/seats-push.sh" ] && { echo "Propagating to shared seat store..."; "$HOME/.claude/bin/seats-push.sh" || echo "(store push skipped; seat still active locally)"; }
