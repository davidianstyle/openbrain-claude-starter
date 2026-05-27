---
name: sync-organizations
description: Discovery pass across Gmail, Google Calendar, Slack, and Fathom to find organizations not yet captured in + Atlas/Organizations/. Stages candidates in + Inbox/org-candidates/ for review. Mirrors /sync-people, but for organizations rather than people.
---

# /sync-organizations

Scan recent activity across all multi-account MCPs and Fathom, propose new Organization notes for domains/entities not yet captured in `+ Atlas/Organizations/`, and surface candidates that should also be added as the Place facet (per the "Places and Organizations are facets, not categories" rule in memory). Never writes directly to `+ Atlas/Organizations/` — candidates stage in `+ Inbox/org-candidates/` for review.

## Inputs

- `$1` (optional): lookback window, e.g. `30d` (default), `7d`, `90d`. Orgs accumulate slowly so a wider window than `/sync-people` is the default.
- `$2` (optional): `interactive` (default) or `scheduled`. In scheduled mode, candidate staging proceeds without confirmation (drafts only — no `+ Atlas/` writes).

## Procedure

1. **Resolve window.** Compute `since = today - lookback`.

2. **Collect touchpoints across all accounts.** Fan out all four sources in a single tool-use block — every `google_*`, every `slack_*`, and Fathom. ~10 calls that must run concurrently.
   - **Gmail** — for each `google_*` MCP, `google_gmail_search_emails` with `newer_than:<window>` scoped to inbox + sent. Extract the **domain** of every `From`, `To`, `Cc` address.
   - **Google Calendar** — for each `google_*` MCP, `google_calendar_list_events` over the window. Extract attendee email domains *and* event `location` strings.
   - **Slack** — for each `slack_*` MCP: domain signal is weak from Slack (people identified by handle, not email). Capture only the workspace itself as an implicit Org touchpoint (e.g. `acme.slack.com` → Acme). Slack rarely surfaces *new* org candidates; treat as supporting evidence for existing ones.
   - **Fathom** — `mcp__fathom__fathom_list_meetings` over the window. Extract `calendar_invitees` and their email domains. Fathom's `is_external: true` flag is high-signal for outside organizations.

3. **Existing-org inventory.** Build a set of already-known Org identifiers:
   - Read `+ Atlas/Organizations/*.md` — for each, capture `title`, `url`, and any domain implied by `url`.
   - Also load `+ Atlas/People/*.md` `emails:` arrays — domains that have ≥1 person attached count as "implied orgs already in scope" even if no Org note exists yet (these are *gap candidates* — high-value stage targets).
   - Also load `+ Inbox/org-candidates/*.md` if the folder exists — to avoid duplicate staging.

4. **Normalize into a touchpoint table.** One row per (domain, source, date, person-touchpoint-count). Roll up touchpoints per domain.

5. **Filter noise.** Drop:
   - **Consumer email providers** (these are people, not orgs): `gmail.com`, `googlemail.com`, `yahoo.com`, `outlook.com`, `hotmail.com`, `live.com`, `aol.com`, `msn.com`, `icloud.com`, `me.com`, `mac.com`, `comcast.net`, `sbcglobal.net`, `verizon.net`, `att.net`, `cox.net`, `bellsouth.net`, `earthlink.net`, `optimum.net`.
   - **No-reply / system domains**: anything that only appears under sender addresses like `noreply@`, `notifications@`, `mailer-daemon@`, `donotreply@`, `connect@`, `email@`, `news@`, `info@` *and* never on a To/From that's bidirectional with the user. Marketing-only domains belong to the Delegated/FYI bucket, not Organizations.
   - **The user's own configured Google account domains** (already known org identifiers; treat them as Bucket A signals, not noise).

6. **Classify each domain into one of three buckets.**
   - **Bucket A — Known org, already in `+ Atlas/Organizations/`.** Possible action: enrich the Org note with newly-discovered people or recent activity. Low priority; surface as "active orgs" tally but don't propose edits unless the user asks.
   - **Bucket B — Implied org (≥1 person note has this domain) but no Org note exists yet.** High-value gap. These should be staged with high confidence.
   - **Bucket C — Truly unknown domain.** Apply threshold (step 7) before staging.

7. **Apply threshold for Bucket C (unknowns).** Require at least one of:
   - **≥2 distinct individuals** from the same domain across the window (e.g. two `@example.org` people show up = the domain is an organizational entity, not a one-off contact), OR
   - **≥3 touchpoints from a single individual** at the domain across ≥2 distinct days (recurring engagement signals an active relationship worth tracking), OR
   - **Fathom meeting where the user is a participant AND an external-domain attendee** is present (direct meeting = high signal, mirrors `/sync-people` Bucket C rule).

   Anything below threshold is logged but not staged.

8. **Place-facet check (per `feedback_place_org_facets.md`).** For each Bucket B/C candidate:
   - Look for matching Place notes in `+ Atlas/Places/` by name or address.
   - If a Place note already exists (e.g. building hosts the org), append `## Related organizations` cross-link suggestion to the staging note.
   - Also scan recent calendar `location` strings for the org's name — if found, surface "this org also appears as a calendar location — consider creating a Place note" in the staging note's Notes section.

9. **Suggest `type` classification** based on TLD and signals (best-effort, user finalizes at promotion):
   - `.edu` → `other` (default) or `nonprofit` if research-focused
   - `.gov`, `.us` (state/local) → `other`
   - `.org` → `nonprofit` (default)
   - `.church` / known church TLDs → `church`
   - `.com` with multiple employees → `company`
   - Single-domain personal/vanity site → flag for review, don't auto-classify

10. **Bucket B + C — stage candidates.** Write a stub at `+ Inbox/org-candidates/<Org Name>.md` using the Organization template:

    ```markdown
    ---
    title: <Org Name (inferred from domain or known)>
    type: <suggested per step 9>
    url: https://<domain>
    created: <today>
    tags: [organization, needs-review, stub]
    ---

    # <Org Name>

    ## Context
    <!-- Auto-staged by /sync-organizations on <today>. Review before promoting to + Atlas/Organizations/. -->
    Domain: `@<domain>`. <N> person-touchpoints across <window>. Surfaced from: <sources>.

    ## Key people
    <!-- [[wikilinks]] to + Atlas/People/* where emails:array contains @<domain> -->
    - [[Person Name]] · <email>
    - ...

    ## Evidence
    - <source-slug> · <date> · <1-line context: email subject, calendar event title, Fathom meeting title>
    - ...

    ## Possible Place facet
    <!-- Per feedback_place_org_facets.md. Populated only if a calendar location matched this org name. -->
    -

    ## Current ongoings
    <!-- Auto-extracted only if interactions/Asana tasks reference this org by name. Otherwise leave blank. -->
    -

    ## Places
    <!-- [[wikilinks]] to + Atlas/Places/* if the org appears at a known venue -->

    ## Related
    -
    ```

    If a stub already exists in `+ Inbox/org-candidates/` for this org, **append** new evidence bullets and new `## Key people` entries rather than overwriting.

10b. **Web fallback for HQ address (interactive mode only).** After staging, for each new Bucket B/C candidate that's a non-consumer org (not a vendor billing domain like `sendgrid.com`), do **one** `WebSearch` for `"<org name>" headquarters address` (or `"<org name>" location` for local/regional orgs). Add a geographic hint if the org name is ambiguous, drawn from the user's home anchor — read `+ Atlas/Places/*.md` for any `type: home` notes and use that city/state. On an unambiguous match:
    - Append to the stub's `## Possible Place facet` section: `_HQ candidate: <address> (from <URL>, verify). If this is the org's primary physical location, /sync-places will pick it up on its next run; otherwise create a Place note manually._`
    - Skip silently if the search returns nothing useful or multiple conflicting addresses.
    - **Hard cap: 1 WebSearch + 1 WebFetch per candidate.** Skip the lookup entirely in `scheduled` mode — sync runs should not burn web quota on uncertain matches.

11. **Report.** Output a four-section summary:
    - **Active orgs (Bucket A)** — count of known orgs with touchpoints in the window. List names only, no diffs.
    - **Implied-org gaps (Bucket B)** — list of staged stubs at `+ Inbox/org-candidates/`. These are the highest-value new captures.
    - **New domain candidates (Bucket C)** — list of staged stubs meeting threshold.
    - **Below threshold (logged, not staged)** — one-line tally with count only. Note any domains that almost-cleared (e.g. `≥2 touchpoints but only 1 individual` — close call worth a glance).

## Promotion path

Candidates are promoted out of `+ Inbox/org-candidates/` manually or via `/process-inbox`:
- User reviews the stub, fills in `type` (if the auto-suggestion was wrong), trims evidence, fleshes out `## Context`.
- Move file to `+ Atlas/Organizations/<Org Name>.md` (strip `needs-review, stub` tags).
- If the stub's "Possible Place facet" section was populated, also create the corresponding `+ Atlas/Places/<Place Name>.md` and cross-link via `## Places` ↔ `## Related organizations` per `feedback_place_org_facets.md`.

This skill never performs promotion itself.

## Output

- Bucket counts and lists as described in step 11.
- List of paths touched (staged stubs in `+ Inbox/org-candidates/`).

## Notes

- **Read-only toward Gmail/Slack/Calendar/Fathom** — never mark anything read, archive, or send.
- **Idempotent** — re-running on the same window should produce no new writes if nothing changed (only append new evidence to existing stubs when new touchpoints are seen).
- **Never auto-promote** from `+ Inbox/org-candidates/` to `+ Atlas/Organizations/`.
- **Never auto-classify** `type` with high confidence — the suggested type per step 9 is a hint; user finalizes at promotion time. The `## Key people` section is the same — link discovered emails, but don't infer relationships beyond "this person's email is at this domain."
- **Cross-skill coordination:** when `/sync-people` stages a new person at a non-consumer domain, this skill's next run should pick up the implied Org. Skills should not duplicate logic — `/sync-organizations` reads `+ Atlas/People/*.md` as the source of truth for which domains are person-attached.
- **Place facet awareness:** per `feedback_place_org_facets.md`, an Org and a Place can co-exist for the same entity. This skill stages Org candidates but only *suggests* Place creation in the staging note; it does not auto-stage Places (that's the future `/sync-places` skill's job).
