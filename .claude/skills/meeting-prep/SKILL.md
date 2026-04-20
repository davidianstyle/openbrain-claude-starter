---
name: meeting-prep
description: Assemble a briefing for a meeting or 1:1 — pulls the person note, last interactions, open commitments, related projects, and recent email/Slack thread excerpts from the right account.
---

# /meeting-prep

## Inputs

- `$1`: person name OR calendar event id OR calendar event title fragment.

## Procedure

1. **Resolve subject.**
   - If `$1` matches a `+ Atlas/People/*.md` file (by title or alias in frontmatter), use that person.
   - Else if `$1` looks like a calendar event id, fetch it via the right `google_*` MCP's `calendar_get_event` and extract attendees.
   - Else fuzzy-search `calendar_list_events` across all `google_*` MCPs for the next 7 days matching `$1`; pick the best match and extract attendees.
> **Parallelization:** step 1 (subject resolution) must run first because it decides which person notes to load. Once the subject is resolved, **steps 2–6 are all independent** — the person note read, interaction grep, project MOC reads, and `google_*` / `slack_*` thread fetches should be issued together in a single tool-use block.

2. **Load person note(s).** Read `+ Atlas/People/<name>.md` for each resolved person. If missing for an attendee, flag as "no person note yet" and offer to run `/log-person` after the brief.
3. **Recent interactions.** Grep `+ Atlas/Interactions/*.md` for wikilinks to the person. Read the 3 most recent by date.
4. **Open commitments.** Extract from the person note's `## Open commitments` section and any unresolved `Follow-ups` from recent interactions.
5. **Related projects.** Follow `[[wikilinks]]` in the Projects section to the relevant `+ Spaces/*` MOCs; summarize current status.
6. **Recent thread excerpts.** Using the person's `emails` frontmatter, pick the best-matching `google_*` MCP (match email domain/address to account slug) and `gmail_search_emails` for messages to/from them in the last 30 days. For Slack, use the `slack` frontmatter field to pick the workspace MCP and read recent DMs. Cap 3 messages per source. Summarize; do not dump raw content.
7. **Compose brief.** Return inline (do not write a file):
   - **Who** — one-liner per attendee
   - **Recent context** — last 3 interactions summarized
   - **Open commitments** — theirs / mine, with dates
   - **Related projects** — MOC links + one-line status
   - **Recent threads** — email + slack excerpts, source attribution
   - **Open questions / risks** — inferred from gaps or stale commitments

## Output

Inline chat response only. Prep briefings are ephemeral — do not write a file. Once the meeting actually happens, use `/capture-meeting` or `/log-interaction` to produce the lasting artifact in `+ Atlas/Interactions/`.

## Notes

- Never include raw email bodies verbatim — always summarize.
- If the person's email domain doesn't match any account slug, search all `google_*` MCPs.
