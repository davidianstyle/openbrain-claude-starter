---
name: log-note
description: Quick-capture a thought, observation, or log entry as an atomic note — no people or interaction required.
---

# /log-note

General-purpose atomic note capture. For when you want to jot something down that isn't a decision, idea, interaction, or any other typed note.

## Inputs

- `$1`: the content to capture — can be a sentence, a paragraph, or a rough dump. The skill extracts a title and body from it.

## Procedure

1. **Extract title.** Derive a concise title from the input (under 60 chars). Use it as both `title:` frontmatter and the filename slug.
2. **Create atomic note.** Write to `+ Atlas/YYYY-MM-DD-<kebab-slug>.md` with frontmatter:
   ```yaml
   ---
   title: "<title>"
   created: YYYY-MM-DD
   tags: []
   ---
   ```
3. **Write body.** Organize the input into a clean note body. If the input contains:
   - Follow-ups or action items → list under `## Follow-ups`
   - Related people → add `[[wikilinks]]` (but do NOT create interaction notes or update `last_contact` — use `/log-interaction` for that)
   - Related projects or topics → add `[[wikilinks]]` to existing MOCs/notes
4. **Surface links.** Grep the vault for related existing notes and suggest 2–3 `[[wikilinks]]` worth adding. Don't force links that aren't genuinely relevant.
5. **Propose tags.** If the note clearly fits an existing tag (e.g. a tool/product observation → no standard tag; a workflow note → no standard tag), leave `tags: []` empty rather than inventing a new tag. Only apply tags from the approved taxonomy.

## Output

- Path to new note
- Any suggested links to existing notes
