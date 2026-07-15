#!/usr/bin/env bash
# =============================================================================
# continuity-audit.sh  — Veriton agent continuity + auth + security self-audit.
# 2026-07-16 claude2.  READ-ONLY. Makes NO changes. Safe to run on any box.
#
# Verifies the canonical agent-continuity + auth-pool + security posture that the
# Veriton fleet (and every friend/Arctico setup that adopted the kit) should have.
# Prints PASS / WARN / FAIL per check + a remediation hint, then a summary.
# Exit 0 if no FAIL, 1 if any FAIL. WARN never fails the run.
#
#   Usage: continuity-audit.sh [--verbose]
#   Env:   AUDIT_HOME (default $HOME), AUDIT_AUTH_ENV (default /etc/veriton/claude-auth.env)
# =============================================================================
set -uo pipefail
H="${AUDIT_HOME:-$HOME}"
AUTH_ENV="${AUDIT_AUTH_ENV:-/etc/veriton/claude-auth.env}"
BIN="$H/.claude/bin"
STATE="$H/.claude/state"
VERBOSE=0; [ "${1:-}" = "--verbose" ] && VERBOSE=1
P=0; W=0; F=0
pass(){ printf '  \033[32mPASS\033[0m  %s\n' "$1"; P=$((P+1)); }
warn(){ printf '  \033[33mWARN\033[0m  %s\n     ↳ %s\n' "$1" "$2"; W=$((W+1)); }
fail(){ printf '  \033[31mFAIL\033[0m  %s\n     ↳ fix: %s\n' "$1" "$2"; F=$((F+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }
cron(){ crontab -l 2>/dev/null | grep -qF "$1"; }
sec(){ echo "== $1 =="; }

echo "======================================================================"
echo " Veriton continuity + auth + security audit   ($(date -u +%FT%TZ))"
echo " host=$(hostname 2>/dev/null)  home=$H"
echo "======================================================================"

sec "1. AUTH — token pool rotation + secure seat mgmt"
AX="$(command -v claude-auth-exec.sh 2>/dev/null || echo /opt/veriton-fleet/bin/claude-auth-exec.sh)"
if [ -f "$AX" ]; then
  if grep -q "token-POOL\|POOL rotation\|CLAUDE_CODE_OAUTH_TOKEN_2" "$AX"; then pass "claude-auth-exec.sh present + v2 pool-rotation"
  else warn "claude-auth-exec.sh present but looks pre-v2 (no pool rotation)" "upgrade to the v2 that rotates CLAUDE_CODE_OAUTH_TOKEN,_2..,_FALLBACK"; fi
  grep -q "VERITON_ALLOW_PAID_BACKSTOP" "$AX" && pass "paid API backstop is cost-gated (off unless flag set)" || warn "no paid-backstop gate found" "v2 gates the paid key behind VERITON_ALLOW_PAID_BACKSTOP"
else fail "claude-auth-exec.sh missing ($AX)" "install the auth wrapper from the continuity kit"; fi
[ -f "$(dirname "$AX")/add-seat.sh" ] && pass "add-seat.sh present (secure seat population)" || warn "add-seat.sh missing" "install it to add OAuth seats without pasting tokens in chat/history"
if [ -e "$AUTH_ENV" ]; then
  perm="$(stat -c %a "$AUTH_ENV" 2>/dev/null)"; grp="$(stat -c %G "$AUTH_ENV" 2>/dev/null)"
  wbit="${perm: -1}"; gbit="${perm:1:1}"; gmembers="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [ "$wbit" != 0 ]; then fail "$AUTH_ENV is WORLD-accessible (perms=$perm)" "chmod o-rwx $AUTH_ENV"
  elif [ "$gbit" = 0 ]; then pass "$AUTH_ENV locked to owner (perms=$perm)"
  elif [ -z "$gmembers" ]; then pass "$AUTH_ENV group '$grp' is single-member — safe (perms=$perm)"
  else warn "$AUTH_ENV group '$grp' also readable by: $gmembers" "confirm trusted, or tighten 640->600"; fi
  n=$( { sudo cat "$AUTH_ENV" 2>/dev/null || cat "$AUTH_ENV" 2>/dev/null; } | grep -cE "^export CLAUDE_CODE_OAUTH_TOKEN.*=.+[^=]$")
  [ "${n:-0}" -ge 1 ] && pass "auth env has $n OAuth seat(s) wired" || warn "no OAuth seats readable" "add seats via add-seat.sh (multiple = more weekly capacity)"
else warn "auth env $AUTH_ENV not present here" "friends/Arctico use their OWN auth env + OWN seats (never Veriton's keys)"; fi

sec "2. BINARY HEALTH — guard against silent 'native binary not installed'"
[ -f "$BIN/claude-binary-guard.sh" ] && pass "claude-binary-guard.sh present" || fail "claude-binary-guard.sh missing" "install it (re-runs postinstall if the native binary vanishes on update)"
cron "claude-binary-guard.sh" && pass "binary-guard in cron (*/30)" || fail "binary-guard not in cron" "add: */30 * * * * $BIN/claude-binary-guard.sh"
if have claude || [ -x "$H/.npm-global/bin/claude" ]; then
  bash -lc 'claude --version' >/dev/null 2>&1 && pass "claude --version runs (binary healthy)" || fail "claude --version FAILS (native binary missing)" "cd ~/.npm-global/lib/node_modules/@anthropic-ai/claude-code && node install.cjs"
else warn "claude not on PATH in login shell" "ensure ~/.profile puts npm-global/bin on PATH"; fi

sec "3. IDENTITY — fail-loud agent resolution (no silent 'unknown')"
if [ -f "$BIN/_resolve-agent.sh" ] || [ -f "$H/.claude/hooks/_resolve-agent.sh" ]; then pass "_resolve-agent.sh present (fail-loud identity)"; else warn "_resolve-agent.sh missing" "hooks may silently resolve to 'unknown/main' and cross-write state"; fi
for hk in block-secrets-read.sh block-prod-write.sh; do [ -f "$H/.claude/hooks/$hk" ] && pass "security hook $hk present" || warn "security hook $hk missing" "recommended guard hook from the kit"; done
if ls /etc/claude-assistant/*.env >/dev/null 2>&1; then
  bad=0; for e in /etc/claude-assistant/*.env; do v="$(sudo grep -m1 '^CLAUDE_AGENT_NAME=' "$e" 2>/dev/null | cut -d= -f2)"; [ -z "$v" ] && { bad=1; echo "     (empty CLAUDE_AGENT_NAME in $e)"; }; done
  [ "$bad" = 0 ] && pass "all /etc/claude-assistant/*.env have CLAUDE_AGENT_NAME set" || fail "an assistant env has empty CLAUDE_AGENT_NAME" "set it — empty name = wrong state save/restore on restart"
fi

sec "4. STATE — per-agent current.md valid + git-backed"
if [ -d "$STATE" ]; then
  for d in "$STATE"/*/; do a="$(basename "$d")"; [ "$a" = "*" ] && continue
    cur="$d/current.md"
    [ ! -f "$cur" ] && [ ! -f "$d/history.md" ] && continue   # not an agent state dir — skip
    if [ -f "$cur" ]; then
      lines=$(wc -l < "$cur"); grep -q NEXT_ACTION "$cur" && nx=ok || nx=missing
      if [ "$lines" -ge 5 ] && [ "$nx" = ok ]; then pass "state/$a/current.md valid ($lines lines, NEXT_ACTION present)"
      else warn "state/$a/current.md thin/incomplete ($lines lines, NEXT_ACTION=$nx)" "agent should write a fuller handover"; fi
    else warn "state/$a has no current.md" "agent never saved a handover"; fi
  done
  if git -C "$STATE" rev-parse >/dev/null 2>&1; then
    rem="$(git -C "$STATE" remote get-url origin 2>/dev/null)"; last="$(git -C "$STATE" log -1 --format=%cr 2>/dev/null)"
    pass "state is a git repo (remote=$rem, last commit $last)"
  else warn "state dir is not a git repo" "back state with a private git repo (durable off-box memory)"; fi
else fail "no $STATE dir" "create ~/.claude/state and per-agent current.md"; fi

sec "5. SNAPSHOT + REFRESH — the 3-layer memory keepers"
[ -f "$BIN/state-snapshot.sh" ] && cron "state-snapshot.sh" && pass "state-snapshot.sh in cron (*/5)" || fail "state-snapshot missing/not scheduled" "*/5 snapshot commits state off-box"
if [ -f "$BIN/haiku-refresh.sh" ]; then
  if grep -qiE "VERBATIM|NEVER invent|UNCHANGED" "$BIN/haiku-refresh.sh"; then pass "haiku-refresh.sh has anti-hallucination guard"
  else fail "haiku-refresh.sh MISSING anti-hallucination guard" "apply HAIKU-REFRESH-HALLUCINATION-FIX (reproduce state verbatim, never invent NEXT_ACTION)"; fi
else warn "haiku-refresh.sh not present" "optional Layer-C refresh"; fi

sec "6. NIGHTLY RESTART — clear long-lived sessions once/night"
if [ -f "$BIN/nightly-restart.sh" ]; then
  pass "nightly-restart.sh present"
  cron "nightly-restart.sh" && pass "nightly-restart scheduled in cron" || warn "nightly-restart present but not scheduled" "add a nightly slot per long-lived (remote-control) agent"
  echo "     note: stateless cron RUNNERS (oneshot claude -p per fire) need NO nightly clear — they start fresh every fire. Only long-lived remote-control/tmux sessions do."
else warn "nightly-restart.sh missing" "install for long-lived sessions (assistant/books/claudeweb-type)"; fi

sec "7. SECRET HYGIENE — no secrets world-readable / in git"
badperm=0
while IFS= read -r f; do
  perm="$(stat -c %a "$f" 2>/dev/null)"; case "$perm" in *[04448]) : ;; esac
  o="$(stat -c %A "$f" 2>/dev/null)"; case "$o" in *r??????r*|*------r*) echo "     world-readable secret-ish: $f ($o)"; badperm=1;; esac
done < <(grep -rlIE "sk-ant-(oat|api)0|gho_[A-Za-z0-9]|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY" "$H/.claude" "$H/.config" 2>/dev/null | head -50)
[ "$badperm" = 0 ] && pass "no world-readable secrets found under ~/.claude, ~/.config" || fail "world-readable secret(s) found (above)" "chmod 600 them; rotate if they were exposed"
if [ -d "$STATE/.git" ] || git -C "$STATE" rev-parse >/dev/null 2>&1; then
  if git -C "$STATE" grep -qIE "sk-ant-(oat|api)0|gho_[A-Za-z0-9]{20}|BEGIN .*PRIVATE KEY" HEAD 2>/dev/null; then fail "a secret appears committed in the state repo" "purge history + rotate; add a .gitignore/secret-scan pre-commit hook"
  else pass "no obvious secret committed in state repo HEAD"; fi
  [ -f "$STATE/.gitignore" ] && pass "state repo has a .gitignore" || warn "state repo has no .gitignore" "add one to block accidental secret commits"
fi

sec "8. WATCHDOGS (optional)"
[ -f "$BIN/stuck-git-watchdog.sh" ] && pass "stuck-git-watchdog.sh present" || warn "stuck-git-watchdog.sh missing" "optional: detects a wedged git push"
crontab -l 2>/dev/null | grep -qi "watchdog" && pass "a watchdog runs in cron" || warn "no watchdog in cron" "optional durable health monitor"

echo "======================================================================"
printf " SUMMARY:  \033[32m%d PASS\033[0m   \033[33m%d WARN\033[0m   \033[31m%d FAIL\033[0m\n" "$P" "$W" "$F"
echo "======================================================================"
[ "$F" -eq 0 ] && { echo " RESULT: continuity posture OK (address WARNs when convenient)."; exit 0; } || { echo " RESULT: $F FAIL(s) — fix the items marked 'fix:' above."; exit 1; }
