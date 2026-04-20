---
name: what-am-i-missing
description: Surface overdue Asana tasks, open commitments past implied deadlines, people past their cadence, and unanswered email threads where the user is the next actor.
---

# /what-am-i-missing

A forcing function for things that have fallen off the user's radar.

## Procedure

> **Parallelization:** steps 1, 2, 3, and 4 are all independent (Asana, vault grep, people walk, Gmail). Fan out the Asana calls (each configured workspace) and the `google_*` calls (all accounts) alongside the vault reads in a single tool-use block. Do not serialize.

1. **Overdue Asana tasks.** For each configured workspace (`asana_personal`, `asana_work`) → `asana_get_my_tasks` with `opt_fields=name,due_on,projects.name,permalink_url,recurrence` (the `recurrence` field is mandatory — see Notes), then post-filter to due date < today and status != done. Group by workspace.
2. **Stale commitments.** Grep `+ Atlas/People/*.md` and `+ Atlas/Interactions/*.md` for unresolved "Commitments (mine)" / "Follow-ups" items. Heuristic for "stale": interaction note or person note was last modified > 14 days ago AND has unchecked bullets in those sections.
3. **People past cadence.** Walk `+ Atlas/People/*.md`; compute days since `last_contact` vs `cadence`:
   - `weekly` → overdue at 8 days
   - `monthly` → overdue at 32 days
   - `quarterly` → overdue at 95 days
   - `asneeded` → never overdue
4. **Unanswered mail where the user is next actor.** For each `google_*` MCP, `gmail_search_emails` with `is:unread newer_than:7d in:inbox -from:me` AND the sender is not a known mailing list. Apply a simple "asked a question" heuristic: subject contains `?` or the message body ends with `?`. (Best-effort; the user can correct.)
5. **Compose report.**
   - **Overdue tasks** (by workspace)
   - **Stale commitments** (by person)
   - **People past cadence** (by tier, most overdue first)
   - **Unanswered mail** (by account)
6. **Rank.** Add a top-line "Most urgent" section listing the top 3 items across all categories, in the user's best judgment.

## Output

Inline chat report. No file writes.

## Notes

- Budget: cap each category at 10 items to stay actionable.
- Do not mark anything as done or mark any email as read — this is a pure read/report skill.
- **Asana display ordering.** In the **Overdue tasks** section, group by repeat frequency and sort least-frequent → most-frequent so high-stakes items bubble to the top: **One-off → Annually → Monthly → Weekly → Daily**. **Source of truth: the Asana `recurrence.type` field — never guess from the task name.** Step 1's `opt_fields` already includes `recurrence` for this reason. Mapping: `never`→One-off, `yearly`→Annually, `monthly`→Monthly, `weekly`→Weekly, `daily`→Daily. If `recurrence` is missing on a task, treat as `never` and flag with `?`. Within each group, secondary sort by `due_on` ascending. Omit empty groups. Render group labels inline as bold text.
