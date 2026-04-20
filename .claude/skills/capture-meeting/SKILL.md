---
name: capture-meeting
description: Turn rough meeting notes or a transcript into an atomic interaction note, update linked people's last_contact + Threads, and propose follow-up tasks.
---

# /capture-meeting

## Inputs

- `$1`: path to a file in `+ Inbox/` containing raw notes, OR the notes passed inline after the command, OR a calendar event id, OR a Fathom meeting ID (numeric or URL like `https://fathom.video/call/...`), OR a Google Meet conference record ID (e.g. `conferenceRecords/abc123`) or meeting URL (e.g. `https://meet.google.com/xxx-yyyy-zzz`).

## Procedure

1. **Ingest source.** If a file path, read it. If inline text, use it. If an event id, fetch the event + notes via the matching `google_*` MCP's `calendar_list_events` / `calendar_get_event`. If a Fathom meeting ID/URL or Google Meet conference record ID/URL is given directly, fetch that specific source first — then still attempt the other sources in parallel for completeness.

   **For calendar events and meeting titles**, resolve the calendar event first (via `google_*` calendar search), then fetch all three transcript sources **in parallel**:

   - **Google Meet transcript** — use `meet_list_meetings` on the matching `google_*` MCP scoped to the meeting date (±1 day window), then `meet_get_transcript` for the matching conference. To pick the right `google_*` server, infer from the organizer's email (match to a known slug), or use a slug hint if provided. Default to the user's work `google_*` MCP (see CLAUDE.md §12) if ambiguous. If `meet_list_meetings` doesn't return the expected meeting, also try matching by the Meet link from the calendar event's `conferenceData` — the conference ID (e.g. `jjj-pswx-emx`) should appear in the results.
   - **Fathom** — call `mcp__fathom__fathom_search_meetings` with the meeting title and date range, then `mcp__fathom__fathom_get_summary` and `mcp__fathom__fathom_get_transcript` for the matched recording.
   - **Gemini notes** — search the organizer's `google_*` MCP (or the user's work `google_*` MCP for work meetings) with `gmail_search_emails` query `from:gemini-notes@google.com subject:"<meeting title>" newer_than:2d`. If found, read the email via `gmail_read_email`. Gemini notes contain a summary, topic sections, and suggested next steps with owner attribution.

   **Merging sources:** Use all available sources together — they are complementary, not competing. General guidance:
   - **Fathom summary** is best for structured extraction (action items, topic labels, decisions) — use it as the primary scaffold when available.
   - **Google Meet / Fathom transcript** is the source of record for quotes, attribution, and timeline — use it to verify and disambiguate.
   - **Gemini notes** often surface clean next-steps with owner names — cross-reference against transcript to validate, and merge any unique items not captured by Fathom.
   - If only one source is available, use it. If none are available, tell the user and ask for raw notes.
2. **Identify participants.** Extract names + any email/slack identifiers from the source. Match to existing `+ Atlas/People/*.md` notes (fuzzy on title + aliases, and exact on `emails`/`slack`). For each unmatched participant:
   - **If the meeting is a real interaction (not a transcript with dozens of names)**: stage a stub at `+ Inbox/people-candidates/<Full Name>.md` using the `/people-sync` stub format, with this meeting as the first evidence bullet. Link the interaction note to the *candidate* stub via `[[people-candidates/<Full Name>]]` and flag for promotion at next `/process-inbox`.
   - **If the name is ambiguous** (first-name only, common name with no other identifier): leave unlinked with a `<!-- TODO: identify -->` marker and skip staging.
   - Offer `/log-person` as an alternative if the user wants to promote directly instead of staging.
3. **Extract structure.** From the raw notes, pull:
   - **Summary** (1–3 sentences)
   - **Decisions**
   - **Commitments (mine)** — things the user said he'd do
   - **Commitments (theirs)**
   - **Follow-ups** — actionable items with a potential owner
4. **Write interaction note.** Create `+ Atlas/Interactions/YYYY-MM-DD-<kebab-slug>.md` from the Interaction template. Fill frontmatter (`people:`, `projects:`, `source:`, `channel:`) and body sections. Slug from the core topic (e.g. `2026-04-07-sarah-roadmap-sync.md`).
5. **Update people notes.** For each linked person:
   - Set `last_contact: YYYY-MM-DD` (meeting date) in frontmatter.
   - Append a bullet under `## Threads` linking to the new interaction note: `- [[2026-04-07-sarah-roadmap-sync]] — one-line gist`.
   - Append new commitments into `## Open commitments` (theirs / mine).
6. **Propose Asana tasks.** For each Follow-up where the user is the owner, draft a task note in `+ Inbox/` tagged `#asana/personal` or `#asana/work` (infer from the linked person's `relationship` field: `work` → `#asana/work`, anything else → `#asana/personal`). Then prompt the user interactively via `AskUserQuestion`:
   - Show the list of drafted task notes (title + tag + inferred due date).
   - Options: `Push all now`, `Push selected`, `Edit first`, `Defer to next /process-inbox`.
   - On **Push all now** / **Push selected**: call the matching Asana MCP (`asana_work` or `asana_personal` per tag, per CLAUDE.md §5) to create each task. Write the returned `gid` + `workspace` back into the task note's frontmatter. Keep the note in `+ Inbox/` — `/process-inbox` will move it to its final home on the next pass.
   - On **Edit first**: leave the notes in `+ Inbox/` and tell the user which paths to open; skip the push.
   - On **Defer**: leave as-is. `/process-inbox` auto-push will handle them on the next run (per `feedback_triage_auto_push.md`).
   If there are no follow-ups where the user is the owner, skip this step entirely — don't prompt.
7. **If source was a file in `+ Inbox/`**, move it to `+ Archive/raw-meeting-notes/YYYY/` (do not delete).

## Output

- New interaction note path
- Summary of person-note updates
- List of proposed Asana task notes in `+ Inbox/`

## Notes

- Never send or share the interaction note. It's a private vault artifact.
- If extraction is ambiguous (e.g. unclear who committed to what), flag with inline `<!-- TODO: clarify -->` markers rather than guess.
