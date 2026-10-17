# `pii-scan` — usage contract

The interface the outbound sync procedure is built against. **This is the canonical copy.** `+ ` content roots never leave a vault, so a personal reference note pointing at this file stays a pointer — never a second copy of the text itself, which is exactly how a prior copy drifted within a day of existing.

> **Status:** the scanner and this contract are live. Callers: `/push-openbrain-template` (step 0 `--selftest`, step 4 scan of everything that leaves). Statements about what a gate "must" do describe current behaviour.

## Invocation

```
pii-scan [--mode gate|review] [--format json|text] [--allow-empty] [--exit-zero] FILE
pii-scan ... -            # read stdin
pii-scan --selftest       # prove the pipeline detects known PII
pii-scan --list-entities
```

Reads UTF-8 text — a file, a diff hunk, a commit message, anything on stdin. Writes JSON with `source`, `char_count`, `model`, `mode`, `findings` (`{entity_type, start, end, score, text}`) and a `summary` count per type. Input over 100K chars is scanned in overlapping windows.

**Two modes, no tuning.** `gate` (default) suppresses `DATE_TIME`, `NRP` and `ORGANIZATION` so a human can read the output; `review` shows everything, for human document review where a date of birth is signal. **`URL` is shown in both** — a signed, tokenized or internal link is one of the leak classes a publishing gate exists to catch, so it is never suppressed.

## Exit codes are the contract

| Code | Meaning |
|---|---|
| `0` | scanned, no findings |
| `1` | scanned, **findings present** — the only code meaning PII was seen |
| `2` | **CANNOT-CHECK** — the scan did not happen, or cannot be trusted |
| `126` / `127` | wrapper not executable / not installed (shell-supplied). CANNOT-CHECK |

`2` never means clean. A caller mapping `2` onto `0` has built the fail-open this tool exists to prevent; one reading any nonzero as "findings" reports a phantom leak whenever the scanner breaks. **A gate must refuse to publish on `2`, `126` or `127` rather than fall back to a pattern list.**

CANNOT-CHECK covers: a missing or wrong spaCy model, a broken venv interpreter, unreadable or non-UTF-8 input, **input containing NUL bytes** (UTF-16 or binary, which would decode into gibberish that scans clean while hiding real identifiers), closed stdin, empty or **whitespace-only** input, a canary failure, and anything unanticipated — an uncaught error is normalised to `2` rather than escaping as `1`.

**Empty and whitespace-only input are the caller's job to pre-test.** `"\n"` exits `2`, so a one-blank-line reformat hunk is CANNOT-CHECK, not clean — deliberate, since an empty read usually means the producer failed. A caller that legitimately produces empty or blank content should test for real text first (`grep -q '[^[:space:]]'`) and skip the scan, rather than reaching for `--allow-empty`. **`--allow-empty` is for the narrow case where the caller has independently confirmed the input is meant to be empty** and still wants a recorded `0`; it is not a way to quiet a noisy pipeline.

**Consuming the output with `| head`, `| grep -q` or `| jq -e` is safe.** Closing the pipe early makes the scan report `2`, not a partial success: the result could not be fully delivered, so findings may have been lost. (An earlier version let CPython's shutdown flush escape as exit **120**, which a gate checking `-eq 2` would have published straight past.)

## Two design decisions a caller should know about

**There are no knobs that narrow a scan.** Earlier versions had `--entities`, `--exclude-entities` and `--min-confidence`. Each produced a silent-blindness bug: an allowlist that omitted `US_PASSPORT` and `MEDICAL_LICENSE`; a threshold of `0.86`, above the 0.85 ceiling every spaCy NER type scores at, which disabled name detection entirely and returned clean; an `--entities`/`--exclude-entities` pair that cancelled out. Guarding each knob grew the defect surface, so they were deleted. If you need different behaviour, add a named mode here — do not reintroduce free-form tuning.

**Every scan verifies itself.** Before reporting any result, the exact configured pipeline scans a canary containing a known name and email address. If that configuration cannot find them, the scan was blind and the answer is CANNOT-CHECK — whatever the cause, including causes nobody anticipated. This is why `--selftest` and a real scan **in the same mode** cannot disagree — they run the same check. Across modes they can: selftest what you will scan with.

## Precondition

Run `pii-scan --selftest` before the scan loop and stop on failure. Installed packages are not evidence the scanner works: `EMAIL_ADDRESS` and `PHONE_NUMBER` are pattern recognizers that fire even when the NER model is absent or degraded, so a broken install returns plausible findings while detecting no names — a false negative that looks exactly like a clean run.

`install-pii-scan.sh --check` is equivalent and slightly stronger: it resolves `pii-scan` on the **inherited PATH**, exactly as a caller will, and fails if the winner is not this repo's wrapper — catching a hijack that an earlier-on-PATH binary would otherwise hide.

## Privacy posture

**The content you scan never leaves the machine, and the scan path performs no network I/O.** Verified by intercepting socket connections across a full scan and a selftest: zero connection attempts. Inference is in-process against a local spaCy model, and none of Presidio's remote extras (`azure-ai-language`, `ahds`, `langextract`) are installed.

The mechanism that makes this hold rather than merely happen: Presidio's spaCy engine calls `spacy.cli.download()` for a missing model, which would turn any scan into an unannounced ~430MB fetch. This tool verifies the pinned model is installed **before** constructing the engine, so a missing model is CANNOT-CHECK instead of a download. The only download is the installer's — once, announced. Note the model wheel is version-pinned; `presidio-analyzer` and `presidio-anonymizer` are not.

## Precision: high recall, low precision on source code

Measured on real repository files.

- **Prose and config read almost clean** in `gate` mode — generic skill definitions return only their own documentation URLs.
- **A file with real personal data lights up unmistakably** — one returned 27× `PERSON`, 11× `EMAIL_ADDRESS`, 5× `LOCATION`.
- **Source code is noisy, and `ORGANIZATION` is the worst of it.** A 36KB shell script returns 96 findings in `review` mode, **68 of them `ORGANIZATION`** (`MAIN`, `&& pwd`, `TARGET`, `MCP`). `gate` mode brings it to 15 — still including junk `PERSON` hits like `--git`, `-s` and `msg_types=`.
- **Clean files are not empty, and `URL` count scales with link density, not cleanliness.** A short generic skill returns 1–2 `URL` findings; real documentation topics run **5–16 per file**, and a 26KB reference document returned **53**. Do not calibrate a reviewer's expectations off the small case. This is the intended cost of never hiding tokenized links — and the reason for the single sanctioned grouping below.

Consequences for the caller:

- **Never auto-block on a count, and never show raw NER output to a human.** Every hit is listed with its `file:line`. The outbound caller hands every NER hit to a fresh reading agent, which answers each one and reads every added line besides; the human reads the agent's flags and the deterministic pattern hits, decided once per run (declining it means one decision per flag or pattern hit — fix / drop the file / accept with a recorded reason). See below.
- **Junk cannot be separated by score.** `--git` scores 0.85 as `PERSON`, identical to a real name. Mode selection shortens the list; only a reader makes it trustworthy. This is why the agent pass and the human OK are mandatory.
- **Complement, not replacement, for the deterministic pattern list.** Patterns catch enumerated account identifiers; NER points the reader at un-enumerable third-party names. Run both.

Whether a heavier local model removes the junk, and what it costs in latency, is an open deferred question.

## Handling the output

The findings JSON quotes every detected identifier **verbatim**. It is as sensitive as the document it describes. Do not write it to a shared path, a log, a PR comment, a commit message, or anywhere it outlives the disposition step — a gate that leaks its own scan output has re-leaked exactly what it protected. Write it to a private directory (`mktemp -d` + `chmod 700`, `umask 077`) and delete it explicitly when the review is done.

### The one sanctioned grouping: public URLs, per file

At real sizes one prompt per finding is impractical for `URL` alone — a 26KB documentation file returns 53 of them. A caller **may** collapse `URL` findings into **one grouped prompt per file**, showing the full list, **only when both conditions hold for every URL in that file**:

1. **Host is on a short known-public allowlist.** Starting set: `github.com`, `docs.claude.com`, `code.claude.com`, `developer.mozilla.org`, `en.wikipedia.org`. **Hosts are added by the human, never by the skill** — a skill that grows its own allowlist has rebuilt the blind allowlist this tool deleted its knobs to avoid.
2. **The URL carries nothing opaque**: no query string, no fragment, and no path segment containing an opaque identifier.

   Test a segment by splitting it on `-`, `_` and `.` first, then asking whether **any resulting token is ≥16 characters of `[A-Za-z0-9]`**. Opaqueness is an unbroken high-entropy run, not raw segment length — split first or ordinary documentation dies with the secrets.

Condition 2 is the load-bearing one. `https://docs.google.com/document/d/1A2b3C4d5E6f7G8h9I0j` is the canonical case that must **stay a single prompt**: the host looks innocuous and the secret is the path segment. A signed URL, a Slack `shared_invite`, or a link with `?token=` fails condition 2 by construction.

**Why the split matters** — tested, 11/11:

| URL | Groupable | Because |
|---|---|---|
| `en.wikipedia.org/wiki/Named-entity_recognition` | yes | tokens `Named`, `entity`, `recognition` are all short |
| `developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat` | yes | every token short |
| `github.com/explosion/spacy-models/releases/download/en_core_web_lg-3.8.0/...whl` | yes | every token short |
| `github.com/x/y/raw/1A2b3C4d5E6f7G8h9I0jKl/f` | **no** | one 22-char unbroken token |
| `docs.google.com/document/d/1A2b3C4d5E6f7G8h9I0j/edit` | **no** | host not allowlisted (and opaque segment) |
| `github.com/x/y?token=abc` · `github.com/x/y#frag` | **no** | query · fragment |

Measuring the whole segment instead of its tokens would reject `Named-entity_recognition` (24 chars) as opaque, forcing one prompt per URL on exactly the ordinary documentation links this rule exists to collapse.

**Any URL in the file failing either condition drops that whole file back to one prompt per URL.** Do not group the compliant subset and single out the rest — that splits the operator's attention exactly where it should be concentrated.

**This is a grouping, not a suppression.** Every URL is still detected, still shown, and still dispositioned; only the number of prompts changes. `URL` is never removed from the scan — see the modes note above.

### Outbound: NER hits go to the agent; pattern hits go to the human

Measured on 216 fictional leaks planted into ten real outbound changes: NER found 68% of them and none at all of five classes (handles, ALL-CAPS surnames, client names, codenames, deal amounts); every rule that routed NER hits to "counted, no decision" or onto a human screen could only reorder what NER found, and the screen it produced was 44–88 strings per change, nearly all junk. A fresh reading agent found 95–97% per run. So the outbound caller (`/push-openbrain-template` step 4–5) routes nothing:

- **Every NER hit goes to the agent.** One item per distinct `(type, text)`, each with an id and every place it occurs — the change's files, the commit message, the PR title and body, the branch name, the path list. The agent answers `ok` or `flag` for every id, and a check refuses a reply that skips one (a skipped id is CANNOT-CHECK, never a pass). The NER list supplements the agent's read; it is not the checklist: the agent reads every added line, and every line of the commit message and PR text, besides.
- **The declared fakes are a rule in the agent's brief, generated from `bootstrap/lib/pii-fakes.txt` at every run** (`Jane Q. Doe`, `Acme Corp`, `example.com` (bare, behind `www.`/`docs.`/`api.`, with a fixed path word such as `/docs`, or at a fixed-vocabulary address such as `you@example.com`; never a free subdomain, path or `first.last@`), `555-0100`…`555-0199`, the RFC 5737 IPs, never-issued SSNs in the 000- and 666- areas (not 9xx-, the ITIN range), published test cards). A string is fake only if the whole string equals an `exact:` entry, ignoring case, or fully matches a `re:` entry, ignoring case (as Python's `re.fullmatch` with `re.IGNORECASE`) — each `re:` shown with its declared one-line meaning — and anything uncertain is flagged. No code matches the fakes: the reading agent applies this rule, worded exactly so, from its brief. "Jane" alone is not one.
- **Every pattern-list hit goes to the human**, located, beside the agent's flags. Patterns are deterministic; they need no reader to surface them.
- **The human sees no NER strings** — **Agent review** (the agent's flags, grouped by the flagged text, every reason and place kept), **Exact-match rules** (the pattern hits), **Blocking problems**, **Files changed** and one **Totals** line. That view is pasted verbatim, never summarized.

#### Why nothing is remembered

No run keeps a list of what was accepted, and no hit is waved through because it was seen before or is public elsewhere:

- **A mistake becomes permanent.** Suppose `Acme Corp` were a real client, accepted once in a hurry: a remembered accept would pass it on every later change, on every machine, with nobody looking again.
- **The list drifts where nobody looks.** An allowlist grows one harmless-looking entry at a time and is never reviewed as a whole.
- **A public string is not a public fact.** The examples here use `Jane Q. Doe`; "remember: Jane is fine" would wave through "call Jane re: biopsy" about a real Jane.
- **It has already happened here.** The deleted knobs above (`--entities`, `--min-confidence`) were each a remembered exemption that went silently blind.
- **Noise is handled by a reader, never by memory.** The declared fakes are the one fixed list, and they change only by PR.

### Inbound: pull does not scan

`/pull-openbrain-template` runs no NER or pattern scan on incoming content: it is public before it lands, so a scan could only report a leak that has already happened ("Design notes").

## The `pii-patterns` list

The deterministic half beside NER: each machine's own identifiers (account handles, a real name, a vault path fragment) that must never leave in infra files. A narrow backstop for what genericizing misses, not a complete PII list; content folders are protected by never being pushed.

- **Where:** `.openbrain/local/pii-patterns` in the template clone (mode 600), the copy the scanners read. Create it by hand for now; nothing seeds it yet. It is per machine: never commit it and never share it.
- **Plain entry** — one string per line, matched as a case-insensitive substring — Unicode NFC normalization and casefolding of both sides (`café` matches `CAFÉ`; an NFD-written entry matches NFC text) — `.openbrain/lib/template-scope.sh`'s `pii_match`, used by the outbound scan. Right for handles: one entry catches the email, the MCP slug and the routing tag.
- **`word:` entry** — `word:<string>`, matched as a whole word. **Use `word:` for short entries**: a short name as a plain substring blocks every innocent word that contains it. Here `_` is part of a word; in the flag pass's flagged-text rule (push step 5b) it is not — there a word is letters, digits and combining marks, split at camelCase steps (`getACMEToken` → get, ACME, Token) and after a source escape (`\u00a0Name` → Name; never decoded; `\\` is one escape — raw strings, regexes, URL `%XX` and ANSI sequences are accepted limits), so a fragment of a mixed-case word (a surname inside a brand-like token) passes that check; the view shows each flag with the context of its line.
- `#` starts a comment; blank lines are ignored. Entries only ever add blocks; nothing here exempts a string.

## Scope to scan

Content, not paths: full text of new files, diff hunks of modified files, **the commit message, and the PR title/body**. Real leaks have shipped in commit messages.

The `pre-push` hook this repo's `setup.sh` installs is a protected-remote URL guard only — it does **not** scan content or commit messages. Do not treat it as a backstop.

## Design notes

Rationale and history moved out of the sync scripts and skills, so the files carry only what a reader or executor needs at the line. One entry per moved note, named by the file (and block) it came from; the line there points here.

- **`.openbrain/lib/template-scope.sh` — why it exists.** Push once defined `deny()` twice inline (its enumerate and scan blocks), and pull's plan block awk-extracted `deny()` from push's live SKILL.md text, `eval`'d it and probed that it survived the trip: three near-copies of one policy. Shared executable logic lives in `.openbrain/lib/` as a real file, never extracted from another skill's markdown at runtime. It is not a section of `_common.sh` because that is the MCP-launcher library: `register-mcps.sh` deploys it to `~/.config/openbrain/lib/` and `reconcile-runtime.sh` drift-checks it there, so scope logic in it would deploy into the MCP runtime and read as drift on every edit, for a concern the runtime has no use for. Same tier as `assert-no-vault-remote.sh`.
- **`template-scope.sh` — `PORTABLE_ROOTS`.** Derived from the upstream push and pull Scope tables (no line numbers cited, so it cannot drift out of step with them). Directory roots are declared by a trailing `/` because a `.md`/`.json` suffix test was tried and rejected: `.claude` and `.openbrain` are dot-directories a suffix test cannot tell from files.
- **`template-scope.sh` `PUSH_ALL_OMITS`, and the push skill's Scope table (`bootstrap/` row).** The upstream pull skill says of `bootstrap/` "include in diff, but flag for careful review"; the upstream push skill says "only update if explicitly asked". Both are upstream's own text, for the two directions of one sync, so each skill follows its own rule: push subtracts `bootstrap/` from `all`, pull uses the roots unmodified. A real asymmetry in the upstream files, not a mismatch to fix here.
- **Push skill, Scope.** The roots are the whole scope, not a default a specific-enough hint can escape: anything git tracks outside them is never enumerated, so the hard-deny table exists only for paths that could otherwise slip into a root, not to bound the rest of the repo. `Dashboard.md` and `.gitignore` were once listed as portable; they left the scope when the roots became the shared, sourced list in `template-scope.sh`, which does not carry them.
- **Push skill, step 0a.** The destination ref is fetched every run because a stale one reads a file upstream has since deleted as still present, which would skip the new-file confirm.
- **Push skill, step 0b (the vault-remote guard).** A vault configured as a remote of the clone is a vault → clone → public leak path. The guard's OK line is required, not just its exit `0`, because a zero-byte or truncated script also exits `0`: a missing checker is never a passing one. 0a's `cd` runs in a subshell so the shell is never left inside the clone. It runs the vault's copy of `assert-no-vault-remote.sh` against the clone because the clone's `main` did not carry the script until the PR that added it merged: running the clone's copy would have stopped `127` on every machine. The file still ships, so vaults made from the template carry it too.
- **Push skill, step 1 (enumeration).** Asking git rather than walking the filesystem means gitignored paths cannot appear, deletions show, and no directory walker is ever handed a tree. A path needing git quoting (a tab, quote or backslash in its name) stops the run because it would otherwise escape both the deny list and the scan.
- **Push skill, step 4 (the scan).** `BASE` is never guessed: a scan against the wrong base attests to a span that is not the one published. A `word:` pattern entry is delimited by letters, digits and `_`, so `word:rail` never fires on "trailing". Every text is tested for NUL bytes before any `grep` reads it, because a `grep` that skips binary input would call the file empty and skip it; every `grep` in the blocks is `command grep`, so a shell function named `grep` (a Claude Code session defines one) never answers for it. NER hits were once pre-sorted into filename, code-shape and declared-fake classes and counted away; now every one goes to the agent (see "Outbound" above).
- **Push skill, step 4 (reading findings).** Reading the scan's lists inside the session is safe because the Claude Code transcript is local and already holds the vault's own content; `.claude/projects/` is hard-denied, so it never travels.
- **Push skill, step 5b (flag pass).** The declared-fakes rule is generated from `bootstrap/lib/pii-fakes.txt` at every run and never written into the skill, so the list changes in one place.
- **Push skill, step 5c (the view).** The view must be pasted into the reply text because on a remote or mobile surface the user cannot see tool output. Nothing is opened in an app for the user because the starters run on more than one OS.
- **Push skill, step 5 (post-OK cleanup).** The artefacts are deleted with `find`, not an `rm` glob: zsh aborts a whole `rm` when one glob matches nothing.
- **Push skill, step 6 (commit and PR).** The stamps check STOPs on a moved stamp because a change or message edited after the OK was never scanned, flagged or read; on `HEAD` ≠ `BASE` because a commit already on the change branch carries a message no step scanned; and on an unpublished `BASE` because a commit only on the local base rides along on the push unscanned. `gh pr create` is written as two literal invocations because zsh expands `${PR_BASE:+--base "$PR_BASE"}` to one word.
- **Push and pull skills, Notes, and the `extract-block.sh` header (block extraction).** Callers extract one marked block instead of reading the skill file: a whole-file read cost about 70% more per run. One shared helper, `extract-block.sh`, called with one stable absolute command string, also means one permission approval instead of a fresh one per ad hoc `awk`/`sed` call, and never the wrong copy when the caller's cwd has moved.
- **`.openbrain/lib/extract-block.sh` — hardening, each guard's failure case.** The file is snapshotted once (TOCTOU) because separate locate, validate and print reads can each see a different version of the file. Anchor text reaches awk through `ENVIRON`, never `-v`: `-v m='back\slash'` silently becomes `backslash`. Every awk/sed call gets `</dev/null` and an absolute path, since a bare `x=y.md` argument is parsed by awk as an assignment and the call then hangs on stdin. Locate fields are checked as integers so a truncated line is one clean CANNOT-CHECK, never a shell arithmetic error. The range is checked before `sed -n` because BSD `sed -n '2,1p'` prints line 2 rather than nothing. The print pass is counted with awk because `wc -l` undercounts a last line with no trailing newline.
- **`bootstrap/lib/install-pii-scan.sh` — why the scanner is required.** The outbound procedure is specified to scan what it publishes. A pattern list matches only what someone thought to enumerate; the leaks that matter are the ones nobody did — a third party's name, a street address, a stranger's email quoted in a comment — and those need NER. Hence no patterns-only fallback. The scanner lives under `bootstrap/lib/` because `bin/`, where machine-local tooling lives, is hard-denied by the sync, so a scanner there could never be updated through the gate it powers. spaCy is pinned to the model's declared range because an unpinned fresh install would one day pair a newer spaCy with this model and fail closed, but only on new machines, the hardest place to diagnose it.
- **`install-pii-scan.sh` — exit handling and ordering, history.** The `finish()` flag exists because a failing `source common.sh` under `set -e` did not reliably surface as a nonzero `$?` in the EXIT trap, so the script once exited `0` on an incomplete checkout, reporting a machine with no scanner as healthy; and a bare `set -e` exit of `1` would read to a caller gating on `-eq 2` as "not unhealthy". `resolved_scanner()` once prepended `BIN_DIR` to `PATH`, which made `--check` validate this script's own link while a caller with another `pii-scan` earlier on `PATH` silently got that one. The `PATH` link step once sat after the early "already installed" return, so install mode could never create a missing link or surface a hijacked one.
- **`bootstrap/lib/pii-scan.py` — gate-mode noise types.** `ORGANIZATION` is suppressed in `gate` mode because it is by far the noisiest type on source code; the measurement is in "Precision" above.
- **`.openbrain/lib/flag-pass.sh` — where it came from.** Its two functions began as push's step-5a builders (inside `push-skill: full-diff`) and its `push-skill: flags-check` block, moved verbatim; they have changed since (a precondition guard, the fakes-path variable `FLAG_PASS_FAKES_REL`, the flagged-text rule) — git history is the record. Not in `_common.sh`, for the same reason as `template-scope.sh` above.
- **Pull skill, step 1 (plan start points).** Upstream starts only from its own declared row, never another topic's: a topic cut from a newer `main` carries `main`'s content in its tree, but its take planned only its own commits. A topic stacked on an already-taken one starts at the nearest taken ancestor, because starting from the merge-base would replay the base topic's old snapshot and conflict on files the base has since moved. Upstream needs none of this; after one of your topics is squash-merged upstream, expect conflict rows on exactly the files you pushed (the pull skill's Notes). `taken.tsv` replaced the retired `openbrain-applied/*` tags and `TOPICS.md` rows.
- **Pull skill, plan block (direction check).** Without it, a topic rooted on an old snapshot of another topic re-offers that snapshot and the row looks like any other. `taken.tsv` records what a topic offered, not what the vault accepted (a conflict resolved "ours", a skip), so the note asks for a comparison rather than prescribing a side: "theirs" is often a regression there, but only the user can tell.
- **Pull skill, steps 3 and 5 (skip and the marker).** A merge that changes the vault cannot be skipped because the skipped hunk would become the base of every later merge of that path, a base the vault never had. The marker moves only when this plan's items are all disposed of because a marker past content the vault does not carry would make the next take report "nothing new" while the vault runs stale content; the check is a set difference against this plan, so a list left over from an earlier plan pays for nothing.
- **Pull skill — no incoming scan.** Incoming template content is public before it lands, and what leaves the vault is gated by `/push-openbrain-template`; the pull scan (NER and patterns, with per-row holds) was there for symmetry with push, not for a risk it reduced.
- **Pull skill, step 4b (verify placement).** Verify once ran after `mark`, which deletes `$SCAN_DIR` as its last act, so on every successful run it wrote into a removed directory and every check reported a spurious failure. It now runs between apply and mark.
