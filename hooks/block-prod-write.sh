#!/usr/bin/env bash
# PreToolUse hook on Bash. Blocks commands that would write to live
# production targets unless a recent HMAC-signed prod-go token exists in
# /run/veriton/prod-go.token. The token is produced by
# /home/veriton/.claude/scripts/prod-go-confirm.sh and expires 15 minutes
# after issue, so a forgotten elevation cannot stay armed across a session.
#
# Override mechanism (legacy): VERITON_PROD_GO=yes in the command string is
# NO LONGER ACCEPTED. The signed-nonce path is the only override.

set -u

input="$(cat)"
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Detect a prod-write candidate
is_prod_write=0
reason=""
if printf '%s' "$cmd" | grep -qE '\bvercel\s+(deploy|--prod|promote)\b'; then
  is_prod_write=1; reason="vercel deploy/promote"
fi
prod_ref='ocylhlmjsoxchkxzvoys'
if printf '%s' "$cmd" | grep -q "$prod_ref" && \
   printf '%s' "$cmd" | grep -qiE '\b(insert|update|delete|drop|truncate|alter)\b'; then
  is_prod_write=1; reason="write SQL against production Supabase"
fi
if printf '%s' "$cmd" | grep -qE '\bsupabase\s+(db\s+push|migration\s+up|functions\s+deploy)'; then
  is_prod_write=1; reason="supabase db push / migration up / functions deploy"
fi
if printf '%s' "$cmd" | grep -qE '\bgit\s+push\b.*\b(main|master)(\s|$)'; then
  is_prod_write=1; reason="git push to main"
fi
if printf '%s' "$cmd" | grep -qE '\bgit\s+push\s+.*--force\b|\bgit\s+push\s+.*-f\b'; then
  is_prod_write=1; reason="git push --force"
fi

[ "$is_prod_write" = "0" ] && exit 0

# Prod-write candidate. Look for a valid prod-go token.
TOKEN=/run/veriton/prod-go.token
SECRET=/etc/veriton/prod-go.secret

block_msg() {
  local msg="$1"
  printf '{"decision":"block","reason":"%s"}\n' "$msg"
  exit 2
}

if [ ! -r "$TOKEN" ]; then
  block_msg "No-accidental-production hook: $reason blocked. Run prod-go-confirm to issue a 15-minute signed-nonce token first. Configured in ~/.claude/hooks/block-prod-write.sh"
fi
if [ ! -r "$SECRET" ]; then
  block_msg "No-accidental-production hook: $reason blocked. Missing secret at /etc/veriton/prod-go.secret on this host."
fi

# Token format: "<ts>|<description>|<hmac_hex>"
token_line=$(head -1 "$TOKEN")
ts=$(printf '%s' "$token_line" | awk -F'|' '{print $1}')
desc=$(printf '%s' "$token_line" | awk -F'|' '{
  out=""
  for (i = 2; i < NF; i++) { out = (out == "" ? $i : out "|" $i) }
  print out
}')
hmac_seen=$(printf '%s' "$token_line" | awk -F'|' '{print $NF}')

if ! printf '%s' "$ts" | grep -qE '^[0-9]+$'; then
  block_msg "No-accidental-production hook: $reason blocked. Token file is malformed."
fi

# Recompute HMAC over "<ts>|<desc>"
payload="${ts}|${desc}"
hmac_calc=$(printf '%s' "$payload" \
  | openssl dgst -sha256 -mac HMAC -macopt "key:$(cat "$SECRET")" \
  | awk '{print $2}')
if [ -z "$hmac_calc" ] || [ "$hmac_calc" != "$hmac_seen" ]; then
  block_msg "No-accidental-production hook: $reason blocked. Token HMAC does not verify; refusing to elevate."
fi

# Expiry: 15 minutes (900 seconds)
now=$(date -u +%s)
age=$(( now - ts ))
if [ "$age" -lt 0 ] || [ "$age" -gt 900 ]; then
  block_msg "No-accidental-production hook: $reason blocked. Token expired (age=${age}s, max=900s). Run prod-go-confirm again."
fi

# Approved. Log the elevated execution so journald has the trail.
logger -t veriton-prod-go "ELEVATED $reason desc='$desc' age=${age}s"
exit 0
