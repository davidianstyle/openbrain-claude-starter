---
name: log-decision
description: Record a decision as an atomic note at + Atlas/Decisions/<title>.md from the Decision template.
---

# /log-decision

## Inputs

- `$1`: decision title or short description. Becomes the filename and note title.

## Procedure

1. **Check for existing note.** If `+ Atlas/Decisions/<title>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Decision.md` to `+ Atlas/Decisions/<title>.md`. Set `title:`, `date:` to today, `status: active`.
3. **Collect details interactively.** Prompt the user for:
   - Context (what situation led to this)
   - The decision itself
   - Reasoning (why this over alternatives)
   - Alternatives considered (optional)
   Skip sections they leave blank.
4. **Surface related notes.** Search for related decisions, projects, and people. Suggest `[[wikilinks]]`.
5. **Report.** Show the path and populated content.

## Output

- Path to new decision note
- Any related notes surfaced
