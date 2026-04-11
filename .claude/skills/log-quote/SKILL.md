---
name: log-quote
description: Save a quote as an atomic note at + Atlas/Quotes/<title>.md from the Quote template.
---

# /log-quote

## Inputs

- `$1`: the quote text (or a short title for it).
- `$2` (optional): author name.
- `$3` (optional): source — a `[[wikilink]]` to a `+ Sources/*` note or free text.

## Procedure

1. **Scaffold from template.** Copy `+ Extras/Templates/Quote.md` to `+ Atlas/Quotes/<title>.md`. Use a short slug derived from the quote or author for the filename. Set `title:`, `author:`, `source:`, `created:` to today.
2. **Fill the blockquote.** Replace the `> {{title}}` placeholder with the actual quote text.
3. **Collect details interactively.** Prompt the user for:
   - Author (if not provided)
   - Source (if not provided) — search `+ Sources/` for matching literature notes
   - Why this matters (optional)
   Skip sections they leave blank.
4. **Link source.** If the source matches an existing `+ Sources/*.md`, use a `[[wikilink]]` in frontmatter.
5. **Report.** Show the path and populated content.

## Output

- Path to new quote note
- Linked source if found
