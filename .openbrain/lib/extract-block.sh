#!/usr/bin/env bash
# extract-block.sh — print a marked range out of a SKILL.md (or similar
# markdown) file without copying or paraphrasing it. Two modes:
#
#   bash extract-block.sh <file> <marker-name>
#     Body strictly between "# --- <marker-name> ---" and its terminator:
#     (1) a whole line EXACTLY "# --- end
#     <marker-name> ---" (the FULL marker text — no prefix aliasing,
#     no load-bearing inference) anywhere after the start marker, wins
#     even if a ``` fence appears first (a body may contain a fenced
#     example); (2) else the next literal ``` line (a block whose whole
#     payload IS one fenced code block); (3) else CANNOT-CHECK "no
#     terminator". A duplicated end marker is CANNOT-CHECK naming the count.
#     While scanning, ANY OTHER line matching `^# --- .* ---$` is a foreign
#     marker (a sibling's start/end line, or an end marker not repeating the
#     full start text) — CANNOT-CHECK naming the line, never silently
#     swallowed into the body or used as its terminator. An end-shaped
#     foreign line matters up to this block's own end marker if it has one,
#     else unconstrained; a start-shaped one only if it falls before the
#     chosen terminator (the ordinary sibling-blocks-in-one-file case is
#     unaffected). Anchor: whole-line string equality, never substring,
#     never regex — same for the end marker and the foreign check.
#
#     Optional `--require-end-marker` (marker mode only, before or after <marker-name>): refuses the fence fallback — a caller that knows its block is prose and must never accept a fence-truncated body.
#
#   bash extract-block.sh <file> --section <heading>
#     Lines after the line EXACTLY matching the heading, up to (excluding)
#     the next heading OUTSIDE a fence whose LEVEL (leading '#' count) is the
#     SAME OR HIGHER (more '#'s stays in the body) — or to EOF if none.
#     <heading> is a full heading line only when it matches `^#{1,6} `;
#     anything else — including '#' with no following space, e.g. "#42
#     Escalation" — is level-2 TEXT, anchored as "## <heading>" verbatim. The start
#     anchor, its duplicate count, and the terminator search are all fence-gated: a heading-shaped line inside a
#     fence (a quoted example) is body, never counted, never a terminator.
#     Fences (section mode only): an opener is 3+ of the same
#     character (backtick or tilde); its closer is a line of only that
#     character, run length >= the opener's (a shorter nested run, e.g.
#     backticks inside backticks, does not close it). Still open at EOF ->
#     CANNOT-CHECK "unterminated fence" (fence state past it is unknown, so
#     no heading count past it can be trusted). Marker mode's own fence
#     stays the literal, undifferentiated ``` line, unchanged.
#     Anchor: whole-line string equality, never substring, never regex.
#     `--section` serves markdown SECTIONS (`## Findings`, or `### Open` /
#     `### Resolved` inside one); not a skill's own numbered `###` steps —
#     those are read by the executor at that heading, not extracted.
#
# Both anchors are WHOLE-LINE and LITERAL by contract, not just in the
# current implementation: a file that talks about its own structure (names
# its own marker or heading in prose, inside backticks, or inside a table
# cell) contains that text without ever producing a line that IS the anchor
# — reported as "missing," never a hit, and this script never falls back to
# a next-best/nearby range, nor to the next structural boundary when an end
# marker is declared but not found.
#
# Callers pass both <file> and this script's own path as absolute
# "$VAULT/..." paths (a skill's preflight often cds into the template clone).
# Why one shared helper: bootstrap/PII-SCAN-CONTRACT.md, "Design notes".
#
# Outcomes — three, never two, same shape for both modes:
#   0    body printed to stdout (>=1 non-blank line present). Nothing on stderr.
#   2    CANNOT-CHECK. Exactly one stderr line naming which of: usage error /
#        file unreadable / locate pass failed (awk errored, or its output was
#        malformed/truncated) / unterminated fence (section only) / start
#        anchor missing or duplicated (names the count) / end marker
#        duplicated (marker mode, names the count) / a foreign marker line
#        before this block's terminator (marker mode, names the line) / no
#        terminator (marker mode only — EOF is a valid section terminator,
#        never "missing") / body empty / print pass emitted the wrong count.
#        Nothing is ever printed to stdout on this path — anchor and
#        terminator are located and validated against a private snapshot
#        before the print pass, so a failure never leaves a partial body on
#        stdout, and this script never substitutes a next-best range.
#   127  the CALLER's shell couldn't find this script at all (not a code path
#        in here). Treat as CANNOT-CHECK: restore it from git, or re-pull the
#        template — it ships alongside /push-openbrain-template.
#
# Hardening (each guard's failure case: the contract's "Design notes"): the
# file is read ONCE into a private snapshot; anchor text reaches awk via
# ENVIRON, never `-v`; every awk/sed call gets `</dev/null` and an absolute
# path; every locate-awk field is validated as an integer before arithmetic;
# the body range is checked non-positive BEFORE `sed -n`; the print pass
# counts (awk, not `wc -l`) and blank-checks what it actually wrote.
#
# No dependencies beyond POSIX awk/sed; runs under bash 3.2 (macOS default).

set -uo pipefail

usage_err() { printf 'extract-block: CANNOT-CHECK — usage error: %s\n' "$1" >&2; exit 2; }
cannot_check() { printf 'extract-block: CANNOT-CHECK — %s\n' "$1" >&2; exit 2; }
int_or_die() { case "$1" in ''|*[!0-9]*) cannot_check "locate pass failed (malformed field)" ;; esac; }

# --require-end-marker may appear anywhere (before or after the marker name);
# strip it out here so the positional parsing below is unaffected by it. No
# arrays (bash 3.2 + set -u makes an empty array an unbound-variable error).
REQUIRE_END=0
eb_i=$#
while [ "$eb_i" -gt 0 ]; do
  eb_a="$1"; shift
  if [ "$eb_a" = "--require-end-marker" ]; then REQUIRE_END=1; else set -- "$@" "$eb_a"; fi
  eb_i=$((eb_i - 1))
done

[ "$#" -ge 1 ] || usage_err "expected 2 args (file, marker-name) or 3 args (file, --section, heading), got $#"
FILE="$1"

if [ "${2:-}" = "--section" ]; then
  [ "$#" -eq 3 ] || usage_err "--section requires exactly 3 args (file, --section, heading), got $#"
  [ "$REQUIRE_END" -eq 0 ] || usage_err "--require-end-marker is not valid with --section"
  HEADING="$3"
  [ -n "$HEADING" ] || usage_err "section heading is empty"
  MODE=section
  case "$HEADING" in
    '# '*|'## '*|'### '*|'#### '*|'##### '*|'###### '*)
      # A full heading line (1-6 '#'s then a space) supplied verbatim.
      ANCHOR_LINE="$HEADING"
      HASHES="${HEADING%%[!#]*}"
      LEVEL="${#HASHES}"
      ;;
    *)
      # No '#<space>' prefix — level-2 text, the original default contract.
      ANCHOR_LINE="## $HEADING"
      LEVEL=2
      ;;
  esac
  ANCHOR_DESC="heading"
else
  [ "$#" -eq 2 ] || usage_err "expected 2 args (file, marker-name), got $#"
  MARKER="$2"
  [ -n "$MARKER" ] || usage_err "marker name is empty"
  MODE=marker
  ANCHOR_LINE="# --- $MARKER ---"
  ANCHOR_DESC="start marker"
  END_FULL="# --- end $MARKER ---"
fi

[ -f "$FILE" ] && [ -r "$FILE" ] || cannot_check "file unreadable: $FILE"

# Snapshot once: every later pass reads this private copy, never the live
# path again. Absolute mktemp path: never a bare "x=y.md" name to awk.
SNAPSHOT="$(umask 077 && mktemp "${TMPDIR:-/tmp}/extract-block-snap.XXXXXX")" || cannot_check "could not create a snapshot temp file"
TMP_OUT="$(umask 077 && mktemp "${TMPDIR:-/tmp}/extract-block-out.XXXXXX")" || { rm -f "$SNAPSHOT"; cannot_check "could not create an output temp file"; }
trap 'rm -f "$SNAPSHOT" "$TMP_OUT"' EXIT
cat -- "$FILE" >"$SNAPSHOT" </dev/null 2>/dev/null || cannot_check "could not snapshot file: $FILE"

export EB_ANCHOR="$ANCHOR_LINE"

if [ "$MODE" = marker ]; then
  export EB_ENDFULL="$END_FULL"
  LOCATE_OUT="$(LC_ALL=C awk '
    $0==ENVIRON["EB_ANCHOR"] { c++; if (c==1) s=NR; next }
    s && $0==ENVIRON["EB_ENDFULL"] { ec++; if (ec==1) e=NR; next }
    s && !fset && $0=="```" { f=NR; fset=1; next }
    s && !fgend && $0 ~ /^# --- end .* ---$/ { fgend=NR; next }
    s && !fgstart && $0 ~ /^# --- .* ---$/ { fgstart=NR }
    END { print c+0, s+0, e+0, ec+0, f+0, fgend+0, fgstart+0 }
  ' "$SNAPSHOT" </dev/null)"
  LOCATE_RC=$?
else
  export EB_LEVEL="$LEVEL"
  LOCATE_OUT="$(LC_ALL=C awk '
  {
    if (!infence) {
      if (match($0, /^`{3,}/)) { infence=1; fchar="`"; flen=RLENGTH; next }
      if (match($0, /^~{3,}/)) { infence=1; fchar="~"; flen=RLENGTH; next }
    } else {
      tmp=$0; sub(/[ \t]+$/, "", tmp)
      if (tmp ~ ("^" fchar "+$") && length(tmp) >= flen) { infence=0; next }
      next
    }
    # infence is always 0 here (the branch above never falls through with it
    # set) -- reaching this point already IS the fence gate.
    if ($0==ENVIRON["EB_ANCHOR"]) { c++; if (c==1) s=NR }
    else if (s && !t && $0 ~ /^#+[[:space:]]/) {
      h=$0; sub(/[^#].*/, "", h)
      if (length(h) <= ENVIRON["EB_LEVEL"]+0) t=NR
    }
  }
  END { print c+0, s+0, t+0, NR+0, (infence?1:0) }
  ' "$SNAPSHOT" </dev/null)"
  LOCATE_RC=$?
fi
[ "$LOCATE_RC" -eq 0 ] || cannot_check "locate pass failed (awk rc $LOCATE_RC)"

if [ "$MODE" = marker ]; then
  read -r COUNT START ENDMARK ENDCOUNT FENCE FGEND FGSTART <<EOF_LOC
$LOCATE_OUT
EOF_LOC
  for v in "$COUNT" "$START" "$ENDMARK" "$ENDCOUNT" "$FENCE" "$FGEND" "$FGSTART"; do int_or_die "$v"; done
else
  read -r COUNT START TERM TOTAL INFENCE <<EOF_LOC
$LOCATE_OUT
EOF_LOC
  for v in "$COUNT" "$START" "$TERM" "$TOTAL" "$INFENCE"; do int_or_die "$v"; done
  [ "$INFENCE" -eq 0 ] || cannot_check "unterminated fence in $FILE (opened, never closed by EOF)"
fi

case "$COUNT" in
  0) cannot_check "$ANCHOR_DESC missing: $ANCHOR_LINE" ;;
  1) ;;
  *) cannot_check "$ANCHOR_DESC found more than once ($COUNT occurrences): $ANCHOR_LINE" ;;
esac

if [ "$MODE" = marker ]; then
  T=""
  case "$ENDCOUNT" in
    0) [ "$REQUIRE_END" -eq 1 ] && cannot_check "end marker required, not found: $ANCHOR_LINE"; [ "$FENCE" -gt 0 ] && T="$FENCE" ;;
    1) T="$ENDMARK" ;;
    *) cannot_check "end marker found more than once ($ENDCOUNT occurrences) for: $ANCHOR_LINE" ;;
  esac
  # A foreign END-shaped line ("# --- end <other> ---") is relevant up to OUR
  # OWN end marker if we have one (no aliasing, so it can only be
  # a different block's end, or ours spelled short; either way, ambiguous),
  # else unconstrained (a bare fence is not a safe fallback in its presence).
  # A foreign START-shaped line (a sibling's own start marker, the ordinary
  # shape of a multi-block file) only matters if it falls INSIDE this body,
  # i.e. before whichever terminator was chosen (the sibling-swallow case).
  FLINE_NO=0
  if [ "$FGSTART" -gt 0 ] && { [ -z "$T" ] || [ "$FGSTART" -lt "$T" ]; }; then FLINE_NO="$FGSTART"; fi
  if [ "$FGEND" -gt 0 ] && { [ "$ENDCOUNT" -ne 1 ] || [ "$FGEND" -lt "$ENDMARK" ]; }; then
    if [ "$FLINE_NO" -eq 0 ] || [ "$FGEND" -lt "$FLINE_NO" ]; then FLINE_NO="$FGEND"; fi
  fi
  if [ "$FLINE_NO" -gt 0 ]; then
    FLINE="$(LC_ALL=C sed -n "${FLINE_NO}p" "$SNAPSHOT" </dev/null)"
    cannot_check "another marker line \`$FLINE\` appears before this block's terminator (a foreign start/end marker, or an end marker that does not repeat the full start text): $ANCHOR_LINE"
  fi
  [ -n "$T" ] || cannot_check "no terminator (no '$END_FULL' and no closing fence after the start marker): $ANCHOR_LINE"
  BODY_START=$((START + 1))
  BODY_END=$((T - 1))
else
  BODY_START=$((START + 1))
  if [ "$TERM" -gt 0 ]; then BODY_END=$((TERM - 1)); else BODY_END="$TOTAL"; fi
fi

# Print pass, folded with validation: range checked non-positive BEFORE sed
# (BSD `sed -n '2,1p'` prints line 2); output counted with awk (`wc -l`
# undercounts a last line with no newline) and blank-checked before emitting.
EXPECTED=$((BODY_END - BODY_START + 1))
EMPTY_MSG="body empty"; [ "$MODE" = marker ] && EMPTY_MSG="body empty in marker block: $ANCHOR_LINE" || EMPTY_MSG="body empty in section: $ANCHOR_LINE"
[ "$EXPECTED" -gt 0 ] || cannot_check "$EMPTY_MSG"
LC_ALL=C sed -n "${BODY_START},${BODY_END}p" "$SNAPSHOT" >"$TMP_OUT" </dev/null
EMITTED="$(LC_ALL=C awk 'END{print NR+0}' "$TMP_OUT" </dev/null)"
[ "$EMITTED" -eq "$EXPECTED" ] || cannot_check "print pass emitted $EMITTED line(s), expected $EXPECTED"
LC_ALL=C grep -q '[^[:space:]]' "$TMP_OUT" </dev/null || cannot_check "$EMPTY_MSG"

cat -- "$TMP_OUT"
