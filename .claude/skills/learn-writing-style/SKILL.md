---
name: learn-writing-style
description: Scan sent messages across configured Google and Slack accounts to derive a personalized writing-style profile (email vs Slack, by audience size), then update CLAUDE.md §6 in place. Run after initial bootstrap or anytime you want to refresh.
---

# /learn-writing-style

Derive your writing-style profile from your real outbound messages and write it into `CLAUDE.md §6`. The drafter skills (`/follow-up-draft`, `/daily-brief`, `/process-inbox`) read §6 as the source of truth, so updating §6 propagates automatically.

This skill is interactive: it shows the derived profile and waits for confirmation before writing.

## Inputs

- `$1` (optional): sample size per channel (default `100`; clamped 30–500). Larger samples yield more stable patterns at the cost of longer runtime.
- `$2` (optional): `--dry-run` — compute and show the profile but skip the file write.

## Procedure

> **Date check first.** Run `Bash: date "+%Y-%m-%d"` to anchor "recent" before any other work.

### 1. Inventory channels

From CLAUDE.md §11, list configured `google_*` accounts and `slack_*` workspaces. Skip any whose MCP server is unreachable; note skipped channels in the final report.

### 2. Sample sent email — per Google account, in parallel

For each `google_*` MCP, fan out:

- `gmail_search_emails` with query `in:sent newer_than:90d`, capped at `$1` results.
- For each match, `gmail_read_email` to retrieve the full body.

Strip quoted reply-history (lines beginning with `>` or below `On <date>, <person> wrote:`) before analyzing — only the user's own freshly-typed text counts.

### 3. Sample sent Slack — per workspace, in parallel

For each `slack_*` MCP, fan out:

- `slack_conversations_search_messages` with query `from:<self> after:<today minus 90 days>`, capped at `$1`.
- For each match, capture: channel id, channel type (`im` / `mpim` / `private_channel` / `public_channel`), thread-position (top-level vs reply), and message body.

### 4. Classify Slack samples by audience size

- **Small audience:** DMs (`im`), group DMs (`mpim`), and any thread reply in any channel.
- **Large audience:** top-level posts in public channels with `num_members > 20`, OR any channel name matching common broadcast patterns (`announce`, `general`, `all-`, `company-`).
- **Medium:** everything else. If the small or large bucket has fewer than 10 samples, fold the medium bucket into the smaller bucket to stabilize the analysis.

### 5. Analyze each bucket

Compute these markers per bucket (email, slack-small, slack-large):

- **Length:** median and p90 word count.
- **Capitalization:** % of messages whose first character is an uppercase letter.
- **Sentence form:** % of messages ending in `.`, `?`, or `!`.
- **Sign-off (email only):** parse the last 1–2 non-empty lines; cluster by closer pattern (`Best, <name>`, `Thanks, <name>`, `Cheers, <name>`, first-name-only, no-closer). Report top 3 with frequency.
- **Greeting (email only):** parse the first non-empty line above the body; cluster as in sign-off (`Hi <name>,`, `Hey <name>,`, `<name>,`, no-greeting).
- **Em-dash usage:** count `—` per 100 messages. If 0, treat as a hard "never use" rule.
- **Markdown usage (Slack only):** count messages using `*bold*`, `_italic_`, backtick code, bullet/list markers. Report % of messages using each.
- **Paragraph format (email only):** % of messages where every paragraph is one unbroken line vs % with hard wraps mid-paragraph.

### 6. Compose the profile draft

Render results in `CLAUDE.md §6` shape. The exact bullet structure must match what's already there so re-runs are clean overwrites:

```markdown
## 6. Writing assistant guidance

- **Drafting voice (general):** {{summarized: e.g. "direct and terse, ~M words median per message" or "complete sentences, friendly register"}}.
- **Em-dashes:** {{if count ≈ 0: "Never use em-dashes (`—`) in any drafted communication. Substitute a colon, hyphen, parentheses, or split the sentence."}} {{else: "Em-dashes appear ~K per 100 messages; use sparingly and only when natural."}}
- **Email style:** {{capitalization observation}}; {{sentence form observation}}; sign off with `{{top closer}}` ({{top-closer frequency}}; alternates: {{closer #2}}, {{closer #3}}); {{greeting observation}}; {{paragraph format observation, including the Gmail hard-break caveat if single-line is dominant}}.
- **Slack style — small audiences (DMs, group DMs, thread replies):** {{tone summary}}; {{capitalization}}; {{markdown habits}}; {{length}}.
- **Slack style — large audiences (broadcast channels, announcements):** {{tone summary}}; {{markdown habits}}; {{length}}.
- **Expanding stubs:** if a note is a one-liner or has `#stub`, offer to expand it using linked context and related notes.
- **Surfacing related notes:** use Grep / wikilink search across `+ Atlas/` and `+ Spaces/` to find genuinely relevant prior thinking before writing anything new.
- **Never invent facts** or create fake citations. If you need a source, say so.

_Generated by `/learn-writing-style` on YYYY-MM-DD from N email + M Slack samples. Re-run to refresh._
```

### 7. Show the profile inline and confirm

Print the proposed §6 body in chat, plus per-channel sample counts. Ask via `AskUserQuestion`:

- **Apply** — overwrite §6 with the new profile.
- **Let me adjust** — accept user edits, then apply.
- **Cancel** — discard.

### 8. Write on confirmation

Replace the body of `## 6. Writing assistant guidance` in `CLAUDE.md` (overwrite from the heading to the next H2 or EOF). Preserve the section header and everything else in the file. Do **not** append.

If `$2` is `--dry-run`, skip step 8 entirely.

### 9. Update memory

If your auto-memory directory contains a writing-style entry, refresh it to mirror the new §6 profile, citing CLAUDE.md §6 as the source of truth.

### 10. Report

Print:
- Path to `CLAUDE.md`
- Sample counts per channel and per bucket
- Channels skipped due to insufficient data (< 5 samples)
- Footer freshness line

## Notes

- **Insufficient data per channel:** if a channel returns fewer than 5 valid samples, skip it. Note in the profile that this channel was not learned (use the template default for that bullet).
- **PII:** the skill reads only the user's own sent messages and computes aggregate statistics. Sample bodies are not stored in the vault — only the derived profile.
- **Idempotent:** re-running replaces §6 in place. The footer line tracks freshness.
- **Bootstrap recommendation:** new users should run `/learn-writing-style` once after `bootstrap/setup.sh` completes and at least one Google account + one Slack workspace are configured. Until then, §6 carries the template defaults shipped with the starter.
- **Scope:** only generates the four user-style bullets (general voice, em-dashes, email, Slack-small, Slack-large). The "expanding stubs", "surfacing related notes", and "never invent facts" bullets are template defaults; the skill leaves them alone.
- **Matching the §6 footer convention:** every run leaves a `_Generated by /learn-writing-style on YYYY-MM-DD from N email + M Slack samples._` line at the bottom of §6 so future readers know the section is auto-derived and how fresh it is.
