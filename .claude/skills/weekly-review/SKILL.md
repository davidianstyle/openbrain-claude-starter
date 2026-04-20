---
name: weekly-review
description: Monday synthesis — write + Atlas/Weekly Reviews/<ISO-week>.md from the past week's daily notes, interactions, Asana task churn, and git history.
---

# /weekly-review

## Inputs

- `$1` (optional): ISO week (e.g. `2026-W14`). Defaults to the week just ended (Mon–Sun preceding today).

## Procedure

> **Date check first.** Before resolving the week, run `Bash: date "+%Y-%m-%d %A %H:%M %Z"` to get today's actual date. Do **not** trust the session-injected `currentDate` field — it can lag the real clock by a day. Use the shell result as the anchor for "the week just ended."

1. **Resolve week.** Compute start + end dates.
2. **Gather inputs.** Issue all reads and fetches in a single tool-use block — daily-note reads, interaction reads, both Asana workspaces, and git log are independent and must run concurrently.
   - Read every `+ Atlas/Daily/YYYY-MM-DD.md` whose date falls in the week.
   - Read every `+ Atlas/Interactions/YYYY-MM-DD-*.md` in the week.
   - Asana task churn: for both workspaces, list tasks completed in the window (`asana_search_tasks` with `completed_on.after` / `.before`), and tasks newly created.
   - Git history: `git log --since=<start> --until=<end> --oneline` from the vault repo → captures vault activity.
3. **People sweep.** Invoke `/people-sync 7d scheduled` logic for the review window — update `last_contact` on Bucket A matches, stage Bucket C candidates in `+ Inbox/people-candidates/`, and hold Bucket B alias merges for user confirmation in the review output. Feed the bucket counts into the review.
4. **Compose the review.** Write `+ Atlas/Weekly Reviews/<ISO-week>.md` with sections:
   - **Highlights** — 3–5 bullets, most meaningful moments of the week (from daily notes + interactions).
   - **People touched** — unique `[[wikilinks]]` from interactions this week.
   - **Shipped** — Asana tasks completed, grouped by workspace.
   - **Started** — Asana tasks newly created this week.
   - **Vault activity** — summary of the git log (ignore auto-commits from the stop hook unless they contain meaningful classifications).
   - **Open loops carried forward** — unresolved follow-ups + stale commitments surfaced by the same logic as `/what-am-i-missing`.
   - **Reflection prompts** — 3 questions for the user to answer in-note (what went well, what dragged, one thing to try next week). Leave blank for the user to fill.
   - **People sync summary** — bucket counts from step 3, plus any alias merges awaiting confirmation.
5. **Link from Home.** Ensure `Home.md`'s "Recent weekly reviews" section (if present) gets the new entry; otherwise skip.
6. **Refresh `Dashboard.md` week-ahead view (optional).** If a `Dashboard.md` file exists at the vault root, this skill owns its forward-looking sections — rebuild them from fresh Asana + calendar data for the **upcoming** week (Mon → Sun starting tomorrow if running on a Sunday/Monday morning, otherwise the next 7 days from today). **Skip this step entirely if `Dashboard.md` does not exist.** Procedure:
   - Gather (in parallel with the rest of the review where possible): 7-day calendar sweep across all `google_*` accounts (via `calendar_list_events`); `asana_get_my_tasks` for each configured workspace with `completed_since=now` and post-filter to `due_on` within the upcoming-week window.
   - Replace the body of these H2 sections in `Dashboard.md` in place (find heading → overwrite to next H2 or EOF):
     - `## This week (...)` — update the heading dates to the new window. Group by **work meetings that matter** (filter to events with attendees > 1; collapse auto-blocking like Reclaim "Busy" rows and out-of-office noise) and **personal anchors** (recurring family / community / 1:1 events).
     - `## Top priorities` — checkbox bullets with `[[wikilinks]]` to people where natural, sorted by `due_on`. Sub-list per workspace if multiple workspaces are configured.
   - Update the frontmatter `updated:` field to today.
   - Never touch `## Today`, `## Needs a reply / open loops`, `## People past cadence`, `## Delegated / FYI`, or `## Quick links` — those are owned by `/daily-brief` (or static).

## Output

Path to the new weekly review note. Report a one-paragraph summary in chat.

## Notes

- Idempotent: if the file already exists, update it (don't duplicate).
- Budget: cap each section at a sensible number of bullets (5–10).
- Never rewrite daily notes as part of this skill.
