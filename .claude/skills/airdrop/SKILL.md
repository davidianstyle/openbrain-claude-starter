---
name: airdrop
description: Send file(s) to a nearby Apple device via AirDrop — opens the macOS share window pre-loaded and reports the verified outcome (sent / cancelled / failed) programmatically.
---

# /airdrop

Send one or more files to a nearby device over AirDrop. macOS only.

## Inputs

- `$1..$N`: path(s) of the file(s) to send. At least one required.

## What's automated vs. human

macOS keeps two actions human by design: choosing the receiving device in the AirDrop window, and — when the two machines are signed into different Apple IDs — the Accept prompt on the receiver. Everything else is automated, including a verified verdict on how the session ended (see Notes for how, and why the obvious API can't provide it).

## Procedure

1. Verify each input path exists. If one doesn't, stop and tell the user which.
2. Run the bundled helper **as a background task** (it blocks until the AirDrop session ends, which includes human reaction time). Invoke it by its **absolute path inside this skill's own directory** — the "Base directory for this skill" you're given at invocation — so it works from any cwd, whether this skill loaded from the vault or from a global install:
   ```bash
   bash "<skill-base-dir>/airdrop.sh" <file> [file...]
   ```
   Substitute `<skill-base-dir>` with the absolute base directory shown for this skill. **Do not** use a cwd-relative path like `.claude/skills/airdrop/airdrop.sh` — a non-vault session won't resolve it. (The helper canonicalizes each file arg to an absolute path itself, so it's otherwise cwd-independent.)
3. Immediately tell the user:
   - Click the receiving device in the window, then leave it alone. Cancel aborts; Esc and close-box do nothing — the window dismisses itself when the session ends.
   - If the receiver uses a different Apple ID, answer the Accept prompt on that machine; an unanswered prompt looks like a hang.
4. When the helper exits, report its last output line:
   - `SENT` (exit 0) — transfer verified. State it as fact; don't ask the user whether it worked.
   - `DISMISSED: ...` (exit 1) — the user clicked Cancel; nothing was transferred.
   - `FAILED: <reason>` (exit 1) — the sharing service reported an error.
   - `TIMEOUT: ...` (exit 1) — nobody touched the window for `AIRDROP_KEEPALIVE` seconds (default 600); treat as abandoned.
   - `CLOSED: ...` (exit 2) — session ended but this system can't verify sent-vs-cancelled; ask the user what they saw.

## Notes

- Re-running first clears any stale helper (and its ghost window) from a previous run — which also kills an in-flight transfer, so wait for the verdict before sending the next batch.
- One recipient per send. Multi-recipient callback semantics are undefined; send twice instead.
- **Why the verdict needs a side-channel** (empirical, macOS 15): `NSSharingServiceDelegate` is blind to cancel-vs-sent — `didShareItems` fires identically for a completed transfer and the Cancel button, and `willShareItems` fires at window-open, not recipient choice. The helper therefore uses the delegate only for the instant exit, and gets the verdict by snapshotting sharingd's `AfterFirstUseExpirationDate` preference, which advances when a transfer actually starts and stays put on Cancel (live-validated both ways). It's an undocumented key: if it's absent the helper degrades to the honest `CLOSED` outcome instead of guessing.
- Implementation: JXA `NSSharingService(sendViaAirDrop)` with a registered delegate subclass, run via `osascript` — ships with macOS, nothing to compile. Don't switch to `swift -e`: it breaks whenever the CLT compiler and the macOS SDK drift apart.
