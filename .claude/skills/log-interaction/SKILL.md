---
name: log-interaction
description: Manually log a touchpoint (call, quick DM, hallway chat) as an atomic interaction note without needing a transcript.
---

# /log-interaction

Lightweight counterpart to `/capture-meeting` — for when there's no raw notes file, just a thing worth recording.

## Inputs

- `$1`: person name (must match an existing `+ Atlas/People/*.md`), or comma-separated names for multi-person touchpoints.
- `$2`: short topic/description. Becomes the filename slug and note title.
- `$3` (optional): channel — `meeting | call | email | slack | dm | in-person`. Defaults to `in-person`.

## Procedure

1. **Resolve people.** Fuzzy-match names to `+ Atlas/People/*.md`. Any miss → stop and suggest `/log-person` for them first.
2. **Create interaction note.** Scaffold from `+ Extras/Templates/Interaction.md` at `+ Atlas/Interactions/YYYY-MM-DD-<kebab-slug>.md`. Fill `people:`, `channel:`, `date:`, `title:`.
3. **Collect details interactively.** Prompt the user for:
   - Summary (1–3 sentences)
   - Any decisions
   - Any commitments (theirs / mine)
   - Any follow-ups
   Skip sections they leave blank.
4. **Update people notes.** For each participant, update `last_contact` and append a Threads bullet (same as `/capture-meeting` step 5).
5. **No Asana task proposal** unless the user explicitly asks — this skill is for lightweight capture.

## Output

- Path to new interaction note
- Summary of person-note updates
