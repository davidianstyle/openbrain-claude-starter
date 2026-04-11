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

Gather evidence of what actually happened, independent of what was planned:

- **Asana churn.** For both `asana_personal` and `asana_work`:
  - `asana_search_tasks` with `completed_on=<date>` → tasks completed today.
  - `asana_get_my_tasks` for currently assigned, incomplete tasks (to get the live outstanding list).
- **Calendar reality.** For each `gcal_*` MCP, `gcal_list_events` for the date. Compare to the morning brief's planned timeline — flag events that were added, moved, or canceled after the brief was written.
- **Mail sent.** For each `gmail_*` MCP, `gmail_search_messages` with `in:sent after:<date> before:<date+1>`. Used only to confirm whether "needs a reply" items got handled.
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

For each **Outstanding** item, prompt the user one at a time using `AskUserQuestion`. Batch related items into a single question when possible (multiple small Asana tasks with similar options). Typical question shape:

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

### 7. Final report

Report back in chat:

- One-line headline (e.g. "Closed 7 tasks, carried 3, created 2 new.")
- Path to the updated daily note
- Any Asana gids created, with workspace
- Anything deferred because the user chose "let me adjust" and didn't resolve

## Notes

- **Never** mark a task complete, create a task, or change a due date without explicit per-item confirmation (batched confirmations are fine, silent ones are not).
- **Never** send mail or Slack messages from this skill. If the user wants to send a reply, hand off to `/follow-up-draft`.
- Follow CLAUDE.md §5 Asana routing rules strictly: `#asana/work` → `asana_work`, `#asana/personal` → `asana_personal`, never the deprecated `claude_ai_Asana` tools.
- **Idempotent by design.** Running `/daily-review` twice on the same date refreshes the `## Evening review` section rather than duplicating it. If you're mid-day and want a partial reconciliation, that's fine — run it now and again at end of day.
- If the user ran `/daily-review` for a past date (not today), still allow writes, but double-confirm any Asana `due_on` changes since rescheduling historical tasks is easy to do by accident.
- If `+ Atlas/Daily/<date>.md` has no `## Morning brief` (the user skipped the morning), treat everything from step 2 as "unplanned" and still run the reconciliation — it becomes a pure "what got done today" pass.
- Budget clarifying questions: don't ask more than ~8 in a single run. If there are more ambiguous items, group them or ask the user to prioritize which to resolve now.
