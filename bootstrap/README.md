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
| 2 | PII scanner | `install-pii-scan.sh` — Presidio + spaCy venv (~570MB, first run only) |
| 3 | User profile | prompts for name and writing voice |
| 4 | CLAUDE.md customization | substitutes placeholders in the repo's CLAUDE.md |
| 5 | Install config dir | creates `~/.config/openbrain/{,tokens,lib,venv}`, copies `.openbrain/env.example` → `.env` |
| 6 | Wire services | loops through each service, calls the matching `add-*.sh` |
| 7 | Register MCPs | writes `~/.claude.json` via `register-mcps.sh` |
| 8 | Git hooks | symlinks `.git/hooks/pre-commit` → `.openbrain/pre-commit.sh`, plus the pre-push guardrail |
| 9 | Auto git sync hooks | wires the Claude Code Stop / SessionStart hooks |
| 10 | Validate | runs `validate.sh` (non-blocking) |

## Architecture: what's brain-specific vs. shared

`setup.sh` builds two layers, and that split is why `minimal-init.sh` exists:

- **Shared MCP-integration layer** (`~/.config/openbrain/`) — `.env` (secrets), `tokens/` (per-account OAuth), `lib/` (launchers + `_common.sh`), `venv/`. This is *not* brain-specific: it's the provider-agnostic plumbing any consumer of the `davidianstyle/*-mcp` servers needs. `bootstrap/lib/minimal-init.sh` stands up *just* this layer.
- **The brain** — the Obsidian vault, `CLAUDE.md`, `Home.md`, skills, git hooks: everything else `setup.sh` layers on top.

Because the shared layer is factored into `minimal-init.sh`, a separate tool that wants the MCPs *without* the vault can shallow-clone this repo, run `minimal-init.sh`, vendor the `add-*.sh` scripts it needs, and stop.

A third boundary sits below both: the **MCP servers** (`davidianstyle/google-mcp`, `asana-mcp`, …) are separate repos. The launchers in `~/.config/openbrain/lib/` clone them to `~/<name>`, build them on demand (`ensure_mcp_server`), and `exec` them. The shared layer holds credentials + launchers; the servers live in their own repos.

## Lifecycle scripts

All live in `bootstrap/lib/`. Safe to run directly any time.

### `minimal-init.sh`

Stands up the shared MCP-integration layer (the `~/.config/openbrain/` dirs, `.env` from the template, launcher scripts) — no vault. Called by `setup.sh` step 4, and directly by external consumers that want the MCP plumbing without the brain. Idempotent.

### `setup-google-oauth.sh`

One-time setup of the Google OAuth client. Stores `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET` in `~/.config/openbrain/.env` and writes `~/.config/openbrain/tokens/google-oauth-client.json` (derived from `.env`). It first asks whether you're reusing an existing client, which picks one of two paths:

- **Reusing a shared app** (most common when joining a team that already has one) — answer **yes**. You skip the Google Cloud Console entirely; just paste the **client ID** and **client secret** someone hands you (e.g. from a shared password manager). Use this if your team already set up a Google app — you don't need to touch any Google developer settings.
- **Creating a new app** — answer **no**, and the script walks you through the one-time Google Cloud Console steps (enable the 6 APIs, configure the consent screen, create a Desktop client ID), then prompts for the two values it generates.

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

### `install-pii-scan.sh`

Installs (or repairs) the local PII scanner the outbound sync skills depend on: a dedicated Python venv holding `presidio-analyzer`, `presidio-anonymizer`, `spacy` and the `en_core_web_lg` model, plus a `pii-scan` symlink in `~/.local/bin`. Idempotent — a no-op when the scanner is already healthy.

```bash
./bootstrap/lib/install-pii-scan.sh            # install if missing, verify
./bootstrap/lib/install-pii-scan.sh --check    # verify only. exit 0 healthy, 2 not
./bootstrap/lib/install-pii-scan.sh --force    # rebuild the venv from scratch
```

It always finishes by running `pii-scan --selftest`, which asserts the NER model really detects a name — having the packages installed is not evidence the scanner works. Uses `uv` when available (much faster, fetches its own Python 3.12); otherwise needs a system Python between 3.9 and 3.13, since spaCy's compiled wheels lag new CPython releases. Roughly 430MB of model (~570MB venv) and a few minutes on first run.

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

### `smoke-test.sh`

Pre-install counterpart to `validate.sh`. Where `validate.sh` checks whether *this machine's install* is healthy (real `~/.config/openbrain` + `~/.claude.json` state, after `setup.sh`), `smoke-test.sh` checks whether the *code in this checkout* is sound — with nothing installed and without touching your real `$HOME`. Three tiers:

1. every shell script under `bootstrap/` and `.openbrain/` parses (`bash -n`)
2. `minimal-init.sh` stands up the shared layer in a throwaway `$HOME` — dirs + `.env` + launchers, idempotent on re-run
3. the `_oauth_env` indirect-expansion helper behaves under `set -u` (set → value, unset → empty, no crash)

Tiers 2–3 self-skip when the feature isn't in the tree yet, so it's safe to run at any point. Exits non-zero on the first hard failure — suitable as a CI gate. A green run in both the `claude-starter` and `gemini-starter` editions is executable proof the shared `bootstrap/lib` layer hasn't drifted.

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

## Adding another OAuth provider

The OAuth machinery is namespaced by a **provider key** (`google` today; e.g. `microsoft` next) so a second provider drops in without touching the shared drift/fingerprint plumbing. The convention:

1. **`.env` vars** — store the client under `<PROVIDER>_OAUTH_CLIENT_ID` / `<PROVIDER>_OAUTH_CLIENT_SECRET` (uppercase; dashes → underscores). Add blank entries to `.openbrain/env.example`. The generic helpers resolve these by provider key via indirect expansion.
2. **Client-config writer** *(the one provider-specific helper)* — add `sync_<provider>_oauth_client_json()` to `lib/common.sh`. Write `tokens/<provider>-oauth-client.json` in whatever shape that provider's auth library expects (Google uses the `{"installed": {…}}` desktop-client shape; Microsoft/MSAL differs). Make it atomic + idempotent and a no-op when the `.env` vars are unset, like `sync_google_oauth_client_json`.
3. **Generic helpers — reuse, don't copy.** `oauth_fingerprint <provider>`, `write_oauth_fingerprint <provider>`, and `auth_drift_detected <provider>` already work for any provider — just pass the key. They use `tokens/.<provider>-oauth-fingerprint`.
4. **Account + refresh scripts** — add `add-<provider>-account.sh` (mint flow → write the per-account creds file the MCP reads, then `write_oauth_fingerprint <provider>` after a successful mint) and `refresh-<provider>-tokens.sh` (token probe; on `auth_drift_detected <provider>`, emit the reconnect nudge bracketed by `OPENBRAIN_AUTH_NUDGE_BEGIN` / `OPENBRAIN_AUTH_NUDGE_END` — the SessionStart hooks surface it verbatim, provider-agnostic).
5. **Launcher** — add `<provider>-mcp.sh` in `.openbrain/lib/`. Check the per-account creds file and `exec` the server. **Do not check or regenerate the client-config json there** — the MCP server reads the per-account creds, not the client json (see `google-mcp.sh` and the note in `src/auth.ts`).
6. **`register-mcps.sh`** — discover the provider's configured accounts and register the `mcpServers` entries.

Only the writer (step 2) and the per-provider scripts (steps 4–5) are provider-specific; the fingerprint / drift / nudge logic is shared. See the `OAuth client config … per provider` block in `lib/common.sh` for the helper contracts.

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
