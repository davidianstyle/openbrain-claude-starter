---
name: process-inbox
description: Triage + Inbox/ together with fresh items in Gmail and Slack across all accounts. Proposes classification per CLAUDE.md §4 and surfaces anything needing a reply.
---

# /process-inbox

Run the CLAUDE.md §4 inbox triage workflow across all sources.

## Procedure

> **Parallelization:** steps 1, 2, 3, and 4 are independent (vault read + all `google_*` + all `slack_*` + all calendars). Issue them all in a single tool-use block — do not loop serially through accounts.

1. **Vault inbox.** Read every `.md` file in `+ Inbox/`. For each, propose classification (atomic / literature / task / project kickoff / ephemeral) and destination, per CLAUDE.md §4.
2. **Gmail sweep.** For each `google_*` MCP, `google_gmail_search_emails` with `is:unread newer_than:1d` (+ `-category:promotions -category:social -label:notifications` to filter noise). Cap 10 per account. Group by account slug.
3. **Slack sweep.** For each `slack_*` MCP, fetch **two complementary sources** in the same parallel block:
   - `slack_conversations_unreads` with `limit: 200` — top-level unread channels and DMs. The `limit` param caps **channels scanned**, not unreads returned, so smaller values miss DMs in lower-priority channels.
   - `slack_my_mentions` with `hours: 24` — explicit `<@me>` mentions across channels and thread replies. **This is required**: `conversations_unreads` only checks each channel's top-level `unread_count` (from `conversations.info`), which excludes thread replies and mentions in channels you've already read. Without this call, @mentions in threads silently disappear.

   After fetching both, dedupe (a message may appear in both) and summarize the top 10 most relevant items.
4. **Calendar sweep — capture today's meetings.** For each `google_*` MCP, call `google_calendar_list_events` for today (midnight to now). Collect all events where:
   - The event has **already ended** (end time ≤ current time).
   - The event is **not** all-day, cancelled, or declined by the user.
   - The event has **at least one other attendee** (skip focus-time blocks, reminders, solo holds).

   Then deduplicate against existing interaction notes:
   - Glob `+ Atlas/Interactions/YYYY-MM-DD-*.md` for today's date.
   - For each calendar event, check whether an interaction note already exists with a matching `source:` frontmatter (calendar event ID or meeting link) or a slug that clearly matches the event title. Skip already-captured meetings.

   For each remaining (uncaptured) meeting, run `/capture-meeting` with the calendar event ID on the matching `google_*` MCP. Fan out transcript fetches in parallel per `/capture-meeting` step 1, but process meetings sequentially (each one may create people candidates that the next one should see).

   **Interactive vs. scheduled behavior:**
   - **Interactive:** list the meetings found and ask which to capture before proceeding. Shape: "Found N past meetings today not yet captured: [list]. Capture all / Select / Skip?"
   - **Scheduled:** auto-capture all without confirmation.
5. **Flag items needing a reply.** For each Gmail/Slack item, infer whether the user is the next actor (question addressed to them, explicit request, etc.). Surface those in a "Needs reply" section.
5b. **Draft replies for actionable threads.** For each item flagged in step 5 where the user is the next actor, invoke `/draft-follow-up` to produce the draft. `/draft-follow-up` is the single source of truth for drafting mechanics (account selection, writing-style application, save tool selection, vault trail). This skill only decides *which* items get drafted and handles batch gating; it does not inline the drafting logic.

   **Skip list** (do not invoke `/draft-follow-up` for these):
   - Delegated/FYI items (care team, ops auto-alerts)
   - Observer-only threads
   - Automated notifications (Asana digests, Dependabot, commercial mailing lists)

   **For each remaining actionable item:**
   1. Build the `/draft-follow-up` input: pass the gmail thread id (for email) or slack permalink (for Slack) as `$1`, and a one-line intent hint as `$2` derived from the thread.
   2. Invoke `/draft-follow-up`. It will resolve the account, pull person context, apply the §6 writing style, save the draft via the matching `gmail_draft_email` or `slack_drafts_create` tool, and log the vault trail under the person's `## Threads` section.
   3. Collect the returned draft id and account into this skill's "Drafted replies" output section.

   **Interactive vs. scheduled behavior:**
   - **Interactive (default):** before invoking `/draft-follow-up` for each item, show the proposed intent hint and ask for approval. Shape: "Draft this reply to [sender] re: [subject]? [Yes / Skip / Edit intent]"
   - **Scheduled:** invoke `/draft-follow-up` without confirmation (drafts are not sent, so this is safe — the user reviews and sends from Gmail/Slack).

   **Parallelization:** `/draft-follow-up` invocations across distinct threads are independent. Fan out all invocations in a single tool-use block per batch.
6. **People detection pass.** From senders/recipients of the Gmail sweep and counterparties of the Slack sweep, match identifiers against `+ Atlas/People/*.md` (`emails`, `slack`, `title`, `aliases`). Apply `/sync-people`'s noise filters (step 4) and its Bucket C staging threshold (step 7) verbatim — `/sync-people` is the single source of truth for these rules. Note that `/process-inbox` does not read calendar, so the "calendar event where the user is also an attendee" branch of the threshold is simply unavailable here; a Gmail thread where the unknown human directly replied to the user (or vice versa) counts as the Gmail equivalent of a direct meeting for threshold purposes.
   - In **interactive mode**: surface qualifying unknowns in a "People candidates" section — do not auto-stage.
   - In **scheduled mode**: stage a stub at `+ Inbox/people-candidates/<Full Name>.md` using `/sync-people`'s stub format (step 10), appending evidence if the stub already exists.
   Also triage any existing files in `+ Inbox/people-candidates/` — if they already look complete (relationship guessed, sufficient context), flag for promotion to `+ Atlas/People/` but do not move them automatically.
6b. **Auto-log interactions from email/Slack.** For each email or Slack message from a known person (matched in step 6), create a lightweight interaction note following `/sync-people` step 8 rules verbatim — include/exclude filters, interaction note format, dedup, and Threads updates all apply as written there. `/process-inbox` has no calendar data, so a Gmail thread where the sender directly replied to the user (or vice versa) counts as the equivalent high-signal trigger.

   **Slack mention handling (explicit).** The Slack sweep in step 3 returns two streams: DMs (from `slack_conversations_unreads`) and channel/thread `@mentions` of the user (from `slack_my_mentions`). **Both** feed step 6b — do not treat mentions as second-class.
   - For **DMs**: the counterparty is the other participant in the DM channel.
   - For **mentions**: the *sender* is the message's `user` field — the person who tagged the user, not the user themselves. Match against `+ Atlas/People/*.md` `slack:` array entries, formatted as `<workspace-slug>:<user_id>`. If the sender resolves to a known person, auto-log the channel mention as an interaction with `channel: slack` and `source: <slack permalink>`.

   Without this explicit walkthrough, mention senders get silently dropped because step 6's "counterparties of the Slack sweep" was historically read as DM-only.

   Interactive: propose and confirm. Scheduled: create automatically.
7. **Interactive vs. scheduled.**
   - **Interactive (default):** propose all moves/actions, wait for approval.
   - **Scheduled (`$1 == "scheduled"`):** act without confirmation when classification is unambiguous. Auto-push notes tagged `#asana/*` to the matching Asana MCP. Leave ambiguous items in `+ Inbox/` with `#needs-review` prepended.
8. When moving a note, update backlinks as CLAUDE.md §4 requires.
9. **Co-located resources.** When moving a note out of `+ Inbox/`, check whether a matching subfolder exists at `+ Inbox/.resources/<note title>/` (Obsidian Web Clipper and Local Images Plus store images there). If it does, move the contents to `+ Extras/Attachments/<note title>/` and update all image embed paths inside the note (`![[+ Inbox/.resources/…]]` → `![[+ Extras/Attachments/…]]`). Do NOT keep images in `.resources/` dotfolders outside of `+ Inbox/` — Obsidian's wikilink resolver does not index dotfolders, so `![[…]]` embeds will break.

## Output

A triage report with six sections:
- **Vault inbox** — per-note proposal (or action taken)
- **Meetings captured** — list of today's past meetings processed via `/capture-meeting`, with interaction note paths
- **Mail/Slack needing reply** — grouped by account
- **Drafted replies** — list of drafts saved, with account + draft ID
- **Interactions logged** — list of auto-created interaction notes from email/Slack
- **Auto-pushed to Asana** — only in scheduled mode

## Notes

- Never create Asana tasks from Gmail/Slack items directly — only from vault notes with `#asana/*` tags.
- Read-only toward Gmail/Slack; do not mark messages as read, archive, or label anything during this skill.
