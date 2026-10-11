# template-scope.sh — the ONE definition of what is portable between this
# vault and the openbrain-claude-starter template. Sourced (never executed)
# by every sync skill that needs it (/push-openbrain-template and
# /pull-openbrain-template, and any skill layered on them) — always by absolute
# path, since a skill's own preflight routinely `cd`s into the template
# clone before this would be sourced:
#
#   source "$VAULT/.openbrain/lib/template-scope.sh"
#
# Previously, push defined deny() twice inline (its step-1 enumerate block and
# its step-4 scan block) and pull's plan block awk-extracted deny() out of
# push's live SKILL.md text at runtime, then `eval`'d it and ran a behaviour
# probe to confirm it survived the trip. Three near-duplicates of one policy.
# This file replaces all three: it is shared EXECUTABLE logic, and David's
# upstream convention is that shared executable logic lives in `.openbrain/
# lib/` as a real file, never extracted out of another skill's markdown at
# runtime (a live-text awk-extraction was a workaround for not having this
# file, not a pattern to keep).
#
# Why a NEW file, and not a section added to `.openbrain/lib/_common.sh`:
# _common.sh is David's upstream MCP-launcher library. Its runtime locus is
# `~/.config/openbrain/lib/` — `bootstrap/lib/register-mcps.sh` deploys the
# managed launcher set (the `*-mcp.sh` scripts + `_common.sh`) there, and
# `reconcile-runtime.sh` drift-checks the deployed copy against the repo
# copy. Adding scope logic to _common.sh would deploy this file's every edit
# into the MCP runtime and flag DRIFT on every one of them, for a concern
# (what is portable to a template) that the MCP runtime has no need of and
# no business tracking. template-scope.sh is clone/vault-tier sync tooling,
# the same tier as `assert-no-vault-remote.sh` — it
# never deploys to `~/.config/openbrain/lib/` and reconcile-runtime.sh never
# looks at it. Kept out of `register-mcps.sh`'s managed set for the same
# reason (see the comment at its LIB_DIR deploy step).
#
# Callers: push (step 1 "enumerate", step 4 "scan"), pull (step 1 "plan" —
# sources this instead of extracting deny() from push's live text), share
# and take (inherit it via the push/pull blocks they execute by reference —
# neither sources it directly).
#
# Three-outcome contract for every caller, before using deny() or in_roots().
# `type` is NOT the check: a shell function and a same-named external command
# on PATH both satisfy `type deny` in bash and zsh alike, so an empty or
# truncated lib plus a stray `deny`/`in_roots` binary on PATH would silently
# "load." `typeset -f` only ever matches a shell FUNCTION:
#
#   LIB="$VAULT/.openbrain/lib/template-scope.sh"
#   [ -f "$LIB" ] || { echo "STOP: CANNOT-CHECK — template-scope.sh missing at $LIB; restore it from git, or re-pull the template — it ships alongside /push-openbrain-template"; exit 1; }
#   source "$LIB"
#   typeset -f deny >/dev/null 2>&1 && typeset -f in_roots >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — template-scope.sh sourced but deny()/in_roots() did not load"; exit 1; }
#
# A missing or broken lib is CANNOT-CHECK, exactly like any other missing
# checker in this project (never a silent pass with an empty or unfiltered
# scope). This file itself only defines functions and constants: no
# `set -e`, no `exit`, nothing that could tear down a caller's shell on
# source, and bash-3.2/zsh compatible throughout (no bash-4-only features:
# no associative arrays, no `${var,,}`, no `mapfile`).

# .openbrain/vault-remotes is the vault OWN remote-URL pattern list (read by assert-no-vault-remote.sh): per-vault, never portable.
# Home.md (root only) is the vault front door: content regenerated from the vault notes, so a reference to it is documentation, never a dependency.
deny() {   # the hard-deny list — moved verbatim from push's two inline copies and pull's extracted eval. Case-folded (APFS is case-insensitive); POSIX awk so BSD and GNU behave alike
  LC_ALL=C awk '{ l = tolower($0) }
    l ~ /^\+ extras\/templates\//   { print; next }
    l ~ /^\+ /                      { next }
    l ~ /^\.openbrain\/local\//     { next }
    l ~ /^\.openbrain\/vault-remotes$/ { next }
    l == "home.md"                  { next }
    l ~ /^\.claude\/projects\//     { next }
    l ~ /^bin\//                    { next }
    l ~ /(^|\/)\.env($|\.)/         { next }
    { print }' "$1"
}

# PORTABLE_ROOTS — the default scope: everything push and pull compare by
# default. Derived from David's upstream push/pull SKILL.md "Scope" tables
# (no line numbers cited, so this file cannot drift out of sync with them). A newline-separated
# string constant, not a bash array: this file is sourced under both bash 3.2
# (macOS system /bin/bash) and zsh (the shell the Bash tool actually runs),
# and mixing array syntax across those reliably is more fragile than one
# `read`-friendly string.
#
# Declared, not inferred: a root ending in `/` is a DIRECTORY prefix; a root
# with no trailing `/` is an EXACT file path. This is a fact about the root
# itself, stated once here, never guessed downstream from its spelling (a
# `.md`/`.json` suffix test was tried and rejected — CLAUDE.md §10, "make the
# truth declarable" — because `.claude` and `.openbrain` are dot-DIRECTORIES
# and a suffix-based test has no way to say so).
PORTABLE_ROOTS=$'.claude/skills/
.openbrain/
+ Extras/Templates/
bootstrap/
CLAUDE.md
README.md
.obsidian/app.json
.obsidian/core-plugins.json
.obsidian/appearance.json
.obsidian/graph.json'
# A vault that gitignores .obsidian/graph.json never enumerates it from
# `git ls-files` — harmless to list; it just never contributes a path.
#
# `bootstrap/` IS a default root (upstream pull: "include in diff, but
# flag for careful review") — but upstream push says the opposite:
# "only update if explicitly asked." Both are David's own text, for two
# different directions of the same sync, and this file follows each skill's
# own upstream rule rather than picking one side for both. PUSH_ALL_OMITS is
# what push's `all` hint subtracts from PORTABLE_ROOTS to honor its own
# narrower rule; pull's `TOPIC=upstream` plan uses PORTABLE_ROOTS unmodified,
# so a `bootstrap/` change upstream reaches the vault exactly as David's pull
# text says it should (flagged for careful review, `bootstrap/setup.sh`
# re-run — see /pull-openbrain-template §3 and §5b).
# shellcheck disable=SC2034   # consumed by push-openbrain-template/SKILL.md after sourcing this file, not used within it
PUSH_ALL_OMITS=$'bootstrap/'

portable_roots() { printf '%s\n' "$PORTABLE_ROOTS"; }   # one root per line — a caller builds a pathspec array from this with a `while read` loop, e.g.:
#   ROOTSPEC=(); while IFS= read -r r; do [ -n "$r" ] && ROOTSPEC+=("$r"); done < <(portable_roots)
#   git -c core.quotePath=false ls-files -co --exclude-standard -- "${ROOTSPEC[@]}"
# (a directory root carries its trailing `/`; `git ls-files -- 'dir/'` and
# `git ls-files -- 'dir'` enumerate identically, verified live, so no
# stripping is needed before handing a root to git as a pathspec.)

# in_roots <pathfile> — filter a file of one-path-per-line (as `git ls-files`
# emits) down to the paths that fall under a PORTABLE_ROOTS entry. A
# directory root (trailing `/`) matches itself (sans the slash) or anything
# under it; a file root (no trailing `/`, e.g. `CLAUDE.md`) matches only that
# exact path. Case-folded like deny(), for the same reason (APFS is
# case-insensitive, so a path that differs from a root only in case is still
# the same file on this filesystem).
in_roots() {
  # roots go through ENVIRON, never `awk -v`: a `-v` value containing a
  # literal newline is a hard "newline in string" error on BSD awk (macOS),
  # and `-v` also silently backslash-unescapes its value either way.
  PORTABLE_ROOTS="$PORTABLE_ROOTS" LC_ALL=C awk '
    BEGIN {
      n = split(ENVIRON["PORTABLE_ROOTS"], r, "\n")
      for (i = 1; i <= n; i++) {
        root[i] = tolower(r[i])
        isdir[i] = (root[i] ~ /\/$/)                    # declared by the trailing slash, never inferred from spelling
        if (isdir[i]) { bare[i] = substr(root[i], 1, length(root[i]) - 1) } else { bare[i] = root[i] }
      }
    }
    { l = tolower($0)
      for (i = 1; i <= n; i++) {
        if (isdir[i]) { if (l == bare[i] || index(l, root[i]) == 1) { print; next } }
        else          { if (l == bare[i]) { print; next } }
      }
    }' "$1"
}

# pii_patterns <file> — the ONE normalizer for a machine's `.openbrain/local/pii-patterns`, used by push's
# step-4 scan and pull's incoming scan (receiving-pii-scan.sh + the DP2 coverage count) so the two can never
# read the same file differently. Strips a UTF-8 BOM, CR line ends and padding; drops comments and blanks.
# A `word:` entry comes out as `word:<entry>` (padding inside trimmed too); a bare `word:` is dropped.
# A `re:` entry has no effect here (`re:` is pii-fakes.txt syntax): it passes through as a plain substring and a
# warning naming its line number (never the entry) goes to stderr.
# One entry per line on stdout; the exit status is awk's (an unreadable file is non-zero, never an empty "clean").
pii_patterns() {
  LC_ALL=C awk 'NR==1{sub(/^\357\273\277/,"")} {sub(/\r$/,""); sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,"")} /^#/||/^$/{next}
    /^re:/ {printf "pii-patterns WARNING: line %d: a `re:` entry has no effect (re: is pii-fakes.txt syntax; matched as a plain substring)\n", NR > "/dev/stderr"}
    /^word:/ {w=substr($0,6); sub(/^[[:space:]]+/,"",w); if (w=="") next; print "word:" w; next} {print}' "$1"
}

# pii_match <plain|word> <entries-file> <text-file> — the ONE matcher for pii-patterns entries (push's step-4 scan and pull's
# incoming scan). Both sides are Unicode-normalized (NFC) and casefolded before comparing, so `café` matches `CAFÉ` and an
# NFD-written entry matches NFC text; `LC_ALL=C grep -i` folds ASCII only and missed both. `plain`: substring; `word`: whole
# word (no letter, digit or `_` either side). Text is read as bytes, one line per newline; a line that is not UTF-8 is
# decoded with replacement, so its ASCII still matches. Prints `<line>:<text>` per matching line (grep -n shape).
# Exit: 0 = a match, 1 = none, 2 = could not read or run (never an empty "clean").
pii_match() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys, unicodedata
mode, pf, tf = sys.argv[1:4]
if mode not in ("plain", "word"): sys.exit(2)
norm = lambda s: unicodedata.normalize("NFC", unicodedata.normalize("NFC", s).casefold())
try:
    pats = [norm(l.rstrip("\r\n")) for l in open(pf, encoding="utf-8", errors="replace") if l.strip()]
    data = open(tf, "rb").read()
except OSError as e:
    print("pii_match: cannot read: %s" % e, file=sys.stderr); sys.exit(2)
if mode == "word": rx = [re.compile(r"(?<!\w)" + re.escape(p) + r"(?!\w)") for p in pats]
hit = 0
lines = data.split(b"\n")
if lines and lines[-1] == b"": lines.pop()
for n, raw in enumerate(lines, 1):
    t = raw.decode("utf-8", "replace"); s = norm(t)
    if any((p in s) for p in pats) if mode == "plain" else any(r.search(s) for r in rx):
        hit = 1; sys.stdout.write("%d:%s\n" % (n, t))
sys.exit(0 if hit else 1)
PY
}
