# template-scope.sh — the ONE definition of what is portable between this
# vault and the openbrain-claude-starter template. Sourced (never executed)
# by every sync skill that needs it (/push-openbrain-template and
# /pull-openbrain-template, and any skill layered on them) — always by absolute
# path, since a skill's own preflight routinely `cd`s into the template
# clone before this would be sourced:
#
#   source "$VAULT/.openbrain/lib/template-scope.sh"
#
# Clone/vault-tier sync tooling: never deployed to `~/.config/openbrain/lib/`,
# never in register-mcps.sh's managed set, never drift-checked by
# reconcile-runtime.sh. Why a file of its own: bootstrap/PII-SCAN-CONTRACT.md,
# "Design notes".
#
# Callers: push (step 1 "enumerate", step 4 "scan"), pull (step 1 "plan"),
# share and take (inherit it via the push/pull blocks they execute by
# reference — neither sources it directly).
#
# Three-outcome contract for every caller, before using deny() or in_roots().
# `typeset -f`, not `type`: a same-named external command on PATH satisfies
# `type`, so an empty lib plus a stray binary would silently "load":
#
#   LIB="$VAULT/.openbrain/lib/template-scope.sh"
#   [ -f "$LIB" ] || { echo "STOP: CANNOT-CHECK — template-scope.sh missing at $LIB; restore it from git, or re-pull the template — it ships alongside /push-openbrain-template"; exit 1; }
#   source "$LIB"
#   typeset -f deny >/dev/null 2>&1 && typeset -f in_roots >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — template-scope.sh sourced but deny()/in_roots() did not load"; exit 1; }
#
# A missing or broken lib is CANNOT-CHECK, never a silent pass with an empty
# or unfiltered scope. This file only defines functions and constants: no
# `set -e`, no `exit`, nothing that could tear down a caller's shell on
# source, and bash-3.2/zsh compatible throughout (no associative arrays, no
# `${var,,}`, no `mapfile`).

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
# default. A newline-separated string, not an array: sourced under bash 3.2
# and zsh alike.
#
# Declared, not inferred: a root ending in `/` is a DIRECTORY prefix; a root
# with no trailing `/` is an EXACT file path, never guessed from its spelling.
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
# PUSH_ALL_OMITS is what push's `all` hint subtracts from PORTABLE_ROOTS:
# push updates `bootstrap/` only when asked (the `bootstrap` hint or a path
# under it). Pull's `TOPIC=upstream` plan uses PORTABLE_ROOTS unmodified, so
# an upstream `bootstrap/` change is offered, flagged for careful review (see
# /pull-openbrain-template §3 and §5b). Why the two differ: the contract's
# "Design notes".
# shellcheck disable=SC2034   # consumed by push-openbrain-template/SKILL.md after sourcing this file, not used within it
PUSH_ALL_OMITS=$'bootstrap/'

portable_roots() { printf '%s\n' "$PORTABLE_ROOTS"; }   # one root per line — a caller builds a pathspec array from this with a `while read` loop, e.g.:
#   ROOTSPEC=(); while IFS= read -r r; do [ -n "$r" ] && ROOTSPEC+=("$r"); done < <(portable_roots)
#   git -c core.quotePath=false ls-files -co --exclude-standard -- "${ROOTSPEC[@]}"
# (a directory root's trailing `/` needs no stripping: git enumerates
# `dir/` and `dir` identically.)

# in_roots <pathfile> — filter a file of one-path-per-line (as `git ls-files`
# emits) down to the paths that fall under a PORTABLE_ROOTS entry. A
# directory root (trailing `/`) matches itself (sans the slash) or anything
# under it; a file root (no trailing `/`, e.g. `CLAUDE.md`) matches only that
# exact path. Case-folded like deny() (APFS is case-insensitive).
in_roots() {
  # roots go through ENVIRON, never `awk -v`: BSD awk rejects a newline in a
  # `-v` value, and `-v` backslash-unescapes it.
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
# step-4 scan. Strips a UTF-8 BOM, CR line ends and padding; drops comments and blanks.
# A `word:` entry comes out as `word:<entry>` (padding inside trimmed too); a bare `word:` is dropped.
# A `re:` entry has no effect here (`re:` is pii-fakes.txt syntax): it passes through as a plain substring and a
# warning naming its line number (never the entry) goes to stderr.
# One entry per line on stdout; the exit status is awk's (an unreadable file is non-zero, never an empty "clean").
pii_patterns() {
  LC_ALL=C awk 'NR==1{sub(/^\357\273\277/,"")} {sub(/\r$/,""); sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,"")} /^#/||/^$/{next}
    /^re:/ {printf "pii-patterns WARNING: line %d: a `re:` entry has no effect (re: is pii-fakes.txt syntax; matched as a plain substring)\n", NR > "/dev/stderr"}
    /^word:/ {w=substr($0,6); sub(/^[[:space:]]+/,"",w); if (w=="") next; print "word:" w; next} {print}' "$1"
}

# pii_match <plain|word> <entries-file> <text-file> — the ONE matcher for pii-patterns entries (push's step-4 scan).
# Both sides are Unicode-normalized (NFC) and casefolded before comparing, so `café` matches `CAFÉ` and an
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
