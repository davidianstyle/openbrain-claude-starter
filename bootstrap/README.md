# Bootstrap — setup wizard + lifecycle scripts

All scripts live at `bootstrap/setup.sh` and `bootstrap/lib/*.sh`. This README covers re-running, adding/removing accounts after initial install, and common pitfalls.

## The wizard (`bootstrap/setup.sh`)

Run this once after `git clone`. Re-runnable: existing secrets are never clobbered silently, and the wizard skips steps that are already done.

```bash
./bootstrap/setup.sh
```

What each step does:

| # | Step | What it touches |
|---|---|---|
| 1 | Prereq check | python3, node, git; warns if `gh` or `claude` CLIs missing |
| 2 | User profile | prompts for name and writing voice |
| 3 | CLAUDE.md customization | substitutes placeholders in the repo's CLAUDE.md |
| 4 | Install config dir | creates `~/.config/openbrain/{,tokens,lib,venv}`, copies `.openbrain/env.example` → `.env` |
| 5 | Wire services | loops through each service, calls the matching `add-*.sh` |
| 6 | Register MCPs | writes `~/.claude.json` via `register-mcps.sh` |
| 7 | Git pre-commit hook | symlinks `.git/hooks/pre-commit` → `.openbrain/pre-commit.sh` |
| 8 | Validate | runs `validate.sh` (non-blocking) |

## Lifecycle scripts

All live in `bootstrap/lib/`. Safe to run directly any time.

### `setup-google-oauth.sh`

One-time GCP Desktop OAuth client setup. Walks you through enabling the 6 Google APIs, creating the OAuth consent screen, and generating a Desktop client ID. Stores `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` in `~/.config/openbrain/.env` and writes `~/.config/openbrain/tokens/oauth-client.json`.

Re-run to rotate the client credentials.

### `add-google-account.sh <email>`

Adds a single Google account. **One browser consent screen** covers all four scope sets (Gmail, Calendar, Meet, Drive/Docs/Sheets). Writes four token files:

```
~/.config/openbrain/tokens/google-<slug>-credentials.json   (Gmail MCP)
~/.config/openbrain/tokens/google-<slug>-gcal-token.json    (Calendar MCP)
~/.config/openbrain/tokens/google-<slug>-gmeet-token.json   (Meet MCP)
~/.config/google-docs-mcp/<slug>/token.json                 (Drive MCP)
```

Slug format: `<local>-<domain-with-dashes>` (e.g. `jane@acme.example.com` → `jane-acme-example-com`).

Re-run for the same email to refresh the tokens.

### `add-slack-workspace.sh <subdomain>`

Adds a single Slack workspace. Walks you through creating a Slack app (one per workspace), prompts for the `xoxp-*` User OAuth Token, and appends `SLACK_TOKEN_<UPPER_SNAKE>` to `.env`.

Accepts either a subdomain (`acme`), a full Slack URL (`acme.slack.com`), or with scheme (`https://acme.slack.com`).

### `add-asana.sh personal|work`

Adds an Asana Personal Access Token. Stores `ASANA_PAT_PERSONAL` or `ASANA_PAT_WORK` in `.env`.

### `add-fathom.sh`

Adds a Fathom API key. Stores `FATHOM_API_KEY` in `.env`.

### `register-mcps.sh`

Re-discovers every configured service from `.env` + `~/.config/openbrain/tokens/` and ensures `~/.claude.json` has a matching `mcpServers` entry for each. **Idempotent** — re-run any time you add/remove an account, or after a Claude Code upgrade.

Also re-syncs the launcher scripts from the repo (`.openbrain/lib/*.sh`) to `~/.config/openbrain/lib/` so MCP entries always point at the latest versions.

Creates `~/.claude.json.openbrain-backup` before mutating.

### `validate.sh`

Non-blocking sanity check. Verifies:

- Vault directories exist
- 21 skills present in `.claude/skills/`
- Every skill has a matching row in `CLAUDE.md` §13
- `~/.config/openbrain/.env` is mode 600
- All launcher scripts installed + executable
- Google/Slack/Asana/Fathom env vars populated where expected
- `~/.claude.json` has openbrain-managed MCP entries

Prints a summary with ✓ / ⚠ / ✗. Exits 0 unless a hard error is present.

---

## Removing an account

1. Delete the token files for the account you want to remove:

   Google:
   ```bash
   rm ~/.config/openbrain/tokens/google-<slug>-*.json
   rm -rf ~/.config/google-docs-mcp/<slug>
   ```

   Slack:
   ```bash
   sed -i '' '/^SLACK_TOKEN_<UPPER_SNAKE>=/d' ~/.config/openbrain/.env
   ```

2. Re-run `./bootstrap/lib/register-mcps.sh` — it will notice the missing credentials and remove the corresponding `mcpServers` entries from `~/.claude.json`.

3. Restart Claude Code.

---

## Common pitfalls

### "Google hasn't verified this app" during OAuth

Expected if your OAuth consent screen is in **Testing** mode. Click **Advanced → Go to OpenBrain MCP (unsafe)**. To avoid this entirely, add the Google account as a **Test User** on the OAuth consent screen in GCP Console.

### Google Workspace admin-managed accounts (custom domains)

If your account is in a Google Workspace, admin may need to approve the OAuth client ID at **Google Workspace admin → Security → API controls → App access control**. The `add-google-account.sh` flow will fail with an access-denied error until then.

### Slack workspace admin approval

Non-admin installs on managed Slack workspaces queue for admin approval at `https://<workspace>.slack.com/apps/manage/requests`. You'll see "App installation request has been submitted" — wait for approval, then re-run `add-slack-workspace.sh`.

### "MCP server not connecting" after install

Almost always a Claude Code restart issue. Quit Claude Code completely (Cmd-Q), then reopen in the vault directory. `/mcp` should show every server as "ready".

If a specific server stays red:
1. Run the launcher manually to see the error: `~/.config/openbrain/lib/gmail-mcp.sh <slug>`
2. Check that the token file(s) exist at the expected path
3. Re-run `add-google-account.sh <email>` to refresh credentials

### "npx not found" when a launcher runs

The launchers source `_common.sh` which tries to find Node in common locations (Homebrew, asdf, nvm). If it still can't find it, the fastest fix is:

```bash
brew install node
```

Or edit `~/.config/openbrain/lib/_common.sh` and add your Node bin directory to the `ensure_node_on_path` function.

### `register-mcps.sh` says "$CLAUDE_JSON not found"

You haven't started Claude Code yet on this machine. Launch it once (any directory), quit, then re-run the script.

### Rotating a token

All `add-*.sh` scripts are idempotent. Re-run the one for the service you're rotating:

```bash
./bootstrap/lib/add-google-account.sh jane@acme.com   # re-mints Google tokens
./bootstrap/lib/add-slack-workspace.sh acme           # re-prompts for xoxp token
./bootstrap/lib/add-asana.sh work                     # re-prompts for PAT
./bootstrap/lib/add-fathom.sh                         # re-prompts for API key
```

Then restart Claude Code.
