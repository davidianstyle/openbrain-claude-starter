---
name: asana
description: Show Asana tasks due in the next 7 days across both workspaces and interactively mark tasks complete.
---

# /asana

Quick view of upcoming Asana tasks with interactive completion. Pure chat skill — no file writes.

## Inputs

- `$1` (optional): number of days to look ahead. Defaults to `7`.

## Procedure

### 1. Fetch upcoming tasks

**Issue both calls in a single tool-use block so they run in parallel.** The two workspaces may use different tools (paid plans support full search; free-tier rejects `asana_search_tasks` with 402 Payment Required), but both calls are independent and must not be sequential.

- **Paid workspace** (`mcp__asana_<slug>__asana_search_tasks`):
  - `assignee_any: me`
  - `completed: false`
  - `due_on_before: <today + $1 days>` (inclusive upper bound as YYYY-MM-DD)
  - `sort_by: due_date` *(must be `due_date`, NOT `due_on` — the API rejects `due_on` as a sort key with Bad Request)*
  - `sort_ascending: true`
  - `opt_fields: name,due_on,projects.name,permalink_url`
- **Free-tier workspace** (`mcp__asana_<slug>__asana_get_my_tasks`):
  - `completed_since: now` (returns incomplete tasks only)
  - `opt_fields: name,due_on,due_at,projects.name,permalink_url`
  - Client-side filter: keep tasks where `due_on` is non-null AND `due_on <= today + $1 days`. Sort ascending by `due_on`.

**Overdue** tasks (due_on < today, not completed) fall naturally inside the `due_on <= today + $1 days` window and will appear in both result sets without a separate query.

### 2. Display the list

Format as a **single unified table** with **Personal on the left** and **Work on the right**. Date group headers are rendered as **bold-text rows spanning the table** (use the Personal column for the label, leave other cells empty). Using one table guarantees consistent column widths throughout.

**Numbering:** assign numbers by counting through **all Personal tasks first** (across all date groups), then **all Work tasks** (across all date groups). This keeps the numbering contiguous within each workspace.

```
## Asana — next 7 days

| #  | Personal                                | #  | Work                                    |
|----|-----------------------------------------|----|-----------------------------------------|
|    | 🔴 **Overdue**                          |    |                                         |
| 1  | Task name — was due Apr 3               | 8  | Task name — was due Apr 5               |
|    | 📅 **Today (Apr 7)**                    |    |                                         |
| 2  | Task name (Project)                     | 9  | Task name (Project)                     |
| 3  | Task name (Project)                     |    |                                         |
|    | 📅 **Tomorrow (Apr 8)**                 |    |                                         |
| 4  | Task name                               |    |                                         |
|    | 📅 **Fri Apr 10**                       |    |                                         |
| 5  | Task name                               | 10 | Task name (Project)                     |
```

- **Single table** for the entire view — this forces all columns to the same width.
- Date groups appear as **bold label rows** with an emoji prefix: 🔴 for **Overdue**, 📅 for all other date groups. This adds color to make date headers visually distinct from task rows.
- **Numbering order:** first pass numbers all Personal tasks sequentially across all date groups (1, 2, 3, …), then second pass numbers all Work tasks continuing from where Personal left off. Within each workspace, numbers follow date order.
- Show project name in parentheses if available.
- When one column has more tasks than the other in a date group, leave the shorter column's cells empty.
- Omit date groups that have no tasks.
- If no tasks at all, say so and stop.

### 3. Interactive check-off (free-text)

After displaying the numbered list, ask the user to type the numbers of tasks he wants to mark complete. Example prompt:

> Type the numbers of tasks to check off (e.g. `1, 3, 8, 11`), or `none` to skip.

- Accept comma-separated numbers, ranges (`3-5`), or `none`/`skip` to exit.
- Validate that all numbers correspond to tasks in the displayed list.
- If any numbers are invalid, report which ones and re-prompt once.

### 4. Mark complete

For all selected tasks:

- Call `asana_update_task` on the correct workspace's MCP (`asana_work` or `asana_personal`) with `completed: true`.
- Run all update calls in parallel where possible.
- Report success/failure inline: `Completed: <task name>` or `Failed: <task name> — <error>`.
- If no tasks were selected, say "No tasks marked complete" and stop.

## Notes

- This is a **read + interactive update** skill. No vault files are created or modified.
- Cap at 25 tasks per workspace to keep the list actionable.
- Tasks without a due date are excluded (this skill is specifically for deadline-driven work).
- If a workspace is on a free Asana plan, `asana_search_tasks` returns 402 Payment Required. Use `asana_get_my_tasks` with `completed_since: now` instead, then client-side filter to tasks with `due_on` within the window.
- **Never** serialize the workspace fetches. They are independent — always issue them in the same tool-use block.
