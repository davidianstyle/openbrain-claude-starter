---
name: log-goal
description: Create a new goal note at + Atlas/Goals/<title>.md from the Goal template.
---

# /log-goal

## Inputs

- `$1`: goal title. Becomes the filename and note title.
- `$2` (optional): target date as `YYYY-MM-DD`.

## Procedure

1. **Check for existing note.** If `+ Atlas/Goals/<title>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Goal.md` to `+ Atlas/Goals/<title>.md`. Set `title:`, `created:` to today, `status: active`, and `target_date:` if provided.
3. **Collect details interactively.** Prompt the user for:
   - Definition of done
   - Why this matters
   - Related projects (search `+ Spaces/` for project MOCs)
   - Initial milestones (optional)
   Skip sections they leave blank.
4. **Link projects.** If the user names existing projects, add `[[wikilinks]]` under `## Projects`.
5. **Report.** Show the path and populated content.

## Output

- Path to new goal note
- Linked projects
