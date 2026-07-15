# Security note — read before you rely on this kit

**Why this matters (a real incident, not theory):** the snapshot/commit scripts write your agents' state into a git repo and push it. If a script does `git add -A`, it commits **any** file that lands in the state directory — including secrets an agent might drop there (a password file, a token, a `.env`). We hit exactly this in our own setup: a demo-password file an agent wrote into the state dir got committed and pushed to a private repo. Private repos limit the blast radius, but it should never leak in the first place.

## What the kit now does to prevent it
1. **Scoped add.** The scripts only add `*/current.md`, `*/history.md`, `MASTER-LEDGER.md`, `README.md`, `.gitignore` — never `git add -A`. A stray file in the state dir is not committed.
2. **`.gitignore`.** Ships secret-name patterns (`*password*`, `*secret*`, `*token*`, `*.key`, `*.env`, `*creds*`, …) as a second layer.
3. **No tokens in git remotes.** Use a credential helper (`gh auth setup-git`) — never embed a token in the remote URL (`https://user:TOKEN@github.com/...`). If you have one embedded, remove it: `git remote set-url origin https://github.com/<you>/<repo>.git`.

## Rules
- **Never** write secrets into the state dir (`~/.claude/state`). Put them in a non-git location (chmod 600) or a real secret store.
- Keep the state repo **private**.
- If a secret already reached git history: purge it (`git filter-repo` / `filter-branch`) + force-push, and rotate the secret.
