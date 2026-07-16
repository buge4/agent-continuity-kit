#!/usr/bin/env bash
# PreToolUse hook on Read (and Bash cat/less/head/tail). Refuses to disclose
# secret-bearing paths. Deny rule, code-enforced, not advice. Holds even with
# skip-permissions on.

set -u

input="$(cat)"
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

# Patterns we never disclose. Anchored to path component boundaries so
# benign mentions in code do not trip them.
deny_patterns=(
  '(^|/)\.env(\.[a-z0-9_-]+)?$'
  '(^|/)\.envrc$'
  '(^|/)\.ssh/'
  '(^|/)\.aws/credentials'
  '(^|/)\.kube/config'
  '(^|/)\.config/claude-code/oauth-token'
  '/secrets?/'
  '/credentials?/'
  '\.pem$'
  '\.key$'
  '_rsa$'
  '_ed25519$'
  'id_dsa$'
  'authorized_keys'
)

is_blocked_path() {
  local p="$1"
  for pat in "${deny_patterns[@]}"; do
    if printf '%s' "$p" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

case "$tool_name" in
  Read)
    fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$fp" ] && is_blocked_path "$fp"; then
      printf '{"decision":"block","reason":"Secrets-fence hook: path %q is on the secrets deny list. Configured in ~/.claude/hooks/block-secrets-read.sh"}\n' "$fp"
      exit 2
    fi
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    # cat / less / more / head / tail / awk / sed / grep -f / xxd / od / strings
    # against a deny-listed path counts as a read.
    extracted=$(printf '%s' "$cmd" | grep -oE '(\S*\.env(\.[a-zA-Z0-9_-]+)?|\S*\.ssh/\S*|\S*\.aws/credentials\S*|\S*\.kube/config\S*|\S*\.config/claude-code/oauth-token\S*|\S*\.pem|\S*\.key|\S*_rsa|\S*_ed25519|\S*authorized_keys\S*)' | head -1)
    if [ -n "$extracted" ]; then
      # Permit listing only (ls -l) of .ssh/authorized_keys for diagnostics
      if printf '%s' "$cmd" | grep -qE '^\s*ls\b'; then exit 0; fi
      printf '{"decision":"block","reason":"Secrets-fence hook: command references %q which is on the secrets deny list. Configured in ~/.claude/hooks/block-secrets-read.sh"}\n' "$extracted"
      exit 2
    fi
    ;;
esac
exit 0
