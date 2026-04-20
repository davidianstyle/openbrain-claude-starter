---
name: daily-brief
description: Produce today's daily briefing across all Google Calendars, Gmail accounts, Slack workspaces, and Asana. Writes to + Atlas/Daily/YYYY-MM-DD.md and surfaces anything that needs the user's attention today. Safe to re-run — refreshes the `## Morning brief` section in place.
---

# /daily-brief

Assemble the user's daily briefing for today (or a date passed as `$1`). Creates or updates the matching daily note in `+ Atlas/Daily/`. Re-runnable: the skill replaces the `## Morning brief` section in place rather than appending a new one.

## Inputs

- `$1` (optional): target date in `YYYY-MM-DD`. Defaults to today.

## Procedure

> **Date check first.** Before any other work, if `$1` is not supplied, resolve "today" by running `Bash: date "+%Y-%m-%d %A %H:%M %Z"`. Do **not** trust the session-injected `currentDate` field — it can lag the real clock by a day. Use the shell result as the target date for everything below.

> **Parallelization:** steps 1–6 are all independent read-only gathers. Fan out **every** MCP call — all `google_*` accounts, all `slack_*` workspaces, all configured Asana workspaces, and Fathom — in a single tool-use block. Do not serialize across accounts or across steps.

1. **Calendar sweep.** For each `google_*` MCP, call `google_calendar_list_events` for the target date (00:00 → 23:59 local). Merge into a single timeline; tag each event with the owning account slug. Collapse duplicate events that appear on multiple calendars (same title + time).
1b. **Fathom recordings.** Call `mcp__fathom__list_meetings` for meetings in the last 24h. For each, note title, participants, and whether a summary is available. Surface under a **Recent recordings** section in the brief — title, attendees, and a `fathom:<meeting-id>` reference the user can pass to `/capture-meeting` if they haven't already processed it.
2. **Priority mail.** For each `google_*` MCP, `google_gmail_search_emails` with `is:unread newer_than:2d (is:important OR is:starred OR label:^iim)`. Cap at 5 per account. Capture subject, sender, account slug.
3. **Slack attention.** For each `slack_*` MCP, search for mentions of the user in the last 24h and list unread DMs. Cap at 10 per workspace.
4. **Overdue tasks.** For each configured Asana workspace (`asana_personal`, `asana_work`), `asana_get_my_tasks` with `completed_since=now`, `opt_fields=name,due_on,due_at,completed,assignee_section.name,projects.name,permalink_url,recurrence`, and post-filter to due date < today. The `recurrence` field is mandatory — see "Asana display ordering" below for why.
5. **Stale relationships.** Grep `+ Atlas/People/*.md` for notes whose `last_contact` is older than their `cadence` allows (weekly: > 7d, monthly: > 30d, quarterly: > 90d, asneeded: never stale). Cap at 5.
6. **People detection pass.** From the calendar attendees + priority mail senders/recipients + Slack counterparties gathered in steps 1–3, check each identifier against `+ Atlas/People/*.md` frontmatter (`emails`, `slack`, `title`, `aliases`). Unknown humans (after filtering no-reply/bots/resources per `/people-sync` rules) become a **New faces** candidate list — do not stage stubs from this skill; just surface them. Recommend `/people-sync` if the list is non-empty.
6b. **Draft replies for actionable threads.** After steps 1–6, draft responses for "Needs a reply" items where the user is the next actor. Skip:
   - Items classified as `Delegated / FYI` (care team, ops auto-alerts)
   - Observer-only threads
   - Automated notifications (Asana digests, Dependabot, commercial mailing lists)

   For each actionable item:
   1. **Resolve account + thread.** Use the `google_*` MCP that surfaced the message (from step 2), or the `slack_*` workspace (from step 3).
   2. **Gather context.** Read the full thread via `google_gmail_read_email` on the matching `google_*` MCP (using the message ID from step 2). Check `+ Atlas/People/` for the sender's person note — pull open commitments, recent interactions, and relationship context. For Slack, read the thread via `slack_<slug>_conversations_replies`.
   3. **Compose draft.** Match the user's voice (see CLAUDE.md §6). Lead with the ask or the answer. For email: use `Re: <original subject>`. For Slack: no subject.
   4. **Save draft.**
      - **Email:** `google_gmail_draft_email` on the matching `google_*` MCP with `threadId` + `inReplyTo` set so it appears as an in-thread reply.
      - **Slack:** `mcp__claude_ai_Slack__slack_send_message_draft` with `channel_id` + `thread_ts` if replying in-thread. (This is the one approved use of the deprecated connector — see CLAUDE.md §9.)
   5. **Log vault trail.** If the sender resolved to a person note, append a bullet under its `## Threads` section: `- <date> · drafted follow-up (<channel>:<draft-id>) — <one-line gist>`. Do NOT update `last_contact` — a draft is not a touchpoint.

   **Parallelization:** fan out all `google_gmail_read_email` / thread-read calls in one tool-use block, then fan out all `google_gmail_draft_email` / `slack_send_message_draft` calls in the next block.

7. **Compose the daily note.** If `+ Atlas/Daily/<date>.md` does not exist, scaffold from `+ Extras/Templates/Daily.md`. If a `## Morning brief` section already exists in the note, **replace its body in place** (find the `## Morning brief` heading and overwrite everything up to the next H2 or EOF). Otherwise insert a new `## Morning brief` section near the top. Contents:
   - **Today's calendar** (merged timeline, grouped bullet list, `[HH:MM–HH:MM] Title · account-slug · other attendees if any`)
   - **Recent recordings** (Fathom meetings from last 24h not yet captured as interaction notes — title, attendees, `fathom:<id>` ref; omit section if empty)
   - **Needs a reply** (mail + slack, grouped by account/workspace)
   - **Drafted replies** — list of drafts saved in step 6b. One bullet per draft: `- ✉️ [[Person]] — Re: Subject · gmail draft <draft-id> · <account>` (or `💬` for Slack). Include a footer: `_(Review and send from Gmail / Slack. Drafts are not sent automatically.)_`. Omit the section if no drafts were generated (all items were delegated/FYI).
   - **Overdue in Asana**
   - **People past cadence** (link with `[[wikilinks]]`)
   - **New faces** — unknown humans seen in today's activity, one line each with source context. Omit the section if empty.
   - A single-line **Focus suggestion** based on the above
8. Never touch any other section of the daily note. Only the `## Morning brief` section is managed by this skill.
9. **Refresh `Dashboard.md` at the vault root.** This skill is the primary owner of the dashboard and rebuilds it on every run, since it already has all the data in hand. Only run this step when the target date is **today** — historical reruns must not retroactively rewrite the dashboard. Procedure:
   - For each H2 section in `Dashboard.md` listed below, **replace the body in place** (find the heading and overwrite everything up to the next H2 or EOF). Do not create the file from scratch — if `Dashboard.md` is missing, log a warning and skip step 9. Never touch `## Quick links` (static) or sections owned by `/daily-review` and `/weekly-review` (see below).
   - **Owned by `/daily-brief`** (rebuild every run):
     - `## Today — <Day YYYY-MM-DD>` — pivot meeting + 5–8 line condensed timeline of today's anchors. Update the heading date too.
     - `## Needs a reply / open loops` — same data as the brief's "Needs a reply" section, but formatted as one bullet per item with `[[wikilinks]]`. Filter out delegated/FYI noise.
     - `## People past cadence` — same content as the brief's section.
     - `## Delegated / FYI` — auto-alerts and FYI items surfaced today that the user does not need to action.
   - **Owned by `/weekly-review`** (only refresh if the section is missing or older than 7 days — otherwise leave alone): `## This week (...)`, `## Top priorities`. To detect age, compare the dashboard's frontmatter `updated:` field against today; if `updated >= start-of-week`, leave these sections alone. If they need refreshing and `/weekly-review` hasn't run yet, generate a "stub" version from current Asana + calendar data so the dashboard isn't stale.
   - **Frontmatter.** Update the `updated:` field to `<today>` after writing.
   - **Idempotence.** Re-running `/daily-brief` on the same day must produce the same dashboard (modulo any new mail/slack/calendar deltas). Never append; always replace section bodies in place.

## Output shape

Create or refresh the `## Morning brief` section in `+ Atlas/Daily/<date>.md`, plus the dashboard sections owned by this skill in `Dashboard.md` (see step 9). Report a short summary of what was (re)generated to the user in chat — including the dashboard refresh status.

## Asana scope note

Step 4 ("Overdue tasks") is for the brief itself. For the dashboard's `## Top priorities` stub generation in step 9, widen the Asana query to include tasks with `due_on` between today and today + 7 days, grouped by workspace. Use the same `asana_get_my_tasks` call — just don't post-filter to `< today`.

## Asana display ordering

Whenever this skill renders a flat list of Asana tasks (in the `Overdue in Asana` section of the brief, the `## Today` must-do block of the dashboard, or the `## Top priorities` lists), **group by repeat frequency** with subheadings and sort least-frequent → most-frequent so high-stakes items bubble to the top.

**Source of truth: the Asana `recurrence.type` field. Never guess from the task name.** Heuristics are unreliable — task titles rarely encode their repeat cadence.

**Required opt_fields.** When this skill issues `asana_get_my_tasks` (step 4) or any task fetch that will feed into a display list, **`recurrence` MUST be in `opt_fields`**. Standard fetches don't return it. The recommended opt_fields string for this skill: `name,due_on,due_at,completed,assignee_section.name,projects.name,permalink_url,recurrence`.

**`recurrence.type` → display group mapping:**

| `recurrence.type` | Display group | Order |
|---|---|---|
| `never` | **One-off** | 1 (highest priority) |
| `yearly` | **Annually** | 2 |
| `monthly` | **Monthly** | 3 |
| `weekly` | **Weekly** | 4 |
| `daily` | **Daily** | 5 (collapsed at bottom) |

If `recurrence` is missing from a task response (e.g. an API error or older field set), treat as `never` and flag the task with a `?` so the user can verify.

Within each group, secondary sort by `due_on` ascending. Omit empty groups. Render group labels as bold inline labels (`**One-off**`, `**Annually**`, etc.) — do NOT use H3 since these live inside an H2 section. This grouping is the **default** behavior when no explicit alternative sort is in effect.

## Notes

- **Idempotent by design.** Running `/daily-brief` twice on the same date replaces the section rather than duplicating it. The section header stays `## Morning brief` (the name reflects content intent, not the time of day the skill was invoked).
- Never **send** any email or Slack message — this skill creates drafts only (step 6b). Drafts are not sent; the user reviews and sends from the native client.
- If a given MCP server fails, note it in the brief (`_(google_<slug>: unavailable)_`) and continue.
- Respect the `#workspace/personal` vs `#workspace/work` split only if the user asks for a single-workspace brief (e.g. `/daily-brief work` → skip all `workspace=personal` sources). Without a flag, include everything.
