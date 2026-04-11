---
title: People
tags: [moc]
created: 2026-04-10
---

# People

Curated hub linking to every [[+ Atlas/People|person note]] in the vault, grouped by relationship context. The `/people-audit` skill regenerates the bulleted lists below from each person note's `relationship:` frontmatter — **do not hand-edit the lists**; edit the frontmatter of the individual person notes instead.

Add new section headings here as your network grows. Common starting points:

## Work

_No people yet. Create one with `/log-person` or let `/people-sync` discover them from your Gmail/Slack/Calendar._

## Family

## Friends

## Network

---

## How the people model works

- Each person gets an atomic note at `+ Atlas/People/<Full Name>.md` (use the Person template).
- Meetings, calls, and significant threads become [[+ Atlas/Interactions|interaction notes]] that link back to the person via the `people:` frontmatter array.
- `last_contact:` on the person note auto-updates when a new interaction is logged.
- `cadence:` governs when someone becomes "overdue" — `weekly`, `monthly`, `quarterly`, or `asneeded`.
- `/what-am-i-missing` and `/people-audit` surface cadence misses.

See `CLAUDE.md` §12 for the full people data model.
