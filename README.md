# OpenBrain

**A personal AI Chief of Staff in an Obsidian vault, managed by Claude Code.**

OpenBrain is a portable template for a [Linking Your Thinking](https://www.linkingyourthinking.com/) (LYT) knowledge base that doubles as an operating layer for [Claude Code](https://claude.com/claude-code). Clone it, run one setup script, and you get:

- A fully scaffolded Obsidian vault (Inbox, Spaces, Atlas, Sources, Templates)
- 21 pre-built Chief of Staff [skills](#skills) (daily brief, inbox triage, capture meeting, etc.)
- Multi-account MCP wiring for Gmail, Google Calendar, Google Meet, Google Drive/Docs/Sheets, Slack, Asana, and Fathom — any number of accounts per service
- A people data model with cadence tracking, interaction logging, and alias resolution

Built for people who want Claude to act on their calendar, email, tasks, and notes the way a human chief of staff would — proactively, with context, and without constant re-briefing.

---

## Prerequisites

- **macOS** (Linux should work; untested)
- **git** — usually `xcode-select --install`
- **Python 3.10+** — `brew install python` (system python also works)
- **Node.js 18+** — `brew install node` (or asdf / nvm)
- **Claude Code** — [installation instructions](https://docs.claude.com/en/docs/claude-code/setup)
- **Obsidian** — [download](https://obsidian.md)
- Optional: **GitHub CLI** (`brew install gh`) if you want automated remote setup
- Optional: **uv** (`brew install uv`) — makes the PII-scanner install much faster and
  sidesteps Python-version issues; setup falls back to `python3 -m venv` without it

Setup also installs a **local PII scanner** (Microsoft Presidio + spaCy; ~430MB model,
~570MB venv, a few minutes on first run). It is required: the push and pull skills scan
everything they publish or take in for personal data, and refuse to run if the scanner
is missing rather than fall back to a pattern list. The text it reads never leaves your
machine. See `bootstrap/PII-SCAN-CONTRACT.md`.

---

## Install

```bash
git clone https://github.com/davidianstyle/openbrain-claude-starter.git ~/OpenBrain
cd ~/OpenBrain
./bootstrap/setup.sh
```

The wizard will:

1. Ask for your name and writing-voice blurb
2. Customize `CLAUDE.md` with your details
3. Create `~/.config/openbrain/` and copy launcher scripts
4. Walk you through Google Cloud OAuth setup (one-time, 5 minutes)
5. Loop through each service and ask which accounts to add:
   - "Add a Google account?" → y → paste email → browser OAuth → done
   - "Add another?" → repeat for as many as you want
   - Same for Slack workspaces, Asana, Fathom
6. Register every MCP server with Claude Code
7. Link the pre-commit hook
8. Optionally enable auto git sync hooks (commit + push on stop, pull on start)
9. Validate the install

Restart Claude Code and run `/mcp` to verify everything connected. Run `/daily-brief` as your first skill.

---

## Adding accounts later

The wizard is not a one-shot. You can add services any time:

```bash
./bootstrap/lib/add-google-account.sh jane@newdomain.com
./bootstrap/lib/add-slack-workspace.sh newteam           # → newteam.slack.com
./bootstrap/lib/add-asana.sh personal                    # or work
./bootstrap/lib/add-fathom.sh
./bootstrap/lib/register-mcps.sh                         # re-sync ~/.claude.json
./bootstrap/lib/install-pii-scan.sh                      # install/repair the PII scanner
./bootstrap/lib/install-pii-scan.sh --check              # verify it; 0 healthy, 2 not
```

Each script is idempotent — safe to re-run.

---

## What you get

### Vault layout

```
~/OpenBrain/
├── + Inbox/                  # capture first, triage later
├── + Spaces/                 # MOCs (Maps of Content)
│   └── People.md             # people MOC (created on demand)
├── + Atlas/                  # atomic notes — the actual knowledge
│   ├── Daily/                # daily notes
│   ├── Weekly Reviews/       # weekly synthesis
│   ├── People/               # person notes
│   ├── Interactions/         # meeting/call/thread notes
│   ├── Ideas/
│   ├── Decisions/
│   ├── Goals/
│   ├── Places/
│   ├── Organizations/
│   └── Quotes/
├── + Sources/                # literature / reference notes
├── + Extras/
│   └── Templates/            # 14 note templates
├── + Archive/                # cold storage
├── CLAUDE.md                 # the operating manual Claude reads every session
├── Home.md                   # front door with MOC index
└── .claude/skills/           # 21 Chief of Staff skills
```

### Skills

| Skill | Purpose |
|---|---|
| `/daily-brief` | Morning briefing across all your calendars, mail, Slack, tasks |
| `/daily-review` | End-of-day reconciliation — check off tasks, push Asana updates |
| `/process-inbox` | Triage `+ Inbox/` + Gmail + Slack; auto-push tagged tasks to Asana |
| `/meeting-prep` | Assemble a briefing for a meeting or 1:1 |
| `/capture-meeting` | Turn notes/transcript into an interaction note, update people |
| `/capture-youtube` | Literature note from a YouTube video |
| `/log-person` | Create a person note, seeded from Gmail/Slack |
| `/log-note` | Quick-capture a thought as an atomic note |
| `/log-interaction` | Manual touchpoint log |
| `/log-idea` | Record an idea |
| `/log-decision` | Record a decision with context and alternatives |
| `/log-goal` | Create a goal with definition of done |
| `/log-place` | Create a place note |
| `/log-organization` | Create an organization note |
| `/log-quote` | Save a quote |
| `/draft-follow-up` | Draft a reply email/Slack message (never sends) |
| `/what-am-i-missing` | Surface overdue tasks, cadence misses, unanswered mail |
| `/people-audit` | Cadence health report + regenerate People MOC |
| `/sync-people` | Discovery pass across Gmail/Calendar/Slack to find unknown people |
| `/sync-organizations` | Discovery pass across Gmail/Calendar/Slack/Fathom for organizations not yet captured; stages candidates for review |
| `/sync-places` | Discovery pass across Calendar (plus mail/Fathom signal) for physical places not yet captured; stages candidates for review |
| `/learn-writing-style` | Derive a writing-style profile from your sent mail and Slack, then update CLAUDE.md §6 |
| `/weekly-review` | Monday synthesis |
| `/push-openbrain-template` | Genericize vault improvements and open a PR against the template repo |
| `/pull-openbrain-template` | Pull the template's `main` into the vault: per-file merge from the last applied marker (`.openbrain/local/taken.tsv`), incoming content scanned before it lands |
| `/asana` | Quick view of upcoming Asana tasks with interactive check-off |
| `/push-mcp-change` | Stage a change to a hand-managed MCP fork, and optionally open its upstream PR |
| `/brain-update-check` | Report which MCP servers have updates waiting (upstream moved, dist stale, npm publish, an open session on an old build), auto-apply what the per-MCP `auto\|ask` policy allows, and offer to apply the rest — read-only beyond that until you say go |

Skills are markdown procedures — Claude reads the SKILL.md and performs the steps. No code execution.

### Supported MCP servers

One stdio MCP server per (service × account) pair, so routing is explicit:

- **Google** (`google-mcp`) — Gmail, Calendar, Meet, Drive, Docs, Sheets, Slides — one consolidated server per Google account
- **Slack** (`slack-mcp`) — one per workspace
- **Asana** (`asana-mcp`) — personal + work
- **Fathom** (`fathom-mcp`) — single instance

All launched via `~/.config/openbrain/lib/*-mcp.sh` wrappers that source `~/.config/openbrain/.env`.

### Keeping MCP servers current

- **Every launcher declares what it runs** in one line: `# openbrain-mcp: shape=fork|checkout|npm dir=<relative-to-root> …`. The launcher runs from that line (cloning and building on first launch if needed), and the update checker checks against it. A registered server with no declaration is reported, never guessed at.
- **Layout**: a relative `dir=`/`src=` is rooted at `root=` in `~/.config/openbrain/mcp-config` (default `~/Code`). `owner=` re-parents every declared `github.com/<owner>/<repo>` origin to your own fork/mirror; a per-MCP `<launcher>.url=`, `<launcher>.fork=`, `<launcher>.dir=`, or `<launcher>.branch=` overrides just that one server. All one-off machine choices — the tracked declaration always carries the upstream default.
- **Session start** runs a fast offline check and prints one line only when something needs attention (a stale build, uncommitted changes, a session still on an old build). **`/brain-update-check`** does the online check against GitHub and npm.
- **Update policy**, per server, in `~/.config/openbrain/mcp-config`: `ask` (default — report and offer, apply on your go) or `auto` (e.g. `google-mcp.update=auto` — `/brain-update-check` applies it when its tests pass). Every build from source must pass the server's tests and keeps the last good build if it fails. To revert a server, build an earlier commit in its checkout (`git checkout <sha> && npm ci --ignore-scripts && npm run build && git rev-parse HEAD > dist/.built-from`). The checker then reports it as `off-branch` (plus `source-behind` for a checkout, or `dist-stale` for a fork), and `auto` leaves it alone. To go forward again, run `git switch <branch>` in the checkout (`main`, or the branch it tracks; `local-build` for a fork), then `--apply` it. A plain npm server on the `stable` channel has no test gate — `auto` just moves it to the latest published version.
- **Channels** for npm servers whose source repo you also have: `stable` (the published package, default) or `canary` (run from the source checkout). Set per machine in the same file. A misspelled value stops that server from starting rather than being guessed at.
- **Restart Claude Code to apply** any update — running sessions keep the build they started with.

### Adding your own MCP

A server that isn't one of the supported services above runs through the same launcher, build and update machinery; you set it up by hand.

1. **Keep its source in a git repo**, on GitHub or local: `git init`, a `.gitignore` with `node_modules/` and `dist/`, and a commit on `main` (or declare `branch=`). It needs a `package.json` whose `build` script writes `dist/`; a `test` script, if present, gates every build. **Only committed code is built**: the build runs in its own clone, the `dist/.built-from` provenance stamp is the source's `HEAD`, and the update checks compare commits. After you commit a change, `/brain-update-check` reports it and `--apply` builds it.
2. **Write a launcher** at `.openbrain/lib/<name>-mcp.sh` with one declaration line:

   ```bash
   #!/usr/bin/env bash
   # openbrain-mcp: shape=checkout dir=my-mcp url=file:///path/to/my-mcp
   set -euo pipefail
   source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
   require_env MY_MCP_API_KEY
   export MY_MCP_API_KEY
   ensure_mcp_server
   exec node "$(declared_entry)"
   ```

   `dir=` is where the build clone lives (under `root=`, default `~/Code`), not your source folder. `url=` is `https://…` or `file:///absolute/path` to the repo (a space in that path is written `%20`: a declaration value can't contain spaces). Add `sub=packages/<pkg>` for a package inside a monorepo, and `entry=` when the built file isn't `dist/index.js` (it must stay under `dist/`). The grammar is in `.openbrain/lib/_mcp-decl.sh`; `fathom-mcp.sh` is a shipped launcher of the same shape.
3. **An absolute `file://` path works on one machine only.** Other machines that share this vault set `<name>-mcp.url=` in their own `~/.config/openbrain/mcp-config`. List the launcher in `.openbrain/template-ignore` to keep it out of template pushes.
4. **Secrets go in `~/.config/openbrain/.env`**, read with `require_env` + `export` as above. Never put them in the launcher or in its registration args (stored as plain text in `~/.claude.json`).
5. **Deploy and register it by hand.** `bash bootstrap/lib/register-mcps.sh` copies the launcher to `~/.config/openbrain/lib/`, but it only registers the supported services, so register yours yourself: `claude mcp add -s user <key> -- ~/.config/openbrain/lib/<name>-mcp.sh [args]`. **Don't pick a managed key:** `register-mcps.sh` deletes any entry named `fathom` or starting with `asana_`, `gmail_`, `gcal_`, `gmeet_`, `gdrive_`, `gslides_`, `gtasks_`, `mstodo_`, `google_` or `slack_` whose launcher is in that folder, and re-creates only the ones it knows.
6. **Restart Claude Code.** The first launch clones and builds it, and `/brain-update-check` covers it from then on.

---

## Design principles

- **Capture first, organize later.** Everything starts in `+ Inbox/`.
- **Atomic notes.** One idea per note. If it wants to split, split it.
- **Links over folders.** Structure comes from `[[wikilinks]]` and MOCs.
- **Never delete, always archive.** Move to `+ Archive/`, never `rm`.
- **Git is the sync layer.** No Obsidian Sync. Auto git sync (commit + push on stop, pull on start) is available as an opt-in during setup. Set `OPENBRAIN_AUTOPUSH=0` to keep auto-commits local-only (no push).
- **Skills are markdown procedures.** Claude reads them and performs the steps.
- **People are first-class entities.** Every person gets a note. Interactions link back. Cadence is tracked.
- **Multi-account by default.** Every external service is wired per-account with routing tags.

---

## Troubleshooting

See [`bootstrap/README.md`](bootstrap/README.md) for:
- Re-running parts of the wizard
- Google OAuth gotchas (admin-managed Workspace accounts, "unverified app" screens)
- Slack workspace admin approval
- Rotating tokens
- Removing an account

---

## Credits

Developed by [@davidianstyle](https://github.com/davidianstyle) as the portable template extracted from his personal OpenBrain vault.

The underlying LYT methodology is from [Nick Milo](https://www.linkingyourthinking.com/).
