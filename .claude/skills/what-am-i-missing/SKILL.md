---
name: what-am-i-missing
description: Surface overdue Asana tasks, open commitments past implied deadlines, people past their cadence, and unanswered email threads where the user is the next actor.
---

# /what-am-i-missing

A forcing function for things that have fallen off the user's radar.

## Procedure

1. **Overdue Asana tasks.** Both `asana_personal` and `asana_work` → `asana_get_my_tasks` with due date < today and status != done. Group by workspace.
2. **Stale commitments.** Grep `+ Atlas/People/*.md` and `+ Atlas/Interactions/*.md` for unresolved "Commitments (mine)" / "Follow-ups" items. Heuristic for "stale": interaction note or person note was last modified > 14 days ago AND has unchecked bullets in those sections.
3. **People past cadence.** Walk `+ Atlas/People/*.md`; compute days since `last_contact` vs `cadence`:
   - `weekly` → overdue at 8 days
   - `monthly` → overdue at 32 days
   - `quarterly` → overdue at 95 days
   - `asneeded` → never overdue
4. **Unanswered mail where the user is next actor.** For each `gmail_*` MCP, `gmail_search_messages` with `is:unread newer_than:7d in:inbox -from:me` AND the sender is not a known mailing list. Apply a simple "asked a question" heuristic: subject contains `?` or the message body ends with `?`. (Best-effort; the user can correct.)
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
