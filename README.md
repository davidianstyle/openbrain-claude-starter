# OpenBrain

**A personal AI Chief of Staff in an Obsidian vault, managed by Claude Code.**

OpenBrain is a portable template for a [Linking Your Thinking](https://www.linkingyourthinking.com/) (LYT) knowledge base that doubles as an operating layer for [Claude Code](https://claude.com/claude-code). Clone it, run one setup script, and you get:

- A fully scaffolded Obsidian vault (Inbox, Spaces, Atlas, Sources, Templates)
- 21 pre-built Chief of Staff [skills](#skills) (daily brief, inbox triage, capture meeting, etc.)
- Multi-account MCP wiring for Gmail, Google Calendar, Google Meet, Google Drive/Docs/Sheets, Slack, Asana, and Fathom — any number of accounts per service
- Automatic git sync via Claude Code Stop/SessionStart hooks
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

---

## Install

```bash
git clone https://github.com/davidianstyle/openbrain-template.git ~/OpenBrain
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
7. Wire Stop + SessionStart git-sync hooks
8. Validate the install

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
├── Home.md                   # front door with auto-regenerated MOC index
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
| `/follow-up-draft` | Draft a reply email/Slack message (never sends) |
| `/what-am-i-missing` | Surface overdue tasks, cadence misses, unanswered mail |
| `/people-audit` | Cadence health report + regenerate People MOC |
| `/people-sync` | Discovery pass across Gmail/Calendar/Slack to find unknown people |
| `/weekly-review` | Monday synthesis |
| `/push-openbrain-template` | Genericize vault improvements and open a PR against the template repo |
| `/pull-openbrain-template` | Pull latest template changes into the vault interactively |
| `/asana` | Quick view of upcoming Asana tasks with interactive check-off |

Skills are markdown procedures — Claude reads the SKILL.md and performs the steps. No code execution.

### Supported MCP servers

One stdio MCP server per (service × account) pair, so routing is explicit:

- **Google** (`google-mcp`) — Gmail, Calendar, Meet, Drive, Docs, Sheets, Slides — one consolidated server per Google account
- **Slack** (`slack-mcp`) — one per workspace
- **Asana** (`asana-mcp`) — personal + work
- **Fathom** (`fathom-mcp`) — single instance

All launched via `~/.config/openbrain/lib/*-mcp.sh` wrappers that source `~/.config/openbrain/.env`.

---

## Design principles

- **Capture first, organize later.** Everything starts in `+ Inbox/`.
- **Atomic notes.** One idea per note. If it wants to split, split it.
- **Links over folders.** Structure comes from `[[wikilinks]]` and MOCs.
- **Never delete, always archive.** Move to `+ Archive/`, never `rm`.
- **Git is the sync layer.** No Obsidian Sync. The Stop hook auto-commits and pushes.
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
