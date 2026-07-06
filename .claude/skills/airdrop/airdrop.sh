#!/usr/bin/env bash
# airdrop.sh — send file(s) via the macOS AirDrop share window, from the terminal.
#
# Automates everything macOS allows: stages the files, opens the AirDrop
# window, exits the moment the session ends, and reports the outcome. Two
# actions stay human by OS design: picking the receiving device (sender side)
# and, between different Apple IDs, the Accept prompt (receiver side).
#
# Outcome detection (empirical, macOS 15/Darwin 24):
#   - NSSharingServiceDelegate is BLIND to cancel-vs-sent: didShareItems fires
#     identically for a completed transfer and for the Cancel button, and
#     willShareItems fires at window-open, not at recipient choice. So the
#     delegate only provides the fast exit, not the verdict.
#   - The verdict comes from sharingd's AfterFirstUseExpirationDate preference,
#     which advances when a transfer actually starts and stays put on Cancel
#     (verified: 3 real sends bumped it, 3 cancels did not). Undocumented key,
#     so an absent/unreadable value degrades to an honest CLOSED outcome
#     rather than a guess.
#
# Usage: airdrop.sh <file> [file...]
#   AIRDROP_KEEPALIVE=<seconds>  backstop timeout for an abandoned window
#                                (default 600). All interactive endings exit
#                                immediately regardless.
#
# Output (last line) / exit code:
#   SENT       0  transfer started and window closed normally
#   DISMISSED  1  window closed without a transfer (Cancel)
#   FAILED:..  1  sharing service reported an error
#   TIMEOUT:.. 1  nobody interacted with the window
#   CLOSED:..  2  window closed but this system offers no way to verify
set -euo pipefail

MARKER="openbrain-airdrop-sheet"
AFU_KEY="AfterFirstUseExpirationDate"

[ "$(uname)" = "Darwin" ] || { echo "airdrop: AirDrop requires macOS" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: airdrop.sh <file> [file...]" >&2; exit 1; }

KEEPALIVE="${AIRDROP_KEEPALIVE:-600}"

files=()
for f in "$@"; do
  [ -e "$f" ] || { echo "airdrop: no such file: $f" >&2; exit 1; }
  files+=("$(cd -- "$(dirname -- "$f")" && pwd)/$(basename -- "$f")")
done

# A helper orphaned by a previous run holds a ghost window on screen; clear it.
# Match only the osascript helper (its -e program embeds the marker) — never
# this script itself, even if a repo path happens to contain the marker string.
pkill -f "osascript.*$MARKER" 2>/dev/null && sleep 1 || true

afu_read() { defaults read com.apple.sharingd "$AFU_KEY" 2>/dev/null || echo "ABSENT"; }
AFU_BEFORE="$(afu_read)"

JXA='function run(argv) { /* '"$MARKER"' */
  ObjC.import("AppKit");
  const app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
  app.activateIgnoringOtherApps(true);

  let outcome = null;
  ObjC.registerSubclass({
    name: "AirdropDelegate",
    protocols: ["NSSharingServiceDelegate"],
    methods: {
      "sharingService:didShareItems:": {
        types: ["void", ["id", "id"]],
        implementation: function (service, items) { outcome = "ENDED"; }
      },
      "sharingService:didFailToShareItems:error:": {
        types: ["void", ["id", "id", "id"]],
        implementation: function (service, items, error) {
          outcome = "FAILED: " + error.localizedDescription.js;
        }
      }
    }
  });
  const delegate = $.AirdropDelegate.alloc.init;

  const keepalive = parseInt(argv[0], 10);
  const urls = $.NSMutableArray.alloc.init;
  for (let i = 1; i < argv.length; i++) {
    urls.addObject($.NSURL.fileURLWithPath(argv[i]));
  }

  const svc = $.NSSharingService.sharingServiceNamed($.NSSharingServiceNameSendViaAirDrop);
  if (svc.isNil()) { return "FAILED: AirDrop sharing service unavailable"; }
  svc.delegate = delegate;
  svc.performWithItems(urls);

  const ticks = Math.ceil(keepalive / 0.25);
  for (let t = 0; t < ticks && outcome === null; t++) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.25));
  }
  return outcome === null
    ? "TIMEOUT: no interaction with the window within " + keepalive + "s"
    : outcome;
}'

echo "Opening the AirDrop window (${#files[@]} file(s))..." >&2
echo "  1. Click the receiving device, then leave the window alone (Cancel aborts; Esc does nothing)." >&2
echo "  2. Different Apple IDs: answer the Accept prompt on the receiving machine." >&2

result="$(osascript -l JavaScript -e "$JXA" "$KEEPALIVE" "${files[@]}")" \
  || { echo "airdrop: osascript helper crashed" >&2; exit 1; }

if [ "$result" = "ENDED" ]; then
  AFU_AFTER="$(afu_read)"
  if [ "$AFU_BEFORE" = "ABSENT" ] || [ "$AFU_AFTER" = "ABSENT" ]; then
    echo "CLOSED: window closed; sent-vs-cancelled not verifiable on this system"
    exit 2
  elif [ "$AFU_AFTER" != "$AFU_BEFORE" ]; then
    echo "SENT"
    exit 0
  else
    echo "DISMISSED: window closed without a transfer (Cancel)"
    exit 1
  fi
fi

echo "$result"
exit 1
