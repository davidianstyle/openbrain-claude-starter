# flag-pass.sh — the agent flag pass's two builders and its reply check, used by
# /push-openbrain-template: focus_brief (step 5a, `push-skill: full-diff`) writes
# the focus list and the agent's brief; flags_check (step 5b,
# `push-skill: flags-check`) checks the agent's reply. Shared executable logic
# lives here, in .openbrain/lib/, sourced, never extracted from a skill's
# markdown. Sourced (never executed), always by absolute path — a calling
# block may have `cd`ed into the template clone:
#
#   FP="${VAULT:?}/.openbrain/lib/flag-pass.sh"; [ -f "$FP" ] || { echo "STOP: CANNOT-CHECK — …"; exit 1; }
#   . "$FP"; typeset -f focus_brief >/dev/null 2>&1 && typeset -f flags_check >/dev/null 2>&1 || { echo "STOP: …(the same line)"; exit 1; }
#
# `typeset -f`, not `type`: a same-named binary on PATH must not satisfy the
# check. Each function is a subshell `name() ( … )`, so a failure inside it
# ends only the function, with a nonzero rc — after its own `STOP: CANNOT-CHECK
# — …` line, or the shell's own message for an unset variable — and its
# variables never leak into the caller; every call branches on the rc —
# `focus_brief || exit 1` — never bare.
#
# Interface is env-based: focus_brief runs in the caller's cwd (the template
# clone), under umask 077, reads SCAN_DIR (full.diff, paths-5a.txt), BASE and VAULT,
# and writes $SCAN_DIR/vocab.txt + brief.txt; flags_check reads SCAN_DIR and
# writes $SCAN_DIR/flags.ok on a pass only.
#
# Not _common.sh: that file deploys to the MCP runtime and is drift-checked
# there. This name does not match `*-mcp.sh`, so register-mcps.sh and
# reconcile-runtime.sh never deploy or check it. No `set -e`, no top-level
# `exit`; bash-3.2/zsh-safe.

FLAG_PASS_FAKES_REL=bootstrap/lib/pii-fakes.txt   # relative to $VAULT: the one definition — focus_brief reads it, full-diff names it on its last line

focus_brief() (
umask 077; : "${SCAN_DIR:?}"; : "${BASE:?}"; [ -s "$SCAN_DIR/full.diff" ] && [ -f "$SCAN_DIR/paths-5a.txt" ] || { echo "STOP: CANNOT-CHECK — focus-brief needs $SCAN_DIR/full.diff and paths-5a.txt (its caller writes them)"; exit 1; }
FILE_EXTS='md sh py json txt tsv csv yml yaml toml js ts mjs lst log diff patch example html css plist'   # the same literal as step 4's
python3 - "$SCAN_DIR/full.diff" "$BASE" "$SCAN_DIR/paths-5a.txt" "$FILE_EXTS" > "$SCAN_DIR/vocab.txt" <<'PY' || { echo "STOP: CANNOT-CHECK — vocabulary builder failed (reading the tree at $BASE, or an unparseable diff)"; exit 1; }
import re, subprocess, sys
diff, base, pathsz, exts = sys.argv[1], sys.argv[2], sys.argv[3], set(sys.argv[4].split())
PROSE = (".md", ".txt", ".example")    # every added line of these is prose; elsewhere, whole comment lines only
TOK = re.compile(r"[A-Za-z0-9_'-]+")
toks = lambda t: [w.strip("'-") for w in TOK.findall(t) if len(w.strip("'-")) >= 3]
# the base-tree vocabulary: every token of every text blob at BASE, lowercased — no dictionary filter
ls = subprocess.run(["git", "ls-tree", "-r", "-z", base], capture_output=True, check=True).stdout.split(b"\0")
oids = [e.split(b"\t")[0].split()[2] for e in ls if e and e.split(b"\t")[0].split()[1] == b"blob"]
if not oids: sys.exit("no blobs at " + base)
cat = subprocess.run(["git", "cat-file", "--batch"], input=b"".join(o + b"\n" for o in oids), capture_output=True, check=True).stdout
vocab, i = set(), 0
while i < len(cat):
    j = cat.index(b"\n", i); size = int(cat[i:j].split()[2]); blob = cat[j + 1:j + 1 + size]; i = j + 2 + size
    if b"\0" not in blob: vocab.update(w.lower() for w in toks(blob.decode("utf-8", "replace")))
added, cur, n, hdr, order = [], None, 0, False, {}
for raw in open(diff, encoding="utf-8", errors="replace"):
    l = raw.rstrip("\n")
    if l.startswith("diff --git "): hdr = True; cur = None; continue
    if hdr and l.startswith("+++ "):
        cur = None if l == "+++ /dev/null" else l[6:].rstrip("\t"); order.setdefault(cur, len(order)); continue
    if l.startswith("@@"): hdr = False; n = int(re.match(r"@@ -\S+ \+(\d+)", l).group(1)); continue
    if hdr or cur is None: continue
    if l.startswith("+"): added.append((cur, n, l[1:])); n += 1
    elif not l.startswith(("-", "\\")): n += 1
def prose(f, t):
    s = t.strip()
    if f.endswith(PROSE): return True
    return (s.startswith("#") and not s.startswith("#!")) or s.startswith(("//", "<!--"))
rows, code, fnames = [], {}, {}
FNAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\.([A-Za-z0-9]+)")
for f, n, t in added:
    new = [w for w in toks(t) if w.lower() not in vocab]
    if not new: continue
    if prose(f, t):
        cap = any(w[0].isupper() for w in new); num = any(c.isdigit() for w in new for c in w)
        rows.append(((not cap, not num, -len(set(new)), order[f], n), f, n, t.strip(), new))
    else:   # code lines: each new identifier-looking token once, at its first place (a prose line is never listed twice)
        for w in new:
            if re.search(r"_|[a-z][A-Z]|[A-Za-z][0-9]|[0-9][A-Za-z]", w): code.setdefault(w, (f, n))
        for m in FNAME.finditer(t):   # a filename-like string on a code line: its new words (the scanner counts the name itself)
            if m.group(1).lower() not in exts: continue
            nw = [w for w in re.split(r"[-_.]", m.group(0)[:-len(m.group(1)) - 1]) if len(w) >= 3 and w.lower() not in vocab]
            if nw: fnames.setdefault(m.group(0), (f, n, nw))
# new path segments: a directory or file name of this change that no path at BASE contains
bsegs = set(s for p in subprocess.run(["git", "ls-tree", "-r", "-z", "--name-only", base], capture_output=True, check=True).stdout.decode("utf-8", "replace").split("\0") if p for s in p.split("/"))
segs = {}
for p in open(pathsz, "rb").read().decode("utf-8", "replace").split("\0"):
    for sg in (p.split("/") if p else []):
        if sg not in bsegs: segs.setdefault(sg, p)
# one entry per line, each with an id: capitalized new tokens first, then numbers, then most new tokens; then path
# segments, filename words and code tokens
out = ["%s:%d | %s | new: %s" % (f, n, t, ", ".join(dict.fromkeys(new))) for _, f, n, t, new in sorted(rows)]
out += ["%s:path | (path segment) %s | new: %s" % (p, sg, sg) for sg, p in sorted(segs.items())]
out += ["%s:%d | (filename) %s | new: %s" % (f, n, nm, ", ".join(dict.fromkeys(nw))) for nm, (f, n, nw) in sorted(fnames.items())]
out += ["%s:%d | (code token) %s | new: %s" % (f, n, w, w) for w, (f, n) in sorted(code.items())]
for i, l in enumerate(out, 1): print("v%d | %s" % (i, l))
PY
# the agent's brief, generated: the fakes rule is built from bootstrap/lib/pii-fakes.txt at every run, never written into this skill
FAKES="${VAULT:?}/$FLAG_PASS_FAKES_REL"
[ -s "$FAKES" ] || { echo "STOP: CANNOT-CHECK — the declared-fakes list is missing at $FAKES; restore it from git (it ships with the scanner contract)"; exit 1; }
python3 - "$FAKES" "$SCAN_DIR" > "$SCAN_DIR/brief.txt" <<'PY' || { cat "$SCAN_DIR/brief.txt" >&2; rm -f "$SCAN_DIR/brief.txt"; echo "STOP: CANNOT-CHECK — could not build the agent brief from $FAKES (see above)"; exit 1; }
import re, sys
fakesf, sd = sys.argv[1], sys.argv[2]
L = [l.rstrip("\n") for l in open(fakesf, encoding="utf-8")]
exact, regs = [], []
for i, l in enumerate(L):
    if not l.strip() or l.lstrip().startswith("#"): continue
    if l.startswith("exact:"): exact.append(l[6:]); continue
    if l.startswith("re:"):
        try: re.compile(l[3:])
        except re.error as e: print("pii-fakes.txt line %d: re: entry does not compile (%s)" % (i + 1, e)); sys.exit(1)
        m = L[i - 1] if i else ""
        if not m.startswith("# means:") or not m[8:].strip(): print("pii-fakes.txt line %d: re: entry has no '# means:' line directly above it — every pattern carries its plain meaning" % (i + 1)); sys.exit(1)
        regs.append((l[3:], m[8:].strip())); continue
    print("pii-fakes.txt line %d: entry is neither exact: nor re:" % (i + 1)); sys.exit(1)
if not exact or not regs: print("pii-fakes.txt holds no exact: or no re: entries"); sys.exit(1)
P = lambda f: "%s/%s" % (sd, f)
print("""You are reviewing a change that is about to be published in a public repository. Read these files, and only these:
- the diff: %s
- its focus list: %s — one item per line, `<id> | <file>:<line> | <text> | new: <words>`: added lines, path segments, filename words and code tokens holding words the rest of the repository never uses (`<line>` is `path` for a path segment; a `(path segment)`, `(filename)` or `(code token)` label before the text is not part of it)
- the NER list: %s — one item per line, `<id> | <type> | <file>:<line>, … | «<text>»`: every distinct string a name/email/phone/URL detector found in the change, the commit message, the PR title and body, the branch name and the path list, with every place it occurs
- the commit message: %s · the PR title: %s · the PR body: %s · the branch name: %s — they are published too

The NER list supplements your read; it is not the checklist. Read every added line. Read every line of the commit message, the PR title, the PR body and the branch name.

Look for anything that could be personal or business context for the person publishing it: names of real people, emails, phones, handles, account slugs or ids; employer, client, product or project names that are not this tool's own; places and addresses; private paths, hostnames, repo or machine names; internal labels and codenames; money, deals, health, HR, family or schedule details; anything that only makes sense inside one person's notes. The tool's own vocabulary (its skill names, commands, file names) is fine.

Declared fakes are the only strings that are fine because they are fake. A string is a declared fake ONLY if the whole string equals one of these, ignoring case:""" % (P("full.diff"), P("vocab.txt"), P("ner.txt"), P("commit-msg.txt"), P("pr-title.txt"), P("pr-body.txt"), P("branch.txt")))
for e in exact: print("  - «%s»" % e)
print("or the whole string fully matches one of these patterns, ignoring case (Python re.fullmatch with re.IGNORECASE), each shown with what it means:")
for r, m in regs: print("  - `%s` — %s" % (r, m))
print("""Anything else is not a fake: a part of a fake (a bare first name is not one), a near miss (`Jane Doe`; `Acme-Health` is not `Acme Corp`), a fake shape carrying a real-looking piece (a real name in an example.com path or subdomain). If you are not sure, flag it.

Reply with exactly:
- one line per focus item and per NER item, in any order: `<id> | ok | <reason, one phrase>` or `<id> | flag | <flagged text> | <reason, one phrase>` — every v-id and every n-id once, no other ids;
- then, for any other line you would flag — an added line (a `+` line inside a hunk) or a line of the commit message, PR title, PR body or branch name — one line `<file>:<line> | <flagged text> | <reason, one phrase>` (`<file>` is the diff's path and `<line>` its new-file line number, or `commit-msg`, `pr-title`, `pr-body` or `branch-name` and the line number in that file);
- then `none found` if nothing at all is flagged.
`<flagged text>` is the exact string you flag (a name, a word, a number — not the whole line), copied character for character, without quotes, from the item's text or its line (for a path segment: the segment or its path; for an n-id: its «text», with `\\\\` written as one backslash and `\\n` or `\\r` as a space) or from the line you cite. Copy it as the line writes it: an escape sequence in the source (`\\u00e9`, `\\x41`, `\\n`, `\\t`, `\\\\`, `&amp;`, `&#233;` and the like) stays exactly as written, never decoded; a name the line holds only as escapes is flagged as those escapes, and a decoded name is not on the line (the n-id rule above undoes only the NER list's own escapes). It is whole words: at least 2 characters, one of them a letter or digit, with no letter, digit or combining mark running on directly before or after it there; camelCase steps are word breaks: a capital after a lowercase letter starts a word, and so does a capital after a capital when a lowercase letter follows it (in `getACMEToken`, `ACME` and `Token` are fine; in `HTTPServer`, `Server`; in `getAcmeCorpToken`, `AcmeCorp`; in `Zzacmecorp`, flag `Zzacmecorp`, never `acme`; in a script written without spaces, or in Korean where a particle follows a name, flag the whole unbroken run); an escape sequence written in the source that ends right before it is a word break too: `\\u` and 4 hex digits, `\\U` and 8, `\\x` and 2, `\\` and 1 to 3 octal digits, or `\\` and one of a b e f n r t v; a doubled backslash `\\\\` is one escape (in `\\\\nobody`, `obody` is not a word; in `\\u00a0Name` or `\\nName`, flag `Name`; `ame` is still not a word). So a part of a mixed-case word passes this check: flag the part that is the leak. Keep its case; Unicode form (NFC) does not count, and any run of spaces, tabs or line breaks counts as one space. A flag whose text is not there is rejected. The reason never contains ` | ` or a path named above.
Nothing else: no totals, no summary.""")
PY
)

flags_check() (
: "${SCAN_DIR:?}"; F="$SCAN_DIR/flags.txt"; rm -f "$SCAN_DIR/flags.ok"
[ -s "$SCAN_DIR/full.diff" ] && [ -f "$SCAN_DIR/vocab.txt" ] || { echo "STOP: CANNOT-CHECK — full.diff or vocab.txt missing in $SCAN_DIR; run 5a first"; exit 1; }
[ -f "$SCAN_DIR/ner.txt" ] || { echo "STOP: CANNOT-CHECK — ner.txt missing in $SCAN_DIR; the NER list is step 4's output — run step 4 and 5a again (an absent list is never 'no NER items')"; exit 1; }
for t in commit-msg pr-title pr-body branch; do [ -f "$SCAN_DIR/$t.txt" ] || { echo "STOP: CANNOT-CHECK — $t.txt missing in $SCAN_DIR; the flag pass read it (step 4 writes branch.txt)"; exit 1; }; done
[ -s "$F" ] || { echo "STOP: CANNOT-CHECK — $F missing or empty; the flag pass has not run"; exit 1; }
python3 - "$SCAN_DIR/full.diff" "$F" "$SCAN_DIR/vocab.txt" "$SCAN_DIR/ner.txt" "$SCAN_DIR" <<'PY' && { cat "$SCAN_DIR/full.diff" "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" "$SCAN_DIR/branch.txt" | cksum > "$SCAN_DIR/flags.ok"; } || { rm -f "$SCAN_DIR/flags.ok"; echo "STOP: CANNOT-CHECK — the flag pass output does not match the diff, the focus list or the NER list (above); re-run the pass"; exit 1; }
import os, re, sys, unicodedata
from collections import Counter
files, added, cur, n, hdr = [], {}, None, 0, False
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    l = raw.rstrip("\n")
    if l.startswith("diff --git "): hdr = True; cur = None; files.append(None); continue
    if hdr and l.startswith("+++ "): cur = None if l == "+++ /dev/null" else l[6:].rstrip("\t"); continue
    if l.startswith("@@"): hdr = False; n = int(re.match(r"@@ -\S+ \+(\d+)", l).group(1)); continue
    if hdr or cur is None: continue
    if l.startswith("+"): added[(cur, n)] = l[1:]; n += 1
    elif not l.startswith(("-", "\\")): n += 1
msgl, msgt = {}, {}
for t, f in (("commit-msg", "commit-msg"), ("pr-title", "pr-title"), ("pr-body", "pr-body"), ("branch-name", "branch")):
    ml = [x.rstrip("\n") for x in open(os.path.join(sys.argv[5], f + ".txt"), encoding="utf-8", errors="replace")]; msgl[t] = len(ml)   # file iteration (\n, \r\n or a lone \r ends a line), as 5c's view and step 4's locator number them; never str.splitlines(), which also splits on \f, \v, \x85, \u2028…
    for k, x in enumerate(ml, 1): msgt[(t, k)] = x
sdp = {os.path.realpath(sys.argv[5]), os.path.abspath(sys.argv[5])} | ({sys.argv[5].rstrip("/")} if sys.argv[5].startswith("/") else set())   # as the brief printed it, too (a TMPDIR may end in /)
sdp |= {b for b in map(os.path.basename, set(sdp)) if b.startswith("push-scan.")}   # and its relative form (step 0d's mktemp name)
nopath = lambda l: bad.append("flag names the scratch dir, which the view never shows: " + l.split(" | ", 1)[0]) if any(x in l for x in sdp) else None
# a flag's text is ON a cited string as whole words of it — the rule the brief declares: at least 2 characters, one a letter
# or digit; neither end joined to the word it sits in (word characters: letters, digits, combining marks; camelCase steps
# break: a lowercase letter then a capital, and a capital then a capital and a lowercase letter); both sides NFC, every whitespace run as one space. Otherwise verbatim. Accepted limit: in a
# script written without spaces (CJK, Thai) only the whole unbroken run passes. A source escape as written (ESC) that ends right
# before the text is a left edge too, never decoded: so `\u00a0Name` gives `Name`; accepted limit: an escaped letter splits a word
# the same way (`\u00e9mile` gives `mile`) — telling the two apart would need a decoder. A doubled backslash is ONE escape (`\\`),
# so `C:\\Users\\nobody` never splits at `obody`. Accepted limit: raw strings and regexes that only look like escapes yield
# fragments (`r"\bend\b"` gives `nd`, `r"C:\Users\nobody"` gives `obody`) — the checker cannot know the language.
# Accepted limit: URL `%XX` and ANSI `\x1b[0m` sequences are not boundaries, so a word glued to one stays refused (flag the whole token).
ws = lambda s: " ".join(unicodedata.normalize("NFC", s).split())
wc = lambda ch: ch.isalnum() or unicodedata.category(ch)[0] == "M"
def edge(c, k):   # a word edge between c[k-1] and c[k]: getACMEToken → get|ACME|Token, HTTPServer → HTTP|Server
    a, b = c[k - 1], c[k]
    return not (wc(a) and wc(b)) or (a.islower() and b.isupper()) or (a.isupper() and b.isupper() and k + 1 < len(c) and c[k + 1].islower())
ESC = re.compile(r"\\(?:\\|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|x[0-9A-Fa-f]{2}|[0-7]{1,3}|[abefnrtv])")   # the brief's list of source escapes
def on(t, c):
    t, c = ws(t), ws(c); i = c.find(t) if len(t) >= 2 and any(x.isalnum() for x in t) else -1; esc = {m.end() for m in ESC.finditer(c)}
    while i >= 0:
        if (i == 0 or i in esc or edge(c, i)) and (i + len(t) == len(c) or edge(c, i + len(t))): return True
        i = c.find(t, i + 1)
    return False
# what each id's flagged text must be on: a focus item's text (never its label) and its added line, or a path segment's
# path; an NER item's «text» with step 4's show() escapes (\\, \n, \r) undone — never the listed form, where an escape's
# letter would join the next word
cite = {}
for l in open(sys.argv[3], encoding="utf-8", errors="replace"):
    if not l.strip(): continue
    p = l.rstrip("\n").split(" | ", 2); f, _, ln = p[1].rpartition(":") if len(p) > 1 else ("", "", "")
    cite[p[0]] = [re.sub(r"^\((path segment|filename|code token)\) ", "", p[2].rsplit(" | new: ", 1)[0]) if len(p) > 2 else ""] + ([added[(f, int(ln))]] if ln.isdigit() and (f, int(ln)) in added else []) + ([f] if ln == "path" else [])
for l in open(sys.argv[4], encoding="utf-8", errors="replace"):
    if not l.strip(): continue
    p = l.rstrip("\n").split(" | ", 3); t = p[3] if len(p) > 3 else ""; t = t[1:-1] if t.startswith("«") and t.endswith("»") else t
    cite[p[0]] = [re.sub(r"\\(\\|n|r)", lambda m: {"n": "\n", "r": "\r"}.get(m.group(1), "\\"), t)]
vids = [l.split(" | ", 1)[0] for l in open(sys.argv[3], encoding="utf-8", errors="replace") if l.strip()]
nids = [l.split(" | ", 1)[0] for l in open(sys.argv[4], encoding="utf-8", errors="replace") if l.strip()]
lines = [l.rstrip("\n") for l in open(sys.argv[2], encoding="utf-8", errors="replace")]
bad = []
if not lines or not re.fullmatch(r"mode: (subagent|same-agent)", lines[0]): bad.append("first line is not 'mode: subagent' or 'mode: same-agent'")
items, free, none = [], [], False
for l in lines[1:]:
    if not l.strip(): continue
    m = re.fullmatch(r"([vn]\d+) \| (ok|flag) \| (.+)", l.strip())
    if m:
        items.append(m.groups())
        if m.group(2) == "flag":   # `<id> | flag | <text> | <reason>`: the reason is the last field, the text everything before it
            t, sep, why = m.group(3).rpartition(" | ")
            if not sep or not t.strip() or not why.strip(): bad.append("flag with no flagged text (want '<id> | flag | <text> | <reason>'): " + l.strip()[:60])
            elif not any(on(t, c) for c in cite.get(m.group(1), [])): bad.append("flagged text is not in the item it cites: %s «%s»" % (m.group(1), t[:40]))
            nopath(l)
        continue
    if l.strip() == "none found": none = True; continue
    if l.startswith("coverage:"): continue   # an agent's own totals are ignored, never trusted: the counts below come from the diff
    if " | " in l: free.append(l); continue
    bad.append("unparseable line (not an item, a flag or 'none found'): " + l[:60])
got = Counter(i for i, _, _ in items); key = lambda x: (x[0], int(x[1:]))
miss = lambda want: sorted(set(want) - set(got), key=key)
if miss(vids): bad.append("focus items with no line: " + ", ".join(miss(vids)))
if miss(nids): bad.append("NER items with no line: " + ", ".join(miss(nids)))
extra = sorted(set(got) - set(vids) - set(nids), key=key); dup = sorted((i for i, c in got.items() if c > 1), key=key)
if extra: bad.append("ids not on the focus or NER list: " + ", ".join(extra))
if dup: bad.append("ids answered more than once: " + ", ".join(dup))
for l in free:
    loc, _, rest = l.partition(" | "); f, _, ln = loc.rpartition(":"); t, sep, why = rest.rpartition(" | ")
    at = (added.get((f, int(ln))) if (f, int(ln)) in added else msgt.get((f, int(ln)))) if ln.isdigit() else None
    if at is None: bad.append("flag points at no added line or message line: " + loc)
    elif not sep or not t.strip() or not why.strip(): bad.append("flag with no flagged text (want '<file>:<line> | <text> | <reason>'): " + l[:60])
    elif not on(t, at): bad.append("flagged text is not on the line it cites: %s «%s»" % (loc, t[:40]))
    nopath(l)
nflag = sum(1 for _, v, _ in items if v == "flag") + len(free)
if nflag and none: bad.append("both flags and 'none found'")
if not nflag and not none: bad.append("no flags and no explicit 'none found'")
if bad: print("\n".join("  - " + b for b in bad)); sys.exit(1)
print("flag pass (%s): %s — %d/%d focus items and %d/%d NER items answered; the diff has %d file(s), %d added line(s); messages read: commit-msg %d, pr-title %d, pr-body %d, branch-name %d line(s)"
      % (lines[0][6:], "FINDINGS, %d flag(s)" % nflag if nflag else "CLEAN, none found", len(set(got) & set(vids)), len(set(vids)), len(set(got) & set(nids)), len(set(nids)),
         len(files), len(added), msgl["commit-msg"], msgl["pr-title"], msgl["pr-body"], msgl["branch-name"]))
PY
)
