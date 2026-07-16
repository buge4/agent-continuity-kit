# Shared seat pool across boxes (Veriton + Arctico + Gary) + auto-update fix

## Why
Each box runs an N-seat OAuth pool (claude-auth-exec.sh v2). To give every box the
SAME seats (and every future Team seat) automatically, seats live in ONE encrypted
store in a private GitHub repo; every box pulls it. GitHub is the hub — no box-to-box
link, so it works across separate Hetzner boxes. Only SEATS are shared; data/infra
stays isolated (own Supabase/SaaS per box).

## Root-cause fix baked in: claude auto-updater
Claude Code auto-updates itself, and the update reinstalls WITHOUT its postinstall ->
"native binary not installed" -> whole fleet dark. Fixes:
- `export DISABLE_AUTOUPDATER=1` in ~/.profile + your auth env + any systemd service env.
- `claude-binary-guard.sh` (cron */10) self-heals if it ever happens anyway.

## Components (bin/)
- `seats-sync.sh`  — cron */10: pull the store, decrypt, rewrite THIS box's OAuth seats
  in the auth env (preserves ANTHROPIC_API_KEY_* + flags). Idempotent; only writes on change.
- `seats-push.sh`  — merge this box's seats INTO the store (store ∪ local, local wins) + push.
- `add-seat.sh`    — add a seat via a SILENT prompt, then auto-calls seats-push.sh so
  every other box picks it up on its next sync.

## Set up on a NEW box (Arctico / Gary)
1. Install bin/* into ~/.claude/bin; `export DISABLE_AUTOUPDATER=1` (see above); cron:
   `*/10 * * * * ~/.claude/bin/claude-binary-guard.sh`
   `*/10 * * * * ~/.claude/bin/seats-sync.sh`
2. Get the shared passphrase file from Bjorn -> `~/.config/veriton/seats-pass` (chmod 600).
   (Bjorn distributes it out-of-band; it is NEVER in git/chat/board — only the .gpg is.)
3. `gh repo clone buge4/veriton-seats ~/.config/veriton/veriton-seats`
4. Run `~/.claude/bin/seats-sync.sh` once -> your auth env now holds the shared seats.
5. Add your own seats with `add-seat.sh` -> they propagate to every box.

## Security
Store repo is private AND gpg-AES256 encrypted; the passphrase never leaves the boxes.
Compromising the repo alone yields nothing without the passphrase.
