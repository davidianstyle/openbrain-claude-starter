---
name: people-audit
description: Walk + Atlas/People/, report last_contact vs cadence, and update + Spaces/People.md grouping. Never edits person notes destructively.
---

# /people-audit

Housekeeping skill for the people layer.

## Procedure

1. **Read all people.** List every `+ Atlas/People/*.md`. Parse frontmatter: `title`, `relationship`, `cadence`, `last_contact`.
2. **Compute cadence health.** Same tiers as `/what-am-i-missing` step 3. Bucket into: `green` (within cadence), `yellow` (≤ 50% overdue), `red` (> 50% overdue).
3. **Rebuild MOC grouping.** Regenerate the bulleted wikilink lists under each section of `+ Spaces/People.md` from the `relationship:` frontmatter of each person note. Use whatever section headings already exist in the MOC (the user defines them) — do not invent new ones. Preserve any introductory prose — only replace the list bodies.
4. **Detect orphans.** People notes with empty `relationship:` → report to user, do not auto-place. People notes with no incoming wikilinks from any interaction or project → flag as "no activity logged."
5. **Detect broken frontmatter.** Missing `cadence`, invalid dates, etc. → flag without editing.
6. **Report health.**
   - `green / yellow / red` counts by relationship tier
   - Orphans list
   - Broken frontmatter list

## What this skill must NOT do

- Do not edit individual person notes (no auto-fixing cadence, no backfilling `last_contact`).
- Do not create new person notes.
- Do not delete anything.

## Output

- Summary report in chat
- `+ Spaces/People.md` updated in place (MOC sections only)
