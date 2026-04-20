---
name: process-inbox
description: Triage + Inbox/ together with fresh items in Gmail and Slack across all accounts. Proposes classification per CLAUDE.md §4 and surfaces anything needing a reply.
---

# /process-inbox

Run the CLAUDE.md §4 inbox triage workflow across all sources.

## Procedure

> **Parallelization:** steps 1, 2, and 3 are independent (vault read + all `google_*` + all `slack_*`). Issue them all in a single tool-use block — do not loop serially through accounts.

1. **Vault inbox.** Read every `.md` file in `+ Inbox/`. For each, propose classification (atomic / literature / task / project kickoff / ephemeral) and destination, per CLAUDE.md §4.
2. **Gmail sweep.** For each `google_*` MCP, `gmail_search_emails` with `is:unread newer_than:1d` (+ `-category:promotions -category:social -label:notifications` to filter noise). Cap 10 per account. Group by account slug.
3. **Slack sweep.** For each `slack_*` MCP, list unread DMs and `@mentions` in the last 24h. Cap 10 per workspace.
4. **Flag items needing a reply.** For each Gmail/Slack item, infer whether the user is the next actor (question addressed to them, explicit request, etc.). Surface those in a "Needs reply" section.
4b. **Draft replies for actionable threads.** For each item flagged in step 4 where the user is the next actor, draft a response and save it to the native client. Skip:
   - Delegated/FYI items (care team, ops auto-alerts)
   - Observer-only threads
   - Automated notifications (Asana digests, Dependabot, commercial mailing lists)

   For each actionable item:
   1. **Resolve account + thread.** Use the `google_*` MCP that surfaced the message, or the `slack_*` workspace.
   2. **Gather context.** Read the full thread via `gmail_read_email` on the matching `google_*` MCP (using the message ID from step 2). Check `+ Atlas/People/` for the sender's person note — pull open commitments, recent interactions, and relationship context. For Slack, read the thread via `slack_<slug>_conversations_replies`.
   3. **Compose draft.** Match the user's voice (see CLAUDE.md §6). Lead with the ask or the answer. For email: use `Re: <original subject>`. For Slack: no subject.
   4. **Save draft.**
      - **Email:** `gmail_draft_email` on the matching `google_*` MCP with `threadId` + `inReplyTo` set so it appears as an in-thread reply.
      - **Slack:** `mcp__claude_ai_Slack__slack_send_message_draft` with `channel_id` + `thread_ts` if replying in-thread. (This is the one approved use of the deprecated connector — see CLAUDE.md §9.)
   5. **Log vault trail.** If the sender resolved to a person note, append a bullet under its `## Threads` section: `- <date> · drafted follow-up (<channel>:<draft-id>) — <one-line gist>`. Do NOT update `last_contact`.

   **Interactive vs. scheduled behavior:**
   - **Interactive (default):** show each proposed draft and ask for approval before saving. Shape: "Draft this reply to [sender] re: [subject]? [Yes / Skip / Edit intent]"
   - **Scheduled:** auto-draft without confirmation (drafts are not sent, so this is safe — the user reviews and sends from Gmail/Slack).

   **Parallelization:** fan out all `gmail_read_email` / thread-read calls in one block, then fan out all `gmail_draft_email` / `slack_send_message_draft` calls in the next block.

5. **People detection pass.** From senders/recipients of the Gmail sweep and counterparties of the Slack sweep, match identifiers against `+ Atlas/People/*.md` (`emails`, `slack`, `title`, `aliases`). Apply `/people-sync`'s noise filters (step 4) and its Bucket C staging threshold (step 7) verbatim — `/people-sync` is the single source of truth for these rules. Note that `/process-inbox` does not read calendar, so the "calendar event where the user is also an attendee" branch of the threshold is simply unavailable here; a Gmail thread where the unknown human directly replied to the user (or vice versa) counts as the Gmail equivalent of a direct meeting for threshold purposes.
   - In **interactive mode**: surface qualifying unknowns in a "People candidates" section — do not auto-stage.
   - In **scheduled mode**: stage a stub at `+ Inbox/people-candidates/<Full Name>.md` using `/people-sync`'s stub format (step 10), appending evidence if the stub already exists.
   Also triage any existing files in `+ Inbox/people-candidates/` — if they already look complete (relationship guessed, sufficient context), flag for promotion to `+ Atlas/People/` but do not move them automatically.
5b. **Auto-log interactions from email/Slack.** For each email or Slack message from a known person (matched in step 5), create a lightweight interaction note following `/people-sync` step 8 rules verbatim — include/exclude filters, interaction note format, dedup, and Threads updates all apply as written there. `/process-inbox` has no calendar data, so a Gmail thread where the sender directly replied to the user (or vice versa) counts as the equivalent high-signal trigger. Interactive: propose and confirm. Scheduled: create automatically.
6. **Interactive vs. scheduled.**
   - **Interactive (default):** propose all moves/actions, wait for approval.
   - **Scheduled (`$1 == "scheduled"`):** act without confirmation when classification is unambiguous. Auto-push notes tagged `#asana/*` to the matching Asana MCP (per saved feedback `feedback_triage_auto_push.md`). Leave ambiguous items in `+ Inbox/` with `#needs-review` prepended.
6. When moving a note, update backlinks as CLAUDE.md §4 requires.
7. **Co-located resources.** When moving a note out of `+ Inbox/`, check whether a matching subfolder exists at `+ Inbox/.resources/<note title>/` (Obsidian Web Clipper and Local Images Plus store images there). If it does, move the contents to `+ Extras/Attachments/<note title>/` and update all image embed paths inside the note (`![[+ Inbox/.resources/…]]` → `![[+ Extras/Attachments/…]]`). Do NOT keep images in `.resources/` dotfolders outside of `+ Inbox/` — Obsidian's wikilink resolver does not index dotfolders, so `![[…]]` embeds will break.

## Output

A triage report with five sections:
- **Vault inbox** — per-note proposal (or action taken)
- **Mail/Slack needing reply** — grouped by account
- **Drafted replies** — list of drafts saved, with account + draft ID
- **Interactions logged** — list of auto-created interaction notes from email/Slack
- **Auto-pushed to Asana** — only in scheduled mode

## Notes

- Never create Asana tasks from Gmail/Slack items directly — only from vault notes with `#asana/*` tags.
- Read-only toward Gmail/Slack; do not mark messages as read, archive, or label anything during this skill.
