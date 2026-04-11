---
name: log-idea
description: Create a new idea note at + Atlas/Ideas/<title>.md from the Idea template.
---

# /log-idea

## Inputs

- `$1`: idea title or short description. Becomes the filename and note title.

## Procedure

1. **Check for existing note.** If `+ Atlas/Ideas/<title>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Idea.md` to `+ Atlas/Ideas/<title>.md`. Set `title:` and `created:` to today.
3. **Collect details interactively.** Prompt the user for:
   - The idea itself (1–3 sentences)
   - Context / what prompted it (optional)
   - Related notes (search `+ Atlas/` and `+ Spaces/` for relevant links)
   Skip sections they leave blank.
4. **Surface related notes.** Grep across the vault for terms in the idea text. Suggest `[[wikilinks]]` to genuinely related existing notes.
5. **Report.** Show the path and populated content.

## Output

- Path to new idea note
- Any related notes surfaced
