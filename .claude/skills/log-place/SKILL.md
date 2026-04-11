---
name: log-place
description: Create a new place note at + Atlas/Places/<name>.md from the Place template.
---

# /log-place

## Inputs

- `$1`: place name. Becomes the filename and note title.
- `$2` (optional): type — `church | office | restaurant | venue | home | other`.

## Procedure

1. **Check for existing note.** If `+ Atlas/Places/<name>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Place.md` to `+ Atlas/Places/<name>.md`. Set `title:`, `created:` to today, and `type:` if provided.
3. **Collect details interactively.** Prompt the user for:
   - Type (if not provided)
   - Address (optional)
   - Context (what this place is, why it matters)
   - Related people or organizations
   Skip sections they leave blank.
4. **Link people and orgs.** Search `+ Atlas/People/` and `+ Atlas/Organizations/` for matches. Add `[[wikilinks]]`.
5. **Report.** Show the path and populated content.

## Output

- Path to new place note
- Linked people and organizations
