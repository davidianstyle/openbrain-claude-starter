---
name: daily-review
description: End-of-day (or any-time) reconciliation — compare today's plan against what actually got done, interactively check off Asana tasks, surface outstanding follow-ups, summarize for review, then update OpenBrain and Asana (mark complete, create tasks, adjust due dates). Safe to re-run — refreshes the `## Evening review` section in place.
---

# /daily-review

Reconcile the user's plan against reality, interactively resolve open items, and push updates to Asana and the vault. Typically run at end of day, but re-runnable at any time — the skill replaces the `## Evening review` section in place rather than appending a new one.

This skill is **interactive by design**. Ask clarifying questions with `AskUserQuestion` whenever status is ambiguous. Never mark a task complete or change a due date without explicit confirmation.

## Inputs

- `$1` (optional): target date in `YYYY-MM-DD`. Defaults to today.

## Procedure

> **Date check first.** Before loading anything, if `$1` is not supplied, resolve "today" by running `Bash: date "+%Y-%m-%d %A %H:%M %Z"`. Do **not** trust the session-injected `currentDate` field — it can lag the real clock by a day. Use the shell result as the target date.

### 1. Load the day's plan

- Read `+ Atlas/Daily/<date>.md`. If missing, tell the user and stop — there's nothing to reconcile against.
- Extract the `## Morning brief` section (or whatever plan the user wrote manually). Note:
  - Scheduled calendar events
  - "Overdue in Asana" list
  - "Needs a reply" items
  - "People past cadence" list
  - Any `Focus suggestion` or manual TODOs the user added during the day
- Also read any notes the user added under other H2 sections today (e.g. `## Notes`, `## Log`) for completion signals he may have already written down.

### 2. Pull actual activity for the day

Gather evidence of what actually happened, independent of what was planned. **Every bullet below is independent — fan out all Asana / google / slack / git / glob calls in a single tool-use block. Do not serialize.**

- **Asana churn (check completions first).** For both `asana_personal` and `asana_work`:
  - `asana_search_tasks` with `completed_on=<date>` → tasks the user already marked complete today. These are **pre-confirmed Done** — they skip the interactive loop entirely.
  - `asana_get_my_tasks` for currently assigned, incomplete tasks (to get the live outstanding list). Only tasks still incomplete here are candidates for the interactive check-off in step 4.
- **Calendar reality.** For each `google_*` MCP, `google_calendar_list_events` for the date. Compare to the morning brief's planned timeline — flag events that were added, moved, or canceled after the brief was written.
- **Mail sent.** For each `google_*` MCP, `google_gmail_search_emails` with `in:sent after:<date> before:<date+1>`. Used only to confirm whether "needs a reply" items got handled.
- **Slack sent.** For each `slack_*` MCP, use `conversations_search_messages` scoped to the user's user for the day if available, otherwise skip — this is best-effort confirmation only.
- **Vault activity.** `git log --since="<date> 00:00" --until="<date> 23:59" --name-only` from the repo root to see which notes were touched today. Filter out auto-commit noise.
- **Interaction notes created today.** Glob `+ Atlas/Interactions/<date>-*.md` — these represent meetings/calls that actually happened.

### 3. Reconcile plan vs. reality

Build an internal ledger with these buckets:

- **Done** — plan items with clear evidence of completion (Asana completed, interaction note written, sent mail matching the thread, git commit touching the expected file).
- **Outstanding** — plan items with no completion evidence.
- **Unplanned but done** — activity that happened today and wasn't on the plan (completed Asana tasks not in the morning brief, new interaction notes, mail sent on threads not flagged as "needs a reply"). Surface these so credit is given.
- **Ambiguous** — items where you genuinely can't tell. These need clarifying questions.

Also walk `+ Atlas/Interactions/<date>-*.md` and any person notes touched today for `## Open commitments (mine)` bullets added today — those are new follow-ups the user owes, and they belong in the outstanding list even if they weren't on the morning plan.

### 4. Interactive check-off (the main loop)

Asana tasks that were already marked complete (from step 2) go straight into the Done bucket — do not ask the user about them again. For each remaining **Outstanding** item, prompt the user one at a time using `AskUserQuestion`. Batch related items into a single question when possible (multiple small Asana tasks with similar options). Typical question shape:

- Subject: the item in 1 line (task name, or "Reply to <sender> re: <subject>")
- Options: `Done`, `Still open — keep as-is`, `Reschedule`, `Drop it`, `Other (explain)`
- For Asana tasks specifically, also offer `Done — with note` so he can add a completion comment.

For **Ambiguous** items, ask a clarifying question before deciding.

For **Unplanned but done** items, confirm once as a group: "Credit these to today? [yes / adjust]" — the user may want to retitle or move some.

For **new commitments surfaced from today's interactions** (from step 3), ask whether each should become an Asana task (and if so, which workspace + due date) or just stay tracked in the person note.

### 5. Summarize before writing

Before mutating anything, show the user a single consolidated summary:

- **To mark complete in Asana:** list (workspace + task name + gid)
- **To create in Asana:** list (workspace + title + proposed due date + source)
- **To reschedule in Asana:** list (task + old due → new due)
- **To update in OpenBrain:**
  - Daily note `## Evening review` section to create or refresh in place
  - Person notes losing "open commitment" bullets that are now done
  - Any interaction notes needing a status update
- **Dropped:** items being abandoned (so the user sees them one last time)

Ask for final confirmation: `Apply all of the above? [yes / let me adjust / cancel]`. On "let me adjust", loop back to step 4 for the specific items flagged.

### 6. Apply updates

Only after confirmation:

- **Asana — mark complete.** For each confirmed done task, `asana_update_task` with `completed: true` on the correct workspace MCP (`asana_work` vs `asana_personal`). If the user provided a completion note, also `asana_create_task_story` with that comment before closing.
- **Asana — create new.** `asana_create_task` on the correct workspace with title, due date, and a `notes` field linking back to the source (interaction note path or person name). Write the returned `gid` + `workspace` back into frontmatter of any corresponding vault note per CLAUDE.md §5.
- **Asana — reschedule.** `asana_update_task` with the new `due_on`.
- **Daily note.** Update `+ Atlas/Daily/<date>.md`: if a `## Evening review` section already exists, **replace its body in place** (find the `## Evening review` heading and overwrite everything up to the next H2 or EOF); otherwise append a new section. Shape:

  ```markdown
  ## Evening review

  **Done today**
  - …

  **Unplanned wins**
  - …

  **Carried forward**
  - …

  **Dropped**
  - …

  **New follow-ups**
  - … (with `[[links]]` to any created tasks or person notes)
  ```

  Never touch the `## Morning brief` section or any other part of the daily note — only the `## Evening review` section is managed here. Mapping from the step 3 buckets: Done → **Done today**; Outstanding → **Carried forward** or **Dropped** (based on step 4 answers); Unplanned but done → **Unplanned wins**; new commitments confirmed as Asana tasks → **New follow-ups**.
- **Person notes.** For commitments that were resolved, tick the checkbox (`- [ ]` → `- [x]`) in the relevant `## Open commitments` section. Do not delete — the checked history is useful. Update `last_contact` only if a new interaction happened today that isn't already reflected.
- **Interaction notes.** If a meeting produced a commitment that became an Asana task, add a line under the interaction's commitments section pointing to the new task's vault note or Asana gid.
- **Dashboard.** Refresh the open-loops view in `Dashboard.md` at the vault root so it reflects the post-review state. Only run this when the target date is **today** — historical reruns must not retroactively rewrite the dashboard. If `Dashboard.md` is missing, log a warning and skip. Replace section bodies in place (find heading → overwrite to next H2 or EOF):
  - `## Needs a reply / open loops` — drop items the user just confirmed as Done; keep Outstanding/Carried-forward items; add any New follow-ups that became Asana tasks today.
  - `## Today — <Day YYYY-MM-DD>` — replace the "Pivot" line with a brief end-of-day status (e.g. `**Wrapped:** 7 done, 3 carried, 2 new`) and trim the timeline to events that have already occurred. The next morning's `/daily-brief` run will rebuild this section fully.
  - Update the frontmatter `updated:` field to today.
  - Never touch `## This week`, `## Top priorities`, or `## Quick links` — those are owned by `/weekly-review` and `/daily-brief`. If `Dashboard.md` is missing, log a warning and skip this step.

### 7. Final report

Report back in chat:

- One-line headline (e.g. "Closed 7 tasks, carried 3, created 2 new.")
- Path to the updated daily note
- Any Asana gids created, with workspace
- Anything deferred because the user chose "let me adjust" and didn't resolve

## Notes

- **Asana display ordering.** Whenever this skill renders a flat list of Asana tasks (Outstanding bucket, summary, dashboard updates), group by repeat frequency and sort least-frequent → most-frequent so high-stakes items bubble to the top: **One-off → Annually → Monthly → Weekly → Daily**. **Source of truth: the Asana `recurrence.type` field — never guess from the task name.** When fetching tasks via `asana_get_my_tasks` or `asana_search_tasks`, **`recurrence` MUST be in `opt_fields`** (it's not returned by default). Mapping: `never`→One-off, `yearly`→Annually, `monthly`→Monthly, `weekly`→Weekly, `daily`→Daily. If `recurrence` is missing on a task, treat as `never` and flag with `?`. Within each group, secondary sort by `due_on` ascending. Omit empty groups. This is the default — skip it only when an explicit alternative sort is in effect (e.g. when the user asks for date-only sorting).
- **Never** mark a task complete, create a task, or change a due date without explicit per-item confirmation (batched confirmations are fine, silent ones are not).
- **Never** send mail or Slack messages from this skill. If the user wants to send a reply, hand off to `/follow-up-draft`.
- Follow CLAUDE.md §5 Asana routing rules strictly: `#asana/work` → `asana_work`, `#asana/personal` → `asana_personal`, never the deprecated `claude_ai_Asana` tools.
- **Idempotent by design.** Running `/daily-review` twice on the same date refreshes the `## Evening review` section rather than duplicating it. If you're mid-day and want a partial reconciliation, that's fine — run it now and again at end of day.
- If the user ran `/daily-review` for a past date (not today), still allow writes, but double-confirm any Asana `due_on` changes since rescheduling historical tasks is easy to do by accident.
- If `+ Atlas/Daily/<date>.md` has no `## Morning brief` (the user skipped the morning), treat everything from step 2 as "unplanned" and still run the reconciliation — it becomes a pure "what got done today" pass.
- Budget clarifying questions: don't ask more than ~8 in a single run. If there are more ambiguous items, group them or ask the user to prioritize which to resolve now.
