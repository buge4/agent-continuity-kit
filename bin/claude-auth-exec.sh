#!/usr/bin/env bash
# =============================================================================
# claude-auth-exec.sh  v2 — token-POOL rotation + optional PAID API-key backstop.
# Wired 2026-07-04 by hetzner-ops (v1: PRIMARY+FALLBACK). v2 2026-07-16 by claude2:
# generalises to an N-token OAuth POOL with per-token cap cooldown + rotation, and
# a cost-gated paid API-key backstop so the fleet never goes fully dark.
# ADDITIVE / REVERSIBLE.  Old v1 saved alongside as claude-auth-exec.sh.v1.bak
#
# Reads /etc/veriton/claude-auth.env (root:root 600). OAuth pool, in try order:
#   CLAUDE_CODE_OAUTH_TOKEN            (seat 1 — bvh@veriton.io, company pays)
#   CLAUDE_CODE_OAUTH_TOKEN_2 .. _9    (extra Team/Max seats — add as they arrive)
#   CLAUDE_CODE_OAUTH_TOKEN_FALLBACK   (overflow seat — e.g. bvhauge@gmail.com)
# Each seat is a full weekly cap; pooling them multiplies weekly capacity at $0.
# On a 401/429/usage-limit/auth error the seat is marked capped for COOLDOWN
# seconds and rotation moves to the next live seat. When ALL OAuth seats are
# capped AND VERITON_ALLOW_PAID_BACKSTOP=1, it falls back to the PAID key
# ANTHROPIC_API_KEY_VERITON (real money — OFF by default; flip the flag to spend).
#
# Env overrides: VERITON_CLAUDE_AUTH_ENV, VERITON_CLAUDE_STATE_DIR,
#   VERITON_CLAUDE_COOLDOWN (s), VERITON_CLAUDE_FAILOVER_GRACE (s),
#   VERITON_CLAUDE_BIN, VERITON_ALLOW_PAID_BACKSTOP (0/1).
# Usage: claude-auth-exec.sh [any claude args]
# =============================================================================
set -uo pipefail

AUTH_ENV="${VERITON_CLAUDE_AUTH_ENV:-/etc/veriton/claude-auth.env}"
STATE_DIR="${VERITON_CLAUDE_STATE_DIR:-$HOME/.cache/veriton-auth}"
STATE="$STATE_DIR/rotation.state"
COOLDOWN="${VERITON_CLAUDE_COOLDOWN:-3600}"      # s a capped seat is skipped
GRACE="${VERITON_CLAUDE_FAILOVER_GRACE:-30}"     # s: fast-exit window (persistent)
PAID_BACKSTOP="${VERITON_ALLOW_PAID_BACKSTOP:-0}"
FAILRE='401|429|rate.?limit|overloaded|authentication|invalid (api|api-key|api key|token|bearer)|unauthor|usage limit|quota|please run /login|token (has )?expired|oauth|credit balance'

# --- locate claude ---
CLAUDE_BIN="${VERITON_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
[ -z "$CLAUDE_BIN" ] && [ -x /home/veriton/.npm-global/bin/claude ] && CLAUDE_BIN=/home/veriton/.npm-global/bin/claude
[ -z "$CLAUDE_BIN" ] && { echo "[auth-exec] FATAL: claude binary not found" >&2; exit 96; }

# --- source canonical auth env ---
if [ -r "$AUTH_ENV" ]; then
  # shellcheck disable=SC1090
  . "$AUTH_ENV"
elif sudo -n cat "$AUTH_ENV" >/dev/null 2>&1; then
  eval "$(sudo -n cat "$AUTH_ENV")"
else
  echo "[auth-exec] FATAL: cannot read $AUTH_ENV" >&2; exit 97
fi

API_KEY="${ANTHROPIC_API_KEY_VERITON:-${ANTHROPIC_API_KEY:-}}"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN   # never leak a key into $0 OAuth runs

# --- build ordered, de-duped OAuth pool ---
declare -a NAMES=("CLAUDE_CODE_OAUTH_TOKEN")
for i in 2 3 4 5 6 7 8 9; do NAMES+=("CLAUDE_CODE_OAUTH_TOKEN_$i"); done
NAMES+=("CLAUDE_CODE_OAUTH_TOKEN_FALLBACK")

declare -a POOL=() POOLNAME=()
seen=" "
for n in "${NAMES[@]}"; do
  v="${!n:-}"
  [ -z "$v" ] && continue
  h="$(printf '%s' "$v" | cksum | cut -d' ' -f1)"
  case "$seen" in *" $h "*) continue;; esac
  seen="$seen$h "
  POOL+=("$v"); POOLNAME+=("$n")
done
NP=${#POOL[@]}
if [ "$NP" -eq 0 ] && { [ "$PAID_BACKSTOP" != 1 ] || [ -z "$API_KEY" ]; }; then
  echo "[auth-exec] FATAL: no OAuth seat in pool and no enabled API-key backstop" >&2; exit 98
fi

# --- cooldown state ---
mkdir -p "$STATE_DIR" 2>/dev/null || true
now="$(date +%s)"
tok_hash(){ printf '%s' "$1" | cksum | cut -d' ' -f1; }
is_cooled(){ local h ts; h="$(tok_hash "$1")"; [ -f "$STATE" ] || return 1
  ts="$(grep -E "^cap:$h:" "$STATE" 2>/dev/null | tail -1 | cut -d: -f3)"
  [ -n "$ts" ] && [ $((now - ts)) -lt "$COOLDOWN" ]; }
mark_capped(){ local h; h="$(tok_hash "$1")"; echo "cap:$h:$now" >> "$STATE"; }
mark_good(){ local h; h="$(tok_hash "$1")"
  { grep -v -E "^cap:$h:" "$STATE" 2>/dev/null || true; } > "$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE" 2>/dev/null || true; }

# try live seats first, capped-but-cooling seats last (better to try than hard-fail)
declare -a TRY=()
for idx in "${!POOL[@]}"; do is_cooled "${POOL[$idx]}" || TRY+=("$idx"); done
for idx in "${!POOL[@]}"; do is_cooled "${POOL[$idx]}" && TRY+=("$idx"); done

MODE=oneshot
for a in "$@"; do [ "$a" = "remote-control" ] && MODE=persistent; done

paid_backstop_oneshot(){
  [ "$PAID_BACKSTOP" = 1 ] && [ -n "$API_KEY" ] || return 1
  echo "[auth-exec] all OAuth seats capped — PAID API-key backstop (ANTHROPIC_API_KEY_VERITON, real money)" >&2
  OUT="$(ANTHROPIC_API_KEY="$API_KEY" "$CLAUDE_BIN" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$OUT"; exit "$rc"; }

if [ "$MODE" = oneshot ]; then
  rc=1; OUT=""
  for idx in "${TRY[@]}"; do
    t="${POOL[$idx]}"; name="${POOLNAME[$idx]}"
    OUT="$(CLAUDE_CODE_OAUTH_TOKEN="$t" "$CLAUDE_BIN" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then mark_good "$t"; printf '%s\n' "$OUT"; exit 0; fi
    if printf '%s' "$OUT" | grep -qiE "$FAILRE"; then
      echo "[auth-exec] seat $name auth/cap failure (rc=$rc) — rotating to next seat" >&2
      mark_capped "$t"; continue
    fi
    printf '%s\n' "$OUT"; exit "$rc"   # real task error, not a cap: return as-is
  done
  paid_backstop_oneshot "$@"
  echo "[auth-exec] FLEET DOWN: all $NP OAuth seats capped; paid backstop disabled (set VERITON_ALLOW_PAID_BACKSTOP=1 to spend)" >&2
  printf '%s\n' "$OUT"; exit "$rc"
else
  rc=99
  for idx in "${TRY[@]}"; do
    t="${POOL[$idx]}"; name="${POOLNAME[$idx]}"; start=$SECONDS
    CLAUDE_CODE_OAUTH_TOKEN="$t" "$CLAUDE_BIN" "$@"; rc=$?
    [ "$rc" -eq 0 ] && { mark_good "$t"; exit 0; }
    if [ $((SECONDS - start)) -lt "$GRACE" ]; then
      echo "[auth-exec] seat $name session failed fast (rc=$rc, $((SECONDS-start))s) — rotating" >&2
      mark_capped "$t"; continue
    fi
    exit "$rc"   # ran a while then died — not a cap
  done
  if [ "$PAID_BACKSTOP" = 1 ] && [ -n "$API_KEY" ]; then
    echo "[auth-exec] all OAuth seats capped — PAID API-key backstop for session" >&2
    exec env ANTHROPIC_API_KEY="$API_KEY" "$CLAUDE_BIN" "$@"
  fi
  echo "[auth-exec] FLEET DOWN: no seat available; paid backstop disabled" >&2
  exit "$rc"
fi
