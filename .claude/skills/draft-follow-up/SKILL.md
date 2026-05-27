---
name: draft-follow-up
description: Draft a follow-up email or Slack message for a given person or thread, using the correct account. Never sends.
---

# /draft-follow-up

## Inputs

- `$1`: person name OR gmail thread id OR slack permalink.
- `$2` (optional): intent hint — e.g. `"nudge on roadmap"`, `"thank them for the intro"`, `"follow up on action items from last meeting"`.

## Procedure

1. **Resolve subject + channel.**
   - Person name → look up `+ Atlas/People/<name>.md`. Default channel = email if `emails` is populated, else Slack.
   - Thread id → fetch via matching `google_*` MCP; channel = email.
   - Slack permalink → extract workspace slug and thread; channel = Slack.
2. **Pick the right account.**
   - **Email:** match the person's primary email domain to the best `google_*` account slug. If the person is in `relationship: [work]`, default to the work `google_*` MCP (see CLAUDE.md §12 for the configured work Google slug).
   - **Slack:** use the workspace from the permalink, or from the person's `slack:` frontmatter.
3. **Gather context.** Pull the last 1–2 interactions from `+ Atlas/Interactions/`, the open commitments section from the person note, and the last email/Slack thread excerpt.
4. **Draft the message.** Apply the writing-style profile in CLAUDE.md §6 (general voice, em-dash rule, email vs Slack, audience-size split). For email: include a subject line. For Slack: no subject. All other formatting and tone choices come from §6. (To populate or refresh §6 from your real sent messages, run `/learn-writing-style`.)
5. **Save as draft.**
   - **Email:** call `gmail_draft_email` on the matching `google_*` MCP with `mimeType: "multipart/alternative"`, `body` (plain-text mirror), and `htmlBody` (HTML body per CLAUDE.md §6). For in-thread replies, set `threadId` and `inReplyTo`. Report the returned draft id.
   - **Slack:** call `slack_drafts_create` on the matching `mcp__slack_<workspace>__` MCP with `channel_id` (+ optional `thread_ts` for thread replies). Only one draft per channel is allowed — if one already exists, call `slack_drafts_edit` instead. Report the returned `draft.id` (format `Dr0B...`).
     - **Channel resolution for DM drafts:** the `channel_id` must be an IM channel id (`D...`), not a user id. Look up an existing IM via `slack_channels_list types=im` (match against the user id from `slack_users_search`). Opening a new DM via `slack_conversations_open` currently fails with `missing_scope` on the OpenBrain Slack OAuth grant — if no existing IM channel is found, fall back to outputting the draft text inline only and note that it wasn't stored server-side.
     - For in-thread replies the channel id is already known from the source thread, so the DM-lookup step does not apply.
6. **Log vault-side trail.** If `$1` resolved to a person note, append a bullet under its `## Threads` section so `/what-am-i-missing` and future lookups can see the pending draft:
   `- <YYYY-MM-DD> · drafted follow-up (<channel>:<draft-id>) — <intent or one-line gist>`
   Do not update `last_contact` — a draft is not a touchpoint.
7. **Never send.** If the user wants to send, they do so themselves from the Gmail/Slack client.

## Output

- Account used
- Draft text (inline in chat)
- Draft id from the MCP server

## Notes

- If the appropriate `chat:write` scope is missing for a Slack workspace, fall back to outputting the draft text inline only, with a note that it wasn't stored server-side.
- Do not draft on behalf of anyone else — only the user.
