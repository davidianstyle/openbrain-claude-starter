---
name: log-person
description: Create a new person atomic note at + Atlas/People/<Full Name>.md from the Person template, optionally seeding context from Gmail/Slack searches across all accounts.
---

# /log-person

## Inputs

- `$1`: full name (quoted if it contains spaces), e.g. `"Alice Example"`
- `$2` (optional): `quick` to skip the cross-account context seed, `deep` (default) to search all Gmail + Slack for prior mentions.

## Procedure

1. **Check for existing note.** If `+ Atlas/People/<name>.md` already exists, stop and tell the user — offer to open it instead.
2. **Scaffold from template.** Copy `+ Extras/Templates/Person.md` to `+ Atlas/People/<name>.md`. Set `title: <name>` and `created:` to today.
3. **Context seed (unless `quick`).** Fan out across every `google_*` and every `slack_*` in a single tool-use block — all calls are independent and must never be serialized.
   - For each `google_*` MCP, `google_gmail_search_emails` for the person's name (as both sender and recipient). Collect top 5 hits per account. Extract email addresses and populate frontmatter `emails:`.
   - For each `slack_*` MCP, `slack_search_users` for the name. Populate `slack:` with `workspace-slug:user_id` entries.
   - Cross-reference across accounts — if the same email address appears in multiple `google_*` account sweeps, that's fine (common for cc'd threads).
4. **Relationship inference.** Based on which accounts surfaced the person, suggest a default `relationship:` value:
   - Appears only in the user's work Google/Slack sources → `work`
   - Appears in one of the user's other accounts mapped to a specific community (see CLAUDE.md §11 account table) → use that community's label
   - Otherwise → `network` (user can correct)
5. **Add to MOC.** Append `- [[<name>]]` under the correct section of `+ Spaces/People.md` (based on relationship).
6. **Report.** Show the populated frontmatter and the inferred context; ask the user to confirm or correct before saving.

## Output

- Path to new person note
- Populated frontmatter
- Any context gathered (summarized, not verbatim)

## Notes

- Only populate frontmatter from unambiguous matches. If multiple people with the same name surface, flag it and don't guess.
- Never write real phone numbers from email signatures automatically — leave `phones: []` for the user to fill.
