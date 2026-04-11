---
name: process-inbox
description: Triage + Inbox/ together with fresh items in Gmail and Slack across all accounts. Proposes classification per CLAUDE.md §4 and surfaces anything needing a reply.
---

# /process-inbox

Run the CLAUDE.md §4 inbox triage workflow across all sources.

## Procedure

1. **Vault inbox.** Read every `.md` file in `+ Inbox/`. For each, propose classification (atomic / literature / task / project kickoff / ephemeral) and destination, per CLAUDE.md §4.
2. **Gmail sweep.** For each `gmail_*` MCP, `gmail_search_messages` with `is:unread newer_than:1d` (+ `-category:promotions -category:social -label:notifications` to filter noise). Cap 10 per account. Group by account slug.
3. **Slack sweep.** For each `slack_*` MCP, list unread DMs and `@mentions` in the last 24h. Cap 10 per workspace.
4. **Flag items needing a reply.** For each Gmail/Slack item, infer whether the user is the next actor (question addressed to him, explicit request, etc.). Surface those in a "Needs reply" section.
5. **People detection pass.** From senders/recipients of the Gmail sweep and counterparties of the Slack sweep, match identifiers against `+ Atlas/People/*.md` (`emails`, `slack`, `title`, `aliases`). Apply `/people-sync`'s noise filters (step 4) and its Bucket C staging threshold (step 7) verbatim — `/people-sync` is the single source of truth for these rules. Note that `/process-inbox` does not read calendar, so the "calendar event where the user is also an attendee" branch of the threshold is simply unavailable here; a Gmail thread where the unknown human directly replied to the user (or vice versa) counts as the Gmail equivalent of a direct meeting for threshold purposes.
   - In **interactive mode**: surface qualifying unknowns in a "People candidates" section — do not auto-stage.
   - In **scheduled mode**: stage a stub at `+ Inbox/people-candidates/<Full Name>.md` using `/people-sync`'s stub format (step 10), appending evidence if the stub already exists.
   Also triage any existing files in `+ Inbox/people-candidates/` — if they already look complete (relationship guessed, sufficient context), flag for promotion to `+ Atlas/People/` but do not move them automatically.
6. **Interactive vs. scheduled.**
   - **Interactive (default):** propose all moves/actions, wait for approval.
   - **Scheduled (`$1 == "scheduled"`):** act without confirmation when classification is unambiguous. Auto-push notes tagged `#asana/*` to the matching Asana MCP (per saved feedback `feedback_triage_auto_push.md`). Leave ambiguous items in `+ Inbox/` with `#needs-review` prepended.
6. When moving a note, update backlinks as CLAUDE.md §4 requires.
7. **Co-located resources.** When moving a note out of `+ Inbox/`, check whether a matching subfolder exists at `+ Inbox/.resources/<note title>/` (Obsidian Web Clipper and Local Images Plus store images there). If it does, move the contents to `+ Extras/Attachments/<note title>/` and update all image embed paths inside the note (`![[+ Inbox/.resources/…]]` → `![[+ Extras/Attachments/…]]`). Do NOT keep images in `.resources/` dotfolders outside of `+ Inbox/` — Obsidian's wikilink resolver does not index dotfolders, so `![[…]]` embeds will break.

## Output

A triage report with three sections:
- **Vault inbox** — per-note proposal (or action taken)
- **Mail/Slack needing reply** — grouped by account
- **Auto-pushed to Asana** — only in scheduled mode

## Notes

- Never create Asana tasks from Gmail/Slack items directly — only from vault notes with `#asana/*` tags.
- Read-only toward Gmail/Slack; do not mark messages as read, archive, or label anything during this skill.
