#!/usr/bin/env bash
# =============================================================================
# add-seat.sh — securely add a Claude Code OAuth seat token to the fleet POOL.
# 2026-07-16 claude2. v2: sudo-OPTIONAL + owner-PRESERVING (works on root-owned
# /etc envs AND user-owned envs where the agent user has NO sudo — arctico/gary).
#
#   1) On the seat's account:  CLAUDE_CONFIG_DIR=/tmp/seat claude setup-token
#   2) On the box:             add-seat.sh [slot]   (paste token at the SILENT prompt)
#
# Auth-env path is $VERITON_CLAUDE_AUTH_ENV (default /etc/veriton/claude-auth.env).
# slot: (none)=next free _2.._9 | fallback=_FALLBACK | primary=CLAUDE_CODE_OAUTH_TOKEN
# The token is NEVER echoed. The file's original owner+mode are preserved (never
# forced to root:root). If the env is unreadable/unwritable and no sudo -> clean abort.
# =============================================================================
set -uo pipefail
ENV_FILE="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
STATE_DIR="${VERITON_CLAUDE_STATE_DIR:-$HOME/.cache/veriton-auth}"
slot="${1:-auto}"

# --- sudo-optional env IO (root-owned OR user-owned) ---
_S=""
_pick_sudo(){ local f="$1"
  if [ -e "$f" ]; then { [ -r "$f" ] && [ -w "$f" ]; } && { _S=""; return 0; }
  else [ -w "$(dirname "$f")" ] && { _S=""; return 0; }; fi
  sudo -n true 2>/dev/null && { _S="sudo"; return 0; }; return 1; }
env_read(){ cat "$ENV_FILE" 2>/dev/null || sudo -n cat "$ENV_FILE" 2>/dev/null; }
env_write(){ local tmp="$1" owner mode
  _pick_sudo "$ENV_FILE" || { echo "[add-seat] no access to $ENV_FILE (no perm + no sudo). Ask the box owner to add the seat manually." >&2; return 1; }
  if [ -e "$ENV_FILE" ]; then owner="$($_S stat -c %U:%G "$ENV_FILE" 2>/dev/null)"; mode="$($_S stat -c %a "$ENV_FILE" 2>/dev/null)"; else owner=""; mode=600; fi
  $_S cp "$tmp" "$ENV_FILE" && $_S chmod "${mode:-600}" "$ENV_FILE"
  [ -n "$owner" ] && $_S chown "$owner" "$ENV_FILE" 2>/dev/null || true; }

val_of(){ env_read | grep -E "^export $1=" | head -1 | cut -d= -f2- | tr -d '"'"'"; }

case "$slot" in
  primary)  VAR=CLAUDE_CODE_OAUTH_TOKEN ;;
  fallback) VAR=CLAUDE_CODE_OAUTH_TOKEN_FALLBACK ;;
  auto)
    VAR=""
    for i in 2 3 4 5 6 7 8 9; do [ -z "$(val_of "CLAUDE_CODE_OAUTH_TOKEN_$i")" ] && { VAR="CLAUDE_CODE_OAUTH_TOKEN_$i"; break; }; done
    [ -z "$VAR" ] && { echo "All numbered slots _2.._9 are full. Use: add-seat.sh fallback"; exit 1; } ;;
  *) echo "usage: add-seat.sh [ auto | fallback | primary ]"; exit 2 ;;
esac

echo "Target slot: $VAR   (env: $ENV_FILE)"
[ -n "$(val_of "$VAR")" ] && { printf 'That slot is already SET. Overwrite? [y/N] '; read -r yn; [ "$yn" = y ] || { echo aborted; exit 0; }; }

printf 'Paste the seat token (input hidden), then Enter: '
IFS= read -rs TOK; echo
[ -z "$TOK" ] && { echo "empty — aborted"; exit 1; }
case "$TOK" in *[![:print:]]*) echo "token has non-printable chars — aborted"; exit 1;; esac
[ "${#TOK}" -lt 20 ] && { echo "token looks too short (${#TOK} chars) — aborted"; exit 1; }

TMP="$(mktemp)"; env_read > "$TMP" 2>/dev/null || true
if grep -qE "^export $VAR=" "$TMP" 2>/dev/null; then
  VAR="$VAR" TOK="$TOK" awk 'BEGIN{v=ENVIRON["VAR"];t=ENVIRON["TOK"]}
    $0 ~ "^export " v "=" {print "export " v "=\"" t "\""; next} {print}' "$TMP" > "$TMP.new"
else
  { cat "$TMP"; printf 'export %s="%s"\n' "$VAR" "$TOK"; } > "$TMP.new"
fi
if ! env_write "$TMP.new"; then shred -u "$TMP" "$TMP.new" 2>/dev/null || rm -f "$TMP" "$TMP.new"; exit 1; fi
shred -u "$TMP" "$TMP.new" 2>/dev/null || rm -f "$TMP" "$TMP.new"

# clear this seat's rotation cooldown so it is tried immediately
h="$(printf '%s' "$TOK" | cksum | cut -d' ' -f1)"; unset TOK
[ -f "$STATE_DIR/rotation.state" ] && { grep -v -E "^cap:$h:" "$STATE_DIR/rotation.state" > "$STATE_DIR/rotation.state.tmp" 2>/dev/null; mv -f "$STATE_DIR/rotation.state.tmp" "$STATE_DIR/rotation.state" 2>/dev/null; }

echo "Seat written to $VAR. Current pool (names + set/empty, no values):"
env_read | while IFS='=' read -r k v; do case "$k" in export\ CLAUDE_CODE_OAUTH_TOKEN*) n="${k#export }"; [ -n "$v" ] && echo "  $n = [SET]" || echo "  $n = [empty]";; esac; done
echo "Done. Next fleet fire will rotate through all SET seats."

# propagate the new seat to the shared store so other boxes sync it
[ -x "$HOME/.claude/bin/seats-push.sh" ] && { echo "Propagating to shared seat store..."; "$HOME/.claude/bin/seats-push.sh" || echo "(store push skipped; seat still active locally)"; }
