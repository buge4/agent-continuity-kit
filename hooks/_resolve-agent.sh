# Sourced by continuity hooks. Sets CONT_AGENT to the real agent name, or "" (fail loud).
# NEVER silently uses 'unknown' (that bug let same-user agents collide on state/unknown/).
CONT_AGENT="${CLAUDE_AGENT_NAME:-}"
if [ -z "$CONT_AGENT" ] || [ "$CONT_AGENT" = "unknown" ]; then
  echo "$(date -u +%FT%TZ) FATAL continuity: CLAUDE_AGENT_NAME unresolved (pid $$ cwd $PWD) - refusing state/unknown" >> "$HOME/.claude/hook-errors.log" 2>/dev/null
  CONT_AGENT=""
fi
