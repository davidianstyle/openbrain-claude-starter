#!/usr/bin/env bash
# receiving-pii-scan.sh — incoming PII gate (the pull skill's step 1b). The
# inverse of an outgoing pattern gate: that scans OUTGOING pushed lines against this
# machine's patterns; this scans INCOMING template content about to be written into the
# vault by /pull-openbrain-template, BEFORE de-genericization (skill step 4).
#
# Why pre-de-genericization: legitimate incoming template content is GENERIC
# ({{USER_NAME}}, "the user", Jane Q. Doe). The pull then deliberately re-adds
# the user's real name into the user's own vault — so scanning post-apply would
# false-positive on every file. A hit on the RAW incoming side means this
# machine's own PII is sitting in content that's supposed to be generic — an
# upstream genericization miss. That cannot false-positive in normal flow.
#
# Nothing is remembered or exempted across runs — why: bootstrap/PII-SCAN-CONTRACT.md, "Why nothing is remembered".
#
# Matching: fixed-string after NFC + casefold on both sides, plus whole-word for `word:` entries
# (template-scope.sh's pii_match — the matcher push's step 4 uses too).
#
# Semantics (i): scans ONE incoming candidate per call so a hit blocks exactly
# that file — the caller leaves it un-applied and proceeds with the rest.
#
# Usage: receiving-pii-scan.sh <patterns-file> <incoming-file>
#   Always the WHOLE incoming file, never a delta against the vault copy: PII this
#   vault once pushed comes back on lines IDENTICAL to the vault's own, which a
#   delta never sees. A third argument (the retired delta mode) is a usage error.
# Exit: 0 = clean (or no patterns/no pattern file), 1 = PII match, 2 = usage
#   or CANNOT-CHECK (grep could not read the file — never treated as clean).

set -uo pipefail

PATFILE="${1:-}"; NEW="${2:-}"
{ [ "$#" -eq 2 ] && [ -n "$PATFILE" ] && [ -n "$NEW" ]; } || {
  echo "receiving-pii-scan: usage: <patterns-file> <incoming-file> (the whole file is scanned; there is no vault-file delta mode)" >&2; exit 2; }
[ -f "$NEW" ] || { echo "receiving-pii-scan: incoming file not found: $NEW" >&2; exit 2; }

if [ ! -f "$PATFILE" ]; then
  echo "receiving-pii-scan WARNING: no $PATFILE — incoming PII gate inactive on this machine." >&2
  exit 0
fi

# Pattern extraction — through template-scope.sh's pii_patterns(), the one normalizer push uses too
# (BOM, CR, padding, comments; a bare "word:" is dropped), so a CRLF-saved or padded file matches here
# exactly as it does on the way out, instead of silently matching nothing.
LIB="$(cd "$(dirname "$0")" && pwd)/template-scope.sh"
[ -f "$LIB" ] || { echo "receiving-pii-scan: CANNOT-CHECK — template-scope.sh missing beside this script ($LIB)" >&2; exit 2; }
source "$LIB"; typeset -f pii_patterns >/dev/null 2>&1 && typeset -f pii_match >/dev/null 2>&1 || { echo "receiving-pii-scan: CANNOT-CHECK — pii_patterns()/pii_match() did not load from $LIB" >&2; exit 2; }
NORM="$(mktemp)"; PATS="$(mktemp)"; WPATS="$(mktemp)"; HITS="$(mktemp)"; trap 'rm -f "$NORM" "$PATS" "$WPATS" "$HITS"' EXIT
pii_patterns "$PATFILE" > "$NORM" || { echo "receiving-pii-scan: CANNOT-CHECK — could not read $PATFILE" >&2; exit 2; }
grc=0; LC_ALL=C command grep -v '^word:' "$NORM" > "$PATS" || grc=$?; [ "$grc" -le 1 ] || { echo "receiving-pii-scan: CANNOT-CHECK — could not split $PATFILE (grep exit $grc)" >&2; exit 2; }   # rc 1 = no plain entries: an answer
LC_ALL=C sed -n 's/^word://p' "$NORM" > "$WPATS" || { echo "receiving-pii-scan: CANNOT-CHECK — could not split $PATFILE (sed)" >&2; exit 2; }
# Zero active entries (empty, or comments only) deactivates the scan exactly
# like a missing file — warn the same way, never pass silently.
if [ ! -s "$PATS" ] && [ ! -s "$WPATS" ]; then
  echo "receiving-pii-scan WARNING: $PATFILE has no active patterns — incoming PII gate inactive on this machine." >&2
  exit 0
fi

# The whole incoming file, read as bytes by template-scope.sh's pii_match — the same matcher push's step 4 uses: NFC +
# casefold on both sides (a non-ASCII name in any case or normal form matches), a NUL byte or a non-UTF-8 byte never
# hides a line. rc 0/1 are answers; anything else is CANNOT-CHECK.
scan_with() {   # scan_with <plain|word> <pattern file>
  local mrc=0
  [ -s "$2" ] || return 0
  pii_match "$1" "$2" "$NEW" >> "$HITS" || mrc=$?
  [ "$mrc" -le 1 ] || { echo "receiving-pii-scan: CANNOT-CHECK — pii_match exit $mrc on '$NEW'" >&2; exit 2; }
}
scan_with plain "$PATS"; scan_with word "$WPATS"
hits="$(head -10 "$HITS")"

if [ -n "$hits" ]; then
  echo "receiving-pii-scan BLOCKED: incoming content for '$NEW' contains this machine's PII:" >&2
  echo "$hits" | sed 's/^/  /' >&2
  echo "Upstream genericization miss. Do NOT apply this file; fix at the source (re-genericize" >&2
  echo "the topic) or override knowingly. Other files in the batch are unaffected." >&2
  exit 1
fi
exit 0
