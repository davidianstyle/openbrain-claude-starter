---
name: weekly-review
description: Monday synthesis — write + Atlas/Weekly Reviews/<ISO-week>.md from the past week's daily notes, interactions, Asana task churn, and git history.
---

# /weekly-review

## Inputs

- `$1` (optional): ISO week (e.g. `2026-W14`). Defaults to the week just ended (Mon–Sun preceding today).

## Procedure

1. **Resolve week.** Compute start + end dates.
2. **Gather inputs.**
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

## Output

Path to the new weekly review note. Report a one-paragraph summary in chat.

## Notes

- Idempotent: if the file already exists, update it (don't duplicate).
- Budget: cap each section at a sensible number of bullets (5–10).
- Never rewrite daily notes as part of this skill.
