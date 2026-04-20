---
name: follow-up-draft
description: Draft a follow-up email or Slack message for a given person or thread, using the correct account. Never sends.
---

# /follow-up-draft

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
4. **Draft the message.** Match the user's voice — direct, terse, no filler. Lead with the ask. For email, include subject line. For Slack, no subject.
5. **Save as draft.**
   - **Email:** call `gmail_draft_email` on the matching `google_*` MCP. Report the draft id.
   - **Slack:** call `slack_send_message_draft` (or equivalent) on the matching `slack_*` MCP. Report the draft/scheduled id.
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
