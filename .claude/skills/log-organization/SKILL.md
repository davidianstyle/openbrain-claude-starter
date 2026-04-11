---
name: log-organization
description: Create a new organization note at + Atlas/Organizations/<name>.md from the Organization template.
---

# /log-organization

## Inputs

- `$1`: organization name. Becomes the filename and note title.
- `$2` (optional): type — `company | church | nonprofit | group | other`.

## Procedure

1. **Check for existing note.** If `+ Atlas/Organizations/<name>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Organization.md` to `+ Atlas/Organizations/<name>.md`. Set `title:`, `created:` to today, and `type:` if provided.
3. **Collect details interactively.** Prompt the user for:
   - Type (if not provided)
   - URL (optional)
   - Context (what this org is, your relationship to it)
   - Key people (search `+ Atlas/People/` for matches)
   - Places (search `+ Atlas/Places/` for matches)
   Skip sections they leave blank.
4. **Link people and places.** Add `[[wikilinks]]` for confirmed matches.
5. **Report.** Show the path and populated content.

## Output

- Path to new organization note
- Linked people and places
