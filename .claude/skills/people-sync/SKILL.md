---
name: people-sync
description: Discovery pass across Gmail, Google Calendar, Slack, and Fathom to find unknown people and stale contacts. Stages new-person candidates in + Inbox/people-candidates/ and auto-updates last_contact on existing people notes.
---

# /people-sync

Scan recent activity across all multi-account MCPs and Fathom, propose new person notes for unknown humans, update `last_contact` for known ones, and surface alias merges. Never writes directly to `+ Atlas/People/` — candidates stage in `+ Inbox/people-candidates/` for review.

## Inputs

- `$1` (optional): lookback window, e.g. `7d` (default), `14d`, `30d`.
- `$2` (optional): `interactive` (default) or `scheduled`. In scheduled mode, safe auto-updates (existing `last_contact`) proceed without confirmation; candidate note creation still goes to staging.

## Procedure

1. **Resolve window.** Compute `since = today - lookback`.
2. **Collect touchpoints across all accounts.** Fan out all four sources in a single tool-use block — every `google_*`, every `slack_*`, and Fathom. All calls are independent and must run concurrently; never loop through accounts serially.
   - **Gmail** — for each `google_*` MCP, `gmail_search_emails` with `newer_than:<window>` scoped to inbox + sent. Extract `From`, `To`, `Cc` addresses and display names from each thread. Tag each touchpoint with account slug and date.
   - **Google Calendar** — for each `google_*` MCP, `calendar_list_events` over the window. Extract attendees (name + email, skip resource rooms and the account owner).
   - **Slack** — for each `slack_*` MCP, pull recent DMs and mentions via `conversations_history` / `conversations_search_messages`. Extract user ids; resolve to display names via `users_search` or profile lookups. Tag with workspace slug.
   - **Fathom** — call `mcp__fathom__list_meetings` for the lookback window. Extract invitees (name + email) from each meeting. Tag touchpoints with source `fathom` and the meeting date. Each Fathom meeting where the user is a participant counts as a calendar-grade signal (direct meeting = high signal for Bucket C threshold).
3. **Normalize into a touchpoint table.** One row per (person identifier, source, date). Identifier = email address (Gmail/Cal) or `workspace-slug:user_id` (Slack).
4. **Filter noise.** Drop:
   - No-reply / bot addresses (`noreply@`, `no-reply@`, `notifications@`, `mailer-daemon@`, etc.).
   - Mailing list addresses and Google Group aliases.
   - Calendar resources (rooms, equipment).
   - The account owner themselves (all of the user's own addresses — see CLAUDE.md §12 for the configured Google slugs).
   - Any addresses the user has explicitly flagged as delegations / FYI-only in an auto-memory or CLAUDE.md note.
5. **Match against existing people.** Apply the alias resolution rules from CLAUDE.md §13:
   - Exact email → `emails:` array = definite match.
   - Exact Slack handle → `slack:` array = definite match.
   - Exact full name → `title:` or `aliases:` = definite match.
   - First-name-only or Slack display name → candidate only, never auto-link.
   - Never auto-merge on partial name match alone.
6. **Classify each touchpoint into one of three buckets.**
   - **Known, matched by identifier** → candidate for `last_contact` update (Bucket A).
   - **Known by name, but identifier is new** → candidate for alias/email/slack merge into existing person (Bucket B).
   - **Unknown** → candidate for a new person stub (Bucket C).
7. **Apply noise thresholds for Bucket C (unknowns).** Require at least one of:
   - ≥2 touchpoints across ≥2 distinct days in the window, OR
   - A calendar event where the user is also an attendee (direct meeting = high signal), OR
   - A Slack DM (not a mention in a channel).
   Anything below threshold is logged but not staged.
8. **Bucket A — update `last_contact` + log interactions.** For each matched person, if the most-recent touchpoint date > current `last_contact`, update the frontmatter in place. In `interactive` mode, list the diffs and ask for confirmation; in `scheduled` mode, apply directly.

   **Auto-log interactions from email/Slack.** For each email thread or Slack message involving a known person, create a lightweight interaction note if one doesn't already exist for that thread. Filtering rules:
   - **Include:** direct emails where the user is in To or From (not CC-only), Slack DMs, Slack @mentions where the user is the target.
   - **Exclude:** mailing lists, Google Groups, no-reply/bot addresses, automated notifications, CC-only threads, observer-only threads (per saved feedback).

   Create the note at `+ Atlas/Interactions/YYYY-MM-DD-<kebab-slug>.md` using the Interaction template:
   - `title`: email subject line or Slack thread topic
   - `channel`: `email` or `slack`
   - `people`: `[[wikilinks]]` to matched person notes
   - `source`: gmail thread ID or slack permalink
   - `## Summary`: first 2–3 sentences of the message body (auto-extracted, not invented)
   - Other sections (`Decisions`, `Commitments`, `Follow-ups`, `Notes`) left as `-`

   **Deduplication:** before creating, grep `+ Atlas/Interactions/` for `^source: <value>` in frontmatter. If an interaction note already exists with the same source (including richer notes from `/capture-meeting` or `/log-interaction`), skip creation. One interaction note per thread, not per message.

   **Threads update:** for each person, collect all new interaction bullets from this run, then write them in a single edit to that person's `## Threads` section: `- <date> · [[interaction-note-title]] (<channel>) — <one-line gist>`. Batch per person — do not re-read and re-write the person note for each interaction.

   In `interactive` mode, list proposed interaction notes and ask for confirmation. In `scheduled` mode, create them automatically (they are vault-local and non-destructive).
9. **Bucket B — alias merges.** For each, propose an edit to the existing person's `emails:` / `slack:` / `aliases:` array. Always require confirmation, even in scheduled mode (merges are irreversible via this skill).
10. **Bucket C — stage candidates.** For each unknown meeting the threshold, write a stub at `+ Inbox/people-candidates/<Full Name>.md`:

    ```markdown
    ---
    title: <Full Name>
    aliases: []
    emails: [<discovered emails>]
    slack: [<discovered slack handles>]
    phones: []
    relationship: []
    cadence: asneeded
    last_contact: <most recent touchpoint date>
    created: <today>
    tags: [person, needs-review, stub]
    workspace: <personal|work based on which MCPs surfaced them, per CLAUDE.md §12>
    ---

    # <Full Name>

    ## Context
    <!-- Auto-staged by /people-sync on <today>. Review before promoting to + Atlas/People/. -->

    ## Evidence
    - <source-slug> · <date> · <1-line context: subject line, event title, or channel>
    - ...

    ## Open commitments
    ### Mine to them
    -
    ### Theirs to me
    -

    ## Threads

    ## Related people

    ## Projects
    ```

    If a stub already exists in `+ Inbox/people-candidates/` for this person, **append** new evidence bullets rather than overwriting; update `last_contact` if newer.
11. **Report.** Output a five-section summary:
    - **Updated (Bucket A)** — count + list of people whose `last_contact` advanced.
    - **Interactions logged (Bucket A)** — list of auto-created interaction notes from email/Slack.
    - **Alias merges proposed (Bucket B)** — one line per proposal, awaiting confirmation.
    - **Candidates staged (Bucket C)** — paths to new/updated stubs in `+ Inbox/people-candidates/`.
    - **Below threshold (logged, not staged)** — one-line tally with count only.

## Promotion path

Candidates are promoted out of `+ Inbox/people-candidates/` manually or via `/process-inbox`:
- User reviews the stub, fills in `relationship`, trims evidence.
- Move file to `+ Atlas/People/<Full Name>.md` (strip `needs-review, stub` tags).
- Add `[[<Full Name>]]` to the correct section of `+ Spaces/People.md`.

This skill never performs promotion itself.

## Output

- Bucket counts and diffs as described in step 11.
- List of paths touched (staged stubs + person notes updated).

## Notes

- **Read-only toward Gmail/Slack/Calendar** — never mark anything read, archive, or send.
- **Idempotent** — re-running on the same window should produce no new writes if nothing changed.
- **Never promote from `+ Inbox/people-candidates/` to `+ Atlas/People/`** automatically.
- **Never guess `relationship`** for Bucket C — leave the array empty. Inference is the user's call at promotion time.
- **Phones are never auto-populated** — same rule as `/log-person`.
- If a candidate's name is ambiguous (e.g. just a first name like "Alex"), skip Bucket C and log under "below threshold" regardless of touchpoint count.
