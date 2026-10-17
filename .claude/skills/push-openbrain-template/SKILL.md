---
name: push-openbrain-template
description: Genericize vault improvements and open a PR against the upstream openbrain-claude-starter repo — enumerates candidates from git, strips personal data, NER-scans everything that leaves (files, hunks, commit message, PR text), and refuses to push when the scanner is missing. New files go out only when their exact path is named.
---

# /push-openbrain-template

Push improvements from this live vault to the upstream [openbrain-claude-starter](https://github.com/davidianstyle/openbrain-claude-starter) repo by opening a pull request. The template repo must be cloned locally — by default at `~/openbrain-claude-starter`. Set the `OPENBRAIN_TEMPLATE_DIR` environment variable to override.

The vault is the working bench; the template is what other people clone. Anything that's a real improvement (a new skill, a bug fix in a hook, a smarter procedure, a new template field) should make it back to the template — but stripped of the user's name, accounts, orgs, memories, and any other personal data.

Three things this skill will not do, ever: walk the filesystem to find candidates (it asks git), publish without the local PII scanner (`pii-scan`, installed by `bootstrap/setup.sh`) having proven it works, or push to the public remote without the user's explicit go in the same session.

## Inputs

- `$1` (optional): scope hint — one of `all` (default), `skills`, `hooks`, `claude-md`, `templates`, `obsidian`, `bootstrap`, or a specific path like `.claude/skills/capture-meeting/SKILL.md`. Limits which paths step 1 enumerates.
- **Named new files** (optional): the exact existing paths the user named for adding. A file absent at the destination goes out **only** if its exact path is named here; write them, verbatim, one per line to `$SCAN_DIR/named.lst` before step 1. A directory, glob, keyword or `all` never names a new file.
- `$2` (optional): `--dry-run` — run steps 0–5 (enumeration, analysis, genericization preview, the scan, the flag pass and the human view) as a full rehearsal, but commit nothing, push nothing, and leave nothing behind in the template repo (the preview lives on a throwaway branch that is deleted at the end).

## Scope: what's portable vs. what stays in the vault

**Hard-deny — never a candidate, no override, no scope hint reaches it:**

| Path | Why |
|---|---|
| `+ ` content roots (`+ Atlas/`, `+ Spaces/`, `+ Inbox/`, `+ Sources/`, `+ Archive/`, `+ Private/`, …) — **except `+ Extras/Templates/`** | Content, not infrastructure. Even a `.gitkeep` under them stays. |
| `.openbrain/local/` | Per-machine state, including the pattern list that is itself concentrated PII. |
| `.claude/projects/` | Auto-memory. |
| `.env`, `.env.*` (any directory) | Secrets. `.openbrain/env.example` is the tracked template and IS in scope. |
| `bin/` | Machine-local personal tooling. |
| `Home.md` | The vault's front door — content, regenerated from this vault's notes. A hunk referencing it is documentation, never a dependency. |

Also never read: `~/.config/openbrain/.env`, `~/.claude/projects/.../memory/`.

**The default scope is a roots allowlist, not a deny-everything-else list.** `all` (and every scope hint below `bootstrap`) enumerates only `PORTABLE_ROOTS` — the paths `.claude/skills/`, `.openbrain/`, `+ Extras/Templates/`, `CLAUDE.md`, `README.md`, and the four per-machine-safe `.obsidian/*.json` files — as defined once in `.openbrain/lib/template-scope.sh` (`in_roots()`) and shared by every sync skill (push, pull, and any skill layered on these blocks). A path outside the roots is never a candidate under `all`; it takes an explicit hint that names it (`bootstrap`, or the path itself) to reach it. The hard-deny table above still applies on top of the roots — it exists for paths that could otherwise slip into a root (`.openbrain/local/` is under `.openbrain/`, `+ Extras/Templates/` is carved back out of the wider `+ ` deny) — not to bound the *rest* of the repo, which the roots already exclude.

| Vault path | Template path | Notes |
|---|---|---|
| `.claude/skills/*/SKILL.md` | same | Procedures — always port improvements |
| `.openbrain/*.sh`, `.openbrain/lib/*.sh` | same | Genericize hardcoded vault paths to `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` |
| `.openbrain/env.example` | same | Strip real account slugs; keep structure + comments |
| `+ Extras/Templates/*.md` | same | Note templates — port schema changes verbatim (already generic) |
| `CLAUDE.md` | same | Most delicate — see §"CLAUDE.md handling" below |
| `.obsidian/app.json`, `core-plugins.json`, `appearance.json`, `graph.json` | same | Only port if a setting is universally useful. Per-machine files are gitignored and never enumerate. |
| `README.md` | same | Only port if there's a real improvement |
| `bootstrap/` | same | Has its own architecture. It **is** one of `PORTABLE_ROOTS` (David's own pull-skill text roots it — "include in diff, but flag for careful review"), but push's own upstream text says the opposite ("only update if explicitly asked"), so `template-scope.sh`'s `PUSH_ALL_OMITS` subtracts it from this skill's `all` — the `bootstrap` scope hint, or a path under it, still reaches it on request. This is a real asymmetry in David's own two files, not a mismatch to fix here |

`Dashboard.md` and `.gitignore`, which an earlier version of this table listed as portable, are no longer roots — the roots list is now the shared, sourced one in `template-scope.sh`, and neither of those two ships in it. **These paths are not portable at all: no scope hint, including an explicit path, reaches outside `PORTABLE_ROOTS`** — the roots are the whole scope, not a default that a specific-enough hint can escape. A hint that names a path outside the roots is refused at step 1 (`in_roots` empties it, and the block STOPs naming the hint rather than silently enumerating nothing). This is a different mechanism from `.openbrain/template-ignore`, which declines specific paths *inside* the roots that the destination already has — **deliberate divergence only** (a vault's personalized keepers, home despite being upstream); a vault-only file needs no entry, because an unnamed new file is never offered: matching paths never become candidates here, and never arrive through `/pull-openbrain-template`; the enumerate block prints its count and list every run. A real improvement to `Dashboard.md` or `.gitignore` would need `PORTABLE_ROOTS` itself extended, not a hint. Anything git tracks outside the roots is never enumerated, so it never becomes a candidate; the hard-deny table and the scanner decide the rest, then you do. Anything containing real secrets (PATs, OAuth client IDs, refresh tokens, `xoxp-*` tokens) is dropped at step 3 or caught at step 4.

## Procedure

### 0. Preconditions — every one of these STOPS the skill on failure

Resolve paths once, in the shell every later block runs in:

```bash
VAULT="$(pwd)"
TEMPLATE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
[ -d "${TEMPLATE:?}/.git" ] || { echo "STOP: no template clone at $TEMPLATE"; exit 1; }
DEST_REF=refs/remotes/upstream/main   # the destination: what "already there" means for new files (step 1) — 0a re-sets it to origin/main when the clone has no upstream remote; re-export it in every later block
DEP_UNION=   # push is strict: the dependency check resolves against the staged tree only (share sets `staging`) — re-export it with DEST_REF
```

**a. Clone clean, on `main`, fetched.** The destination ref is fetched here, every run: `DEST_REF` is what "already there" means for new files, and a stale one reads a file upstream has since deleted as present, so it would skip the new-file confirm. The remote is `upstream`, or `origin` when the clone has none (a clone of the template itself), as in the pull skill's preflight.

```bash
# --- push-skill: clone ---
( cd "${TEMPLATE:?}" && git checkout -q main && git pull -q --rebase --autostash \
  && [ -z "$(git status --porcelain)" ] ) || { echo "STOP: template clone is not clean on main"; exit 1; }   # subshell: the session's cwd stays in the vault
REMS="$(git -C "$TEMPLATE" remote)" || { echo "STOP: CANNOT-CHECK — git remote failed in $TEMPLATE"; exit 1; }
UPR=origin; printf '%s\n' "$REMS" | LC_ALL=C command grep -qx upstream && UPR=upstream
GIT_TERMINAL_PROMPT=0 git -C "$TEMPLATE" fetch -q --prune "$UPR" || { echo "STOP: CANNOT-CHECK — git fetch --prune $UPR failed; the destination ref would be stale (a file $UPR has deleted would read as already there)"; exit 1; }
DEST_REF="refs/remotes/$UPR/main"
git -C "$TEMPLATE" rev-parse -q --verify "$DEST_REF^{commit}" >/dev/null || { echo "STOP: CANNOT-CHECK — $DEST_REF does not resolve after the fetch"; exit 1; }
echo "DEST_REF=$DEST_REF ($UPR fetched just now, at $(git -C "$TEMPLATE" rev-parse --short "$DEST_REF"))"
```

Re-export the `DEST_REF` it printed in every later block.

**b. No vault configured as a remote of the clone.** A vault remote on the bench that pushes to public repos is a vault → clone → public leak path. The guard refuses on a local-path remote or a `.openbrain/vault-remotes` pattern match (the vault's pattern file is passed in as `VAULT_REMOTES_FILE`, unioned with the clone's if it has one), and refuses when it cannot determine the repo, is not run from its root, has zero remotes, or sees `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR` set. Its OK line states coverage: remote URL rows checked, patterns and pattern files applied. The vault's pattern file is passed only when it exists; a vault without one is told, in one line, that ssh/https-reached vaults are then undetectable. It is the **vault-resident** copy (`$VAULT/.openbrain/lib/`, vault-is-king) run with the clone as its working directory: the clone's `main` does not carry the script until this PR merges, so running the clone's copy would STOP `127` on every machine. The file still ships in the PR so vaults created from the template carry it too.

```bash
# --- push-skill: guard ---
case "${VAULT:-}" in /*) ;; *) echo "STOP: CANNOT-CHECK — VAULT must be an absolute path; cd to the vault and re-run the step-0 preamble"; exit 1 ;; esac
case "${TEMPLATE:-}" in /*) ;; *) echo "STOP: CANNOT-CHECK — TEMPLATE must be an absolute path; re-run the step-0 preamble"; exit 1 ;; esac
if [ "$VAULT" -ef "$TEMPLATE" ]; then echo "STOP: CANNOT-CHECK — VAULT resolves to the template clone (the shell was left inside the clone); cd to the vault and re-run the preamble"; exit 1; fi
PATS="$VAULT/.openbrain/vault-remotes"; VRF="VAULT_REMOTES_FILE=$PATS"
[ -e "$PATS" ] || { VRF="VAULT_REMOTES_FILE="; echo "note: no $PATS in this vault — a vault reached over ssh/https cannot be recognised as one (local-path remotes still are)"; }
rc=0; OUT0B="$( ( cd "$TEMPLATE" || exit 2; env "$VRF" bash "$VAULT/.openbrain/lib/assert-no-vault-remote.sh" ) 2>&1 )" || rc=$?; printf '%s\n' "$OUT0B"
case "$rc" in
  0) printf '%s\n' "$OUT0B" | command grep -q '^assert-no-vault-remote: OK — [1-9][0-9]* remote' || { echo "STOP: CANNOT-CHECK — the guard exited 0 without its OK line (empty or truncated script? restore .openbrain/lib/assert-no-vault-remote.sh from git)"; exit 1; } ;;
  1) echo "STOP: BLOCKED — a vault is configured as a remote of the clone; remove it (git remote remove <name>)"; exit 1 ;;
  127) echo "STOP: MISSING: assert-no-vault-remote.sh — the guard is missing from the vault ($VAULT/.openbrain/lib/); restore it (git checkout -- .openbrain/lib/assert-no-vault-remote.sh) or pull the template"; exit 1 ;;
  *) echo "STOP: CANNOT-CHECK — vault-remote guard exit $rc (see its message above)"; exit 1 ;;
esac
```

Three outcomes, never two: `0` checked and clean **and** the guard's own `OK — N remote URL row(s) checked` line is present (a zero-byte or truncated script also exits 0 — the exit code alone is not proof the check ran), `1` blocked, anything else (`2` cannot determine the repo, not at its root, zero remotes, cannot enumerate or parse its remotes, or a named pattern file is unreadable; `126` script unreadable or not a file; `127` script absent from the vault) is CANNOT-CHECK. A missing checker is never a passing one. The block also refuses when `VAULT` is not absolute or resolves to the clone — every block re-derives `VAULT="$(pwd)"`, so the shell must never be left inside the clone (0a's `cd` runs in a subshell for that reason).

**c. The PII scanner is present and proves it can see.** `pii-scan --selftest` runs the exact configured pipeline against a canary name + email. Exit codes are the contract (`bootstrap/PII-SCAN-CONTRACT.md`): `0` works, anything else is **CANNOT-CHECK** — including `2` (no venv, wrong model, blind configuration) and `126`/`127` (not installed).

```bash
rc=0; pii-scan --selftest || rc=$?
[ "$rc" -eq 0 ] || { echo "STOP: CANNOT-CHECK — pii-scan selftest exit $rc. Repair with: \"$VAULT\"/bootstrap/lib/install-pii-scan.sh"; exit 1; }
```

There is no patterns-only fallback. A machine that cannot run the scanner cannot push from this skill.

**d. A private scratch dir for scan output.** Findings JSON quotes every detected identifier verbatim — it is as sensitive as what it describes. It lives here and nowhere else, and is deleted at the end of step 6 (or on any abort):

```bash
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'push-scan.*' -user "$(id -un)" -exec rm -rf {} +   # a previous aborted run's scratch, if any
SCAN_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/push-scan.XXXXXX")" && chmod 700 "$SCAN_DIR" && echo "SCAN_DIR=$SCAN_DIR" || exit 1
```

Shell state does not survive between tool calls. Every later block starts by re-deriving `VAULT`/`TEMPLATE` as above and re-exporting `SCAN_DIR` (plus `HINT` = the `$1` the user typed, and `BASE` in step 4) from the values printed here; the blocks refuse to run without `SCAN_DIR` rather than guess. If the run is abandoned at any point — "Revert all", an error you cannot fix, a new session — `rm -rf "$SCAN_DIR"` is the first thing to do.

### 1. Enumerate candidates from git, not the filesystem

Ask each repo what it tracks or would track (`-c` cached, `-o` untracked-but-not-ignored). Gitignored paths cannot appear, deletions show, and no directory walker is ever handed a tree.

The block sources the shared scope library and maps the scope hint (`HINT`, the `$1` the user typed) to a git pathspec **within `PORTABLE_ROOTS`**; `all` means the roots minus `PUSH_ALL_OMITS` (`bootstrap/` — push's own narrower rule; see the Scope table) — `git ls-files` is never run over the whole tree, and every scope, including a bare path hint, is filtered through `in_roots` afterward. There is no separate knob to turn that filtering off: `bootstrap/` reaches this skill by naming it (or a path under it) as the hint, and it's still in `PORTABLE_ROOTS`, so `in_roots` passes it through like anything else.

```bash
# --- push-skill: enumerate ---
set -o pipefail; umask 077
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"; [ -d "$SCAN_DIR" ] || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing"; exit 1; }
LIB="${VAULT:?}/.openbrain/lib/template-scope.sh"
[ -f "$LIB" ] || { echo "STOP: CANNOT-CHECK — template-scope.sh missing at $LIB; restore it from git, or re-pull the template — it ships alongside /push-openbrain-template"; exit 1; }
source "$LIB"
typeset -f deny >/dev/null 2>&1 && typeset -f in_roots >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — template-scope.sh sourced but deny()/in_roots() did not load"; exit 1; }
ALLSPEC=(); while IFS= read -r r; do [ -n "$r" ] && ALLSPEC+=("$r"); done < <(portable_roots | LC_ALL=C command grep -vxF -f <(printf '%s\n' "$PUSH_ALL_OMITS"))
PATHHINT=0
case "${HINT:-all}" in                       # the scope hint the user typed → one git pathspec (declared here, not inferred); in_roots (below) is the ONLY scope gate — no separate knob narrows or widens it
  all) SCOPE=("${ALLSPEC[@]}") ;;
  skills) SCOPE=(".claude/skills/") ;; hooks) SCOPE=(".openbrain/") ;; claude-md) SCOPE=("CLAUDE.md") ;;
  templates) SCOPE=("+ Extras/Templates/") ;; obsidian) SCOPE=(".obsidian") ;;
  bootstrap) SCOPE=("bootstrap/") ;;
  *) SCOPE=("$HINT"); PATHHINT=1 ;;         # a single path: new (vault-only) or deleted (template-only) is the normal case, so only ONE side need be non-empty
esac
( cd "${VAULT:?}"    && git -c core.quotePath=false ls-files -co --exclude-standard -- "${SCOPE[@]}" ) | LC_ALL=C sort > "$SCAN_DIR/vault.all"    || { echo "STOP: CANNOT-CHECK — vault enumeration failed"; exit 1; }
( cd "${TEMPLATE:?}" && git -c core.quotePath=false ls-files -co --exclude-standard -- "${SCOPE[@]}" ) | LC_ALL=C sort > "$SCAN_DIR/template.all" || { echo "STOP: CANNOT-CHECK — template enumeration failed"; exit 1; }
if LC_ALL=C command grep -q '^"' "$SCAN_DIR/vault.all" "$SCAN_DIR/template.all"; then echo "STOP: CANNOT-CHECK — a path needs git quoting (tab, quote or backslash in its name); rename it first:"; LC_ALL=C command grep -h '^"' "$SCAN_DIR/vault.all" "$SCAN_DIR/template.all"; exit 1; fi
in_roots "$SCAN_DIR/vault.all" > "$SCAN_DIR/vault.roots" && in_roots "$SCAN_DIR/template.all" > "$SCAN_DIR/template.roots" || { echo "STOP: CANNOT-CHECK — in_roots filter failed"; exit 1; }
if { [ -s "$SCAN_DIR/vault.all" ] && [ ! -s "$SCAN_DIR/vault.roots" ]; } || { [ -s "$SCAN_DIR/template.all" ] && [ ! -s "$SCAN_DIR/template.roots" ]; }; then
  echo "STOP: CANNOT-CHECK — hint '${HINT:-all}' names nothing under the portable roots (see PORTABLE_ROOTS in template-scope.sh); not portable"; exit 1
fi
deny "$SCAN_DIR/vault.roots"    > "$SCAN_DIR/vault.ok"    || { echo "STOP: CANNOT-CHECK — deny filter failed"; exit 1; }
deny "$SCAN_DIR/template.roots" > "$SCAN_DIR/template.ok" || { echo "STOP: CANNOT-CHECK — deny filter failed"; exit 1; }
if [ "$PATHHINT" -eq 1 ]; then { [ -s "$SCAN_DIR/vault.ok" ] || [ -s "$SCAN_DIR/template.ok" ]; } || { echo "STOP: CANNOT-CHECK — path hint names nothing in either repo (wrong VAULT/TEMPLATE, bad pathspec, or a broken clone); this is not a clean result"; exit 1; }
else { [ -s "$SCAN_DIR/vault.ok" ] && [ -s "$SCAN_DIR/template.ok" ]; } || { echo "STOP: CANNOT-CHECK — enumeration produced an empty list (wrong VAULT/TEMPLATE, bad pathspec, or a broken clone); this is not a clean result"; exit 1; }
fi
# template-ignore: the vault's declared keepers (one path or glob per line) never become candidates. Never silent: count + list printed.
IGN="$VAULT/.openbrain/template-ignore"; : > "$SCAN_DIR/ignored.lst"
if [ -f "$IGN" ] && LC_ALL=C command grep -qxE '[[:space:]]*(\./)?[*]+(/[*]+)*[[:space:]]*' "$IGN"; then echo "STOP: template-ignore has a bare match-everything entry (like '*') — it would ignore every candidate; fix .openbrain/template-ignore"; exit 1; fi
if [ -f "$IGN" ]; then
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%$'\r'}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"; pat="${pat#./}"; case "$pat" in ''|'#'*) continue ;; esac
    while IFS= read -r ip; do bash -c 'case "$2" in $1) exit 0 ;; esac; exit 1' _ "$pat" "$ip" && printf '%s\n' "$ip"; done < <(LC_ALL=C sort -u "$SCAN_DIR/vault.ok" "$SCAN_DIR/template.ok") >> "$SCAN_DIR/ignored.lst"   # glob evaluated by bash: under zsh, `case … in $pat)` matches literally
  done < "$IGN"
fi
LC_ALL=C sort -u -o "$SCAN_DIR/ignored.lst" "$SCAN_DIR/ignored.lst" || { echo "STOP: CANNOT-CHECK — could not sort ignored.lst"; exit 1; }
for side in vault template; do LC_ALL=C comm -23 "$SCAN_DIR/$side.ok" "$SCAN_DIR/ignored.lst" > "$SCAN_DIR/$side.kept" && mv "$SCAN_DIR/$side.kept" "$SCAN_DIR/$side.ok" || { echo "STOP: CANNOT-CHECK — template-ignore filter failed"; exit 1; }; done
echo "template-ignore: $(wc -l < "$SCAN_DIR/ignored.lst" | tr -d ' ') path(s) skipped ($(tr '\n' ' ' < "$SCAN_DIR/ignored.lst" | sed 's/ $//'))"
if [ -s "$SCAN_DIR/ignored.lst" ]; then   # re-check emptiness AFTER the filter, and say which manifest emptied it
  if [ "$PATHHINT" -eq 1 ]; then { [ -s "$SCAN_DIR/vault.ok" ] || [ -s "$SCAN_DIR/template.ok" ]; } || { echo "STOP: hint '$HINT' names only paths listed in .openbrain/template-ignore — nothing left to push; remove the entry to push it"; exit 1; }
  else { [ -s "$SCAN_DIR/vault.ok" ] && [ -s "$SCAN_DIR/template.ok" ]; } || { echo "STOP: CANNOT-CHECK — .openbrain/template-ignore removed every enumerated path on one side (hint '${HINT:-all}'); fix the manifest"; exit 1; }; fi
fi
LC_ALL=C comm -23 "$SCAN_DIR/vault.ok" "$SCAN_DIR/template.ok" > "$SCAN_DIR/vault-only.lst"
LC_ALL=C comm -13 "$SCAN_DIR/vault.ok" "$SCAN_DIR/template.ok" > "$SCAN_DIR/template-only.lst"
: > "$SCAN_DIR/differing.lst"
while IFS= read -r rel <&3; do
  cmp -s "$VAULT/$rel" "$TEMPLATE/$rel" || printf '%s\n' "$rel" >> "$SCAN_DIR/differing.lst"
done 3< <(LC_ALL=C comm -12 "$SCAN_DIR/vault.ok" "$SCAN_DIR/template.ok")
n() { wc -l < "$1" | tr -d ' '; }
# new files go out only when NAMED: a path absent at the destination is a candidate only if the user named its exact
# path (one per line in $SCAN_DIR/named.lst, written verbatim from the invocation). Never under all, keywords or dirs.
: "${DEST_REF:?export DEST_REF — refs/remotes/upstream/main for push; for share, staging/topic/<t> (or staging/main for a new topic)}"
git -C "$TEMPLATE" rev-parse -q --verify "$DEST_REF^{commit}" >/dev/null || { echo "STOP: CANNOT-CHECK — destination $DEST_REF does not resolve in the clone; fetch it first"; exit 1; }
git -C "$TEMPLATE" -c core.quotePath=false ls-tree -r --name-only "$DEST_REF" | LC_ALL=C sort > "$SCAN_DIR/dest.all" && [ -s "$SCAN_DIR/dest.all" ] || { echo "STOP: CANNOT-CHECK — could not list the tree at $DEST_REF"; exit 1; }
LC_ALL=C comm -23 "$SCAN_DIR/vault.ok" "$SCAN_DIR/dest.all" > "$SCAN_DIR/new.lst"; : > "$SCAN_DIR/add.lst"; rm -f "$SCAN_DIR/add.ok"
{ [ ! -f "$SCAN_DIR/named.lst" ] || cat "$SCAN_DIR/named.lst"; [ "$PATHHINT" -eq 0 ] || ! LC_ALL=C command grep -qxF -- "$HINT" "$SCAN_DIR/vault.ok" "$SCAN_DIR/ignored.lst" || printf '%s\n' "$HINT"; } > "$SCAN_DIR/named.use"   # a path hint naming one exact file names it too
if [ -s "$SCAN_DIR/named.use" ]; then
  while IFS= read -r np || [ -n "$np" ]; do np="${np%$'\r'}"; [ -n "$np" ] || continue
    ! LC_ALL=C command grep -qxF -- "$np" "$SCAN_DIR/ignored.lst" || continue   # a declared keeper stays home even when named (listed on the template-ignore line)
    LC_ALL=C command grep -qxF -- "$np" "$SCAN_DIR/vault.ok" || { echo "STOP: named path '$np' is not an exact existing file in scope — a directory, glob or keyword never names a new file"; exit 1; }
    ! LC_ALL=C command grep -qxF -- "$np" "$SCAN_DIR/new.lst" || printf '%s\n' "$np" >> "$SCAN_DIR/add.lst"
  done < "$SCAN_DIR/named.use"
fi
LC_ALL=C sort -u -o "$SCAN_DIR/add.lst" "$SCAN_DIR/add.lst" && LC_ALL=C comm -23 "$SCAN_DIR/new.lst" "$SCAN_DIR/add.lst" > "$SCAN_DIR/unnamed-new.lst" || { echo "STOP: CANNOT-CHECK — could not build the add list"; exit 1; }
for L in vault-only differing; do LC_ALL=C sort -o "$SCAN_DIR/$L.lst" "$SCAN_DIR/$L.lst" && LC_ALL=C comm -23 "$SCAN_DIR/$L.lst" "$SCAN_DIR/unnamed-new.lst" > "$SCAN_DIR/$L.kept" && mv "$SCAN_DIR/$L.kept" "$SCAN_DIR/$L.lst" || { echo "STOP: CANNOT-CHECK — could not drop unnamed new files"; exit 1; }; done
echo "$(n "$SCAN_DIR/unnamed-new.lst") files not at $DEST_REF not considered; name a path to add"
[ ! -s "$SCAN_DIR/add.lst" ] || { echo "adding these $(n "$SCAN_DIR/add.lst") new files to $DEST_REF:"; sed 's/^/  /' "$SCAN_DIR/add.lst"; echo "OK? — ask once; on an explicit yes: cp \"\$SCAN_DIR/add.lst\" \"\$SCAN_DIR/add.ok\""; }
printf 'enumerated (hint=%s): vault %s paths (%s after roots+deny), template %s (%s after roots+deny); vault-only %s, template-only %s, differing %s\n' \
  "${HINT:-all}" "$(n "$SCAN_DIR/vault.all")" "$(n "$SCAN_DIR/vault.ok")" "$(n "$SCAN_DIR/template.all")" "$(n "$SCAN_DIR/template.ok")" \
  "$(n "$SCAN_DIR/vault-only.lst")" "$(n "$SCAN_DIR/template-only.lst")" "$(n "$SCAN_DIR/differing.lst")"
```

Always print that coverage line. The block stops by itself when either `*.ok` list is empty (wrong `VAULT`/`TEMPLATE`, bad pathspec, broken clone — not a clean result; for a single-path hint, when both are — a new or deleted file is empty on one side by nature) and when a path needs git quoting (a tab, quote or backslash in a filename would otherwise escape both the deny list and the scan). If `vault-only` and `differing` are both empty, stop too and say "nothing in scope differs" with the counts — never the word *clean*.

**New files go out only when named.** A path in the vault but absent at `DEST_REF` (upstream `main`) is dropped from both lists unless its exact path is in `named.lst`; the block prints `N files not at <dest> not considered; name a path to add` every run. Named ones are echoed back — "adding these N new files to <dest>: … OK?" — for **one explicit confirm**; only on a yes, copy `add.lst` to `add.ok`. Step 4 refuses any staged file absent at the destination that is not on a confirmed list matching step 1's.

The three lists are the working set:
- **Vault-only** — candidates for **add** (named and confirmed only)
- **Template-only** — usually skip; flag if it looks like the vault drifted backwards
- **Differing** — candidates for **update**

### 2. Per-file analysis

For each candidate, read both versions side-by-side. Classify each hunk in the diff:

- **(P) Personal**: contains the user's name, email/Slack/account identifiers, orgs, specific people from the vault, hardcoded user-specific paths, Asana workspace gids, memory pointers, delegation tables. → **strip or rewrite** before porting.
- **(I) Improvement**: a real procedure change, bug fix, new feature, schema update, clearer wording. → **port**, after genericization.
- **(N) Noise**: timestamps, formatting nits, accidental edits. → **skip**.
- **(R) Regression**: vault is *behind* the template (e.g. template has `HAS_UPSTREAM` handling that the vault still hardcodes `origin/main`). → **flag** to user, don't auto-port the vault version backwards. The template should stay ahead.

If a file is **all (P)** with no (I), skip it.
If a file is **all (R)**, skip it and add a line to the report telling the user the vault should pull this change forward.

Then group what's left into **changes** — one change is one improvement a reviewer can accept or reject on its own (a skill fix; a hook hardening; a template schema field). Each change gets its own branch in step 3.

### 3. Genericize, one branch per change

Apply these substitutions to any text you port. They are deliberate — do them by hand, hunk by hunk, not as a blind regex pass, because context matters.

#### Identity substitutions

| Vault literal | Template form |
|---|---|
| User's real name (subject) | `the user` or `you` (match the surrounding voice) |
| User's name (possessive) | `the user's` or `your` |
| Specific colleague names | A declared fake (`Jane Q. Doe`, `John Q. Roe` — `bootstrap/lib/pii-fakes.txt`) or remove if not load-bearing |
| Real email addresses | `you@example.com` or remove |
| Real company/org names | `your company`, `acme.com` |
| Context-specific orgs (churches, clubs) | Remove if not load-bearing |
| Hardcoded vault path (e.g. `/Users/jane/Code/openbrain`) | `~/OpenBrain` or `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` for bash |
| Other hardcoded home paths | Generic `$HOME/...` |

#### MCP-name substitutions

The vault uses concrete slugs like `google_jane_acme_com`, `slack_acme_slack_com`. The template uses pattern references and the placeholder tables in CLAUDE.md.

| Vault literal | Template form |
|---|---|
| `mcp__google_<specific>__*` | `mcp__google_<slug>__*` |
| `mcp__slack_<specific>__*` | `mcp__slack_<workspace_slug>__*` |
| Specific `google_*` default (e.g. for work) | "the user's work `google_*` MCP (see CLAUDE.md §12)" |
| Hardcoded Asana workspace gid | `<asana_work_workspace_gid>` placeholder, or strip |
| References to `asana_work` and `asana_personal` MCPs | Keep — these names are already generic and used in the template |

#### CLAUDE.md handling

CLAUDE.md is the most personal file in the vault. Most of it should NOT be ported. Only port:

- Section structure changes (new section, renumbered section, reorganized headers)
- Convention changes that are universally true (e.g. a new tag in the taxonomy, a new frontmatter requirement)
- Clarifications to the "What you must NOT do" rules
- Improvements to skill descriptions in the skills table

NEVER port:
- §1 "Primary collaborator" identity line
- Per-machine bootstrap sections (the template has its own bootstrap wizard)
- Maintenance automation summaries that reference user-specific scheduler plans
- Multi-account routing tables — the template uses `{{GOOGLE_ACCOUNTS_TABLE}}` etc. placeholders that the bootstrap fills in
- Any "delegations" / "memory pointers" / specific people lists
- The `# auto memory` block

The template version of CLAUDE.md uses `{{USER_NAME}}`, `{{USER_VOICE}}`, `{{ASANA_ROUTING_TABLE}}`, `{{GOOGLE_ACCOUNTS_TABLE}}`, `{{SLACK_WORKSPACES_TABLE}}`, `{{FATHOM_TABLE}}`, `{{BOOTSTRAP_DATE}}`. **Preserve those placeholders verbatim.** Never resolve them to the vault values.

When in doubt, leave a CLAUDE.md hunk un-ported and surface it in the report for the user to decide.

#### Skill-file handling

Skills are the bread and butter of this skill. Most diffs in `.claude/skills/*/SKILL.md` are tractable:

- "After displaying the numbered list, ask [Name] to..." → "After displaying the numbered list, ask the user to..."
- Default MCP slugs in fall-back instructions → generic `<slug>` pattern + a CLAUDE.md §12 reference
- Example timestamps and example interaction note slugs → keep as examples but ensure they don't reference real people

If the vault has a skill the template doesn't, port it as a new file. Strip any vault-specific paths. Make sure the frontmatter `name:` and `description:` are clean.

#### Hook-script handling

Bash scripts under `.openbrain/`:

- Replace any hardcoded vault path with `VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`
- Replace `git push origin main` with `git push` (no branch hardcoded)
- Replace `git pull --rebase --autostash origin main` with `git pull --rebase --autostash`
- Wrap upstream-dependent operations in a `HAS_UPSTREAM` guard so a fresh clone without a remote doesn't error
- Use `${TMPDIR:-/tmp}/openbrain-on-stop.log` instead of hardcoded `/tmp/...`
- Strip any user-specific comments

If the template version already has these patterns and the vault doesn't, that's a (R) regression — flag and skip.

#### env.example handling

`.openbrain/env.example` is the tracked secrets template. It must contain **zero real values**:

- `ASANA_PAT_PERSONAL=` (empty)
- `GOOGLE_OAUTH_CLIENT_ID=` (empty)
- `GOOGLE_OAUTH_CLIENT_SECRET=` (empty)
- All Slack `SLACK_USER_TOKEN_*` variables empty
- All comments that list specific Google account slugs → replaced with the `--- GOOGLE_SLUGS (managed by bootstrap) ---` marker block from the template
- All workspace-admin gotchas referencing specific domains → genericized to "Google Workspace accounts (custom domains)" / "managed Slack workspaces"

Comments and section headers can be ported if they're a real improvement (e.g. clearer instructions, an additional OAuth scope).

#### Write the change to its branch

One branch per change, named for the change, from `main`. If the change depends on one that is still an open PR, branch from that PR's branch instead (stack) and say so in the PR body; never bundle two changes to avoid a stack.

```bash
cd "${TEMPLATE:?}" && git checkout -b <change-slug> main   # or: -b <change-slug> <unmerged-pr-branch>
```

For each file in the change:

1. Read the existing template version (if any).
2. Apply only the (I) hunks, with genericization substitutions baked in.
3. Write the resulting file to the template repo path — `Edit` for an existing file (preserve the rest of it), `Write` only for a new one.

**Hunk dependencies.** A hunk that references a vault skill (`/name`, `.claude/skills/<name>/`) or a vault path (`.openbrain/…`, `bootstrap/…`, any tracked path) that the staged tree will not carry **stays home** — README and CLAUDE.md rows included. Step 4 computes this from git (the vault's tracked files versus the index; push is strict) and STOPs naming each such line; leave the hunk out, or name the dependency as a new file (above) so it travels too. Nothing is raised implicitly. It sees only literal `/name` and path tokens: a line that *describes* a vault-only skill without naming it passes, so the agent flag pass (step 5b) still reads every added line.

Draft the commit message, PR title and PR body now, as files in the scratch dir, so step 4 scans them:

```bash
cd "${TEMPLATE:?}" && git add -A && git status --short && git diff --no-color --cached --stat
# then write: "$SCAN_DIR/commit-msg.txt"  "$SCAN_DIR/pr-title.txt"  "$SCAN_DIR/pr-body.txt"
```

In `--dry-run`, do exactly the same, but on a branch named `dry-run/<change-slug>`: the writes, `git add -A` and the three draft files are what step 4 scans, and the closing paragraph of step 4 deletes the branch. Nothing is committed.

### 4. Scan everything that will leave — content, not paths

Two scanners, both mandatory: **`pii-scan`** (NER — names, emails, phones, locations, URLs; `gate` mode; no tuning flags exist and none are wanted, every earlier knob produced silent blindness) and **the pattern list** (deterministic — tokens, OAuth client IDs, Asana gids, 40-hex, home paths, plus the machine's own `.openbrain/local/pii-patterns` entries when that file exists in the clone). Their hits go to different readers: every NER hit to the agent (step 5b), every pattern hit to the human view (step 5c). What gets scanned:

- the **staged blob** of every new, copied or renamed file (the index is what the commit carries; the worktree copy is not)
- the **added lines** of every modified file (the diff hunks — what actually leaves)
- the **list of paths** the change touches (a filename can be a name), re-checked against the hard-deny list — a denied path that reached the index stops the run
- the **branch name** (it is pushed and shown on the PR), the **commit message**, the **PR title**, the **PR body**

Not scanned, published by design: the commit **author** (`user.name`/`user.email` of the clone). A PR carries its author; if that identity should differ from your vault's, set it in the clone (`git config user.name …`) before committing.

`BASE` must be exported explicitly — `main` for a plain change, the parent PR branch for a stacked one; the block refuses to guess, because a scan against the wrong base attests to a span that is not the one published. The clone's `.openbrain/local/pii-patterns`, when it exists, is one entry per line, matched after Unicode NFC normalization and casefolding on both sides (so `café` matches `CAFÉ`, and an NFD-written entry matches NFC text): a plain entry as a substring, a `word:` entry as a whole word (letters, digits and `_` delimit it, so `word:rail` never fires on "trailing"); `#` comments and blank lines ignored; the coverage header states how many entries were live, or `absent`.

```bash
# --- push-skill: scan ---
umask 077; cd "${TEMPLATE:?}" || exit 1
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"
[ -d "$SCAN_DIR" ] && : > "$SCAN_DIR/.writable" || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing or unwritable"; exit 1; }
: "${BASE:?export BASE=main for a plain change, the parent PR branch for a stacked one, or the parent branch your caller printed}"
PATTERNS='xox[pbea]-|[0-9]/[0-9]{10,}[:/]|apps\.googleusercontent\.com|ASANA_PAT_[A-Z]+=.|[0-9a-f]{40}|/Users/[^/ ]+|[0-9]{16}'
# Hosts whose plain documentation links may be dispositioned as ONE grouped prompt per file. Literal, edited by the
# repo owner only. A URL is groupable only if its host is exactly here AND it has no query string, no fragment and no
# path segment holding an opaque id — split each segment on - _ . and ask if any token is >=16 chars of [A-Za-z0-9];
# testing the whole segment instead calls en.wikipedia.org/wiki/Named-entity_recognition (24 chars) an id and
# un-groups the very documentation links this exists to collapse. A share link, token or document id stays single.
URL_GROUP_HOSTS='github.com docs.claude.com code.claude.com developer.mozilla.org en.wikipedia.org'
: > "$SCAN_DIR/coverage.txt"; : > "$SCAN_DIR/findings.idx"; : > "$SCAN_DIR/hits.idx"; rm -f "$SCAN_DIR/local-patterns.txt" "$SCAN_DIR/local-words.txt" "$SCAN_DIR/ner.txt" "$SCAN_DIR/patterns.txt" "$SCAN_DIR/scan.ok" "$SCAN_DIR/scan-notes.txt" "$SCAN_DIR/flags.txt"   # a re-run never reads the last run's hits, nor the last flag pass's reply
shred_findings() {   # the sensitive artefacts, never the operator's drafts. find, not globs: an unmatched glob aborts the whole rm under zsh
  find "$SCAN_DIR" -maxdepth 1 \( -name '*.json' -o -name '*.pat' -o -name '*.urls' -o -name '*.err' -o -name 'blob.txt' -o -name 'hunk.*' -o -name 'local-patterns.txt' \
    -o -name '*.all' -o -name '*.ok' -o -name '*.lst' -o -name 'outgoing.tsv' -o -name 'paths*.txt' -o -name 'branch.txt' -o -name 'findings.idx' \
    -o -name '*.hits' -o -name '*.map' -o -name 'hits.idx' -o -name 'ner.txt' -o -name 'patterns.txt' -o -name 'local-words.txt' -o -name 'deps.*' -o -name 'deps-*' \) -exec rm -f {} +
}
stop() { echo "STOP: CANNOT-CHECK — $*"; shred_findings; exit 1; }
has_nul() { [ "$(LC_ALL=C tr -d '\000' < "$1" | wc -c)" -ne "$(wc -c < "$1")" ]; }   # FIRST, before any grep reads the file: a grep that skips binary input (the session's is a function, ugrep -I) reads a NUL-bearing file as empty
has_text() { LC_ALL=C command grep -q '[^[:space:]]' "$1"; }   # -s alone passes whitespace-only files, which the scanner (rightly) refuses
LIB="${VAULT:?}/.openbrain/lib/template-scope.sh"
[ -f "$LIB" ] || stop "template-scope.sh missing at $LIB; restore it from git, or re-pull the template — it ships alongside /push-openbrain-template"
source "$LIB"
typeset -f deny >/dev/null 2>&1 && typeset -f in_roots >/dev/null 2>&1 && typeset -f pii_patterns >/dev/null 2>&1 && typeset -f pii_match >/dev/null 2>&1 || stop "template-scope.sh sourced but deny()/in_roots()/pii_patterns()/pii_match() did not load"   # the hard-deny list, re-applied here to what is actually staged; same function step 1 sourced. in_roots isn't used in this block, but the load check still verifies BOTH functions loaded — a lib that half-loaded is broken, not half-usable
# the clone's own per-machine pattern list, when it has one — normalized once (BOM, CR, comments, `word:` prefix, padding)
# the vault's pii-patterns sync, when this vault has it: regenerate the clone copy from the vault copy BEFORE it is read,
# so a mid-session vault edit is live. Absent (a template vault) is stated, never skipped silently; rc 20 stops.
PSYNC="$VAULT/.openbrain/lib/pii-patterns-sync.sh"
if [ -f "$PSYNC" ]; then
  psrc=0; PSOUT="$(bash "$PSYNC" --clone "$TEMPLATE" 2>&1)" || psrc=$?
  [ -z "$PSOUT" ] || printf '%s\n' "$PSOUT"
  case "$psrc" in 0|3) PSYNC_STATE="ok (rc $psrc)" ;; 10) PSYNC_STATE="WARN — the clone copy was NOT regenerated (it holds entries the vault copy lacks); scanned as is" ;;
    *) stop "pii-patterns sync failed (rc $psrc) — the clone copy may be stale; fix it and re-run" ;; esac
else PSYNC_STATE="MISSING — no $PSYNC (a template vault has none); the clone copy is scanned as is"; echo "pii-patterns sync: $PSYNC_STATE"; fi
LOCAL_N=absent
if [ -f .openbrain/local/pii-patterns ]; then
  pii_patterns .openbrain/local/pii-patterns > "$SCAN_DIR/local-patterns.norm" || stop "could not read .openbrain/local/pii-patterns"   # the shared normalizer in template-scope.sh
  { LC_ALL=C command grep -v '^word:' "$SCAN_DIR/local-patterns.norm" > "$SCAN_DIR/local-patterns.txt"; [ $? -le 1 ]; } && LC_ALL=C sed -n 's/^word://p' "$SCAN_DIR/local-patterns.norm" > "$SCAN_DIR/local-words.txt" && rm -f "$SCAN_DIR/local-patterns.norm" || stop "could not stage the normalized pattern list"   # plain entries: substring; word: entries: whole word (grep -w)
  LOCAL_N=$(( $(wc -l < "$SCAN_DIR/local-patterns.txt") + $(wc -l < "$SCAN_DIR/local-words.txt") ))
fi
scan() {                       # scan <label> <textfile> [<linemap>]  → records outcome; findings never exit, errors always do
  local label="$1" text="$2" map="${3:-}" out rc=0 prc=0 lrc=0
  if has_nul "$text"; then stop "binary content (NUL bytes) in $label — no text scanner can see into it; drop it from the change"; fi
  out="$SCAN_DIR/$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$label" | cksum | cut -d' ' -f1)"   # hash keeps a/b.md and a_b.md apart
  pii-scan --mode gate --format json "$text" > "$out.json" 2> "$out.err" || rc=$?
  case "$rc" in
    0) ;;
    1) printf '%s\tNER\t%s.json\n' "$label" "$out" >> "$SCAN_DIR/findings.idx" ;;
    *) cat "$out.err"; stop "pii-scan exit $rc on $label" ;;
  esac
  LC_ALL=C command grep -nE "$PATTERNS" "$text" > "$out.pat" || prc=$?
  [ -e "$out.pat" ] && [ "$prc" -le 1 ] || stop "pattern grep exit $prc on $label (or could not write $out.pat)"
  if [ "$LOCAL_N" != absent ] && [ -s "$SCAN_DIR/local-patterns.txt" ]; then
    pii_match plain "$SCAN_DIR/local-patterns.txt" "$text" >> "$out.pat" || lrc=$?   # NFC + casefold on both sides (template-scope.sh)
    [ "$lrc" -le 1 ] || stop "local pattern grep exit $lrc on $label"
  fi
  if [ "$LOCAL_N" != absent ] && [ -s "$SCAN_DIR/local-words.txt" ]; then lrc=0
    pii_match word "$SCAN_DIR/local-words.txt" "$text" >> "$out.pat" || lrc=$?
    [ "$lrc" -le 1 ] || stop "local word-pattern grep exit $lrc on $label"
  fi
  [ -s "$out.pat" ] && printf '%s\tPATTERN\t%s.pat\n' "$label" "$out" >> "$SCAN_DIR/findings.idx"
  # every hit, located: <out>.hits (one JSON row per hit, file:line in the file it came from) + <out>.urls (URL classifier)
  python3 - "$label" "$text" "$out" "$rc" "$map" "$URL_GROUP_HOSTS" <<'PY' || stop "hit locator failed on $label"
import bisect, json, re, sys
label, text, out, rc, mapf, hosts = sys.argv[1:7]; hosts = set(hosts.split())
src = open(text, "r", encoding="utf-8").read()          # read exactly as pii-scan reads it, so offsets line up
nl = [i for i, c in enumerate(src) if c == "\n"]
lmap = [int(x) for x in open(mapf)] if mapf else None   # hunk text line -> new-file line
where = label.split(":", 1)[1] if label.startswith(("new:", "hunks:")) else label
fline = lambda n: lmap[n - 1] if lmap else n
def urlclass(u):
    rest = re.sub(r'^[A-Za-z][A-Za-z0-9+.-]*://', '', u); host, _, path = rest.partition('/'); host = host.lower()
    return ("host not on the allowlist" if host not in hosts
            else "query string or fragment" if ('?' in u or '#' in u)
            else "opaque id in path" if any(re.fullmatch(r'[A-Za-z0-9]{16,}', t)
                                               for seg in path.split('/') for t in re.split(r'[-_.]', seg))
            else None)
with open(out + ".urls", "w") as U, open(out + ".hits", "w") as H:
    if rc == "1":
        for f in json.load(open(out + ".json"))["findings"]:
            row = {"kind": "NER", "type": f["entity_type"], "text": f["text"], "score": f.get("score"),
                   "file": where, "line": fline(bisect.bisect_left(nl, f["start"]) + 1),
                   "before": src[f["start"] - 1] if f["start"] > 0 else "", "after": src[f["end"]] if f["end"] < len(src) else ""}
            if f["entity_type"] == "URL":
                u = f["text"].strip(); why = urlclass(u)
                print("GROUPABLE\t%s" % u if why is None else "SINGLE\t%s\t%s" % (u, why), file=U)
                row["url"] = "GROUPABLE" if why is None else "SINGLE"
            print(json.dumps(row), file=H)
    for p in open(out + ".pat", encoding="utf-8", errors="replace"):
        n, _, body = p.rstrip("\n").partition(":")
        print(json.dumps({"kind": "PATTERN", "type": "PATTERN", "text": body, "file": where, "line": fline(int(n))}), file=H)
PY
  printf '%s\t%s.hits\n' "$label" "$out" >> "$SCAN_DIR/hits.idx"
  printf '%s\t%s bytes\tner=%s\tpattern-lines=%s\turl-groupable=%s\turl-single=%s\n' "$label" "$(wc -c < "$text" | tr -d ' ')" "$rc" "$(wc -l < "$out.pat" | tr -d ' ')" \
    "$(LC_ALL=C awk -F'\t' '$1=="GROUPABLE"{n++} END{print n+0}' "$out.urls")" "$(LC_ALL=C awk -F'\t' '$1=="SINGLE"{n++} END{print n+0}' "$out.urls")" >> "$SCAN_DIR/coverage.txt"
}
skip() { printf '%s\t%s\n' "$1" "$2" >> "$SCAN_DIR/coverage.txt"; }
git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached --name-status "$BASE" > "$SCAN_DIR/outgoing.tsv" || stop "git diff --name-status failed"
[ -s "$SCAN_DIR/outgoing.tsv" ] || stop "nothing staged against $BASE — a change with no outgoing files is a wiring error, not a clean scan"
cut -f2- "$SCAN_DIR/outgoing.tsv" | tr '\t' '\n' > "$SCAN_DIR/paths.txt"          # one path per line (renames/copies contribute two)
if LC_ALL=C command grep -q '^"' "$SCAN_DIR/paths.txt"; then stop "a staged path needs git quoting (tab, quote or backslash in its name) — rename it"; fi
deny "$SCAN_DIR/paths.txt" > "$SCAN_DIR/paths-allowed.txt"
cmp -s "$SCAN_DIR/paths.txt" "$SCAN_DIR/paths-allowed.txt" || { LC_ALL=C comm -23 <(LC_ALL=C sort "$SCAN_DIR/paths.txt") <(LC_ALL=C sort "$SCAN_DIR/paths-allowed.txt"); stop "a hard-denied path is staged (listed above) — unstage it; the deny list has no override"; }
# new-file gate (step 1's rule, enforced on what is actually staged): a staged path absent at the destination ships only
# if it is on the confirmed add list, and that list is exactly the one step 1 printed
: "${DEST_REF:?export DEST_REF — the destination step 1 compared against}"
git -c core.quotePath=false ls-tree -r --name-only "$DEST_REF" > "$SCAN_DIR/dest.all" && [ -s "$SCAN_DIR/dest.all" ] || stop "could not list the tree at $DEST_REF"
LC_ALL=C awk -F'\t' '$1!="D"{print $NF}' "$SCAN_DIR/outgoing.tsv" | LC_ALL=C sort -u | LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$SCAN_DIR/dest.all") > "$SCAN_DIR/staged-new.lst" || stop "could not list the staged new files"
if [ -s "$SCAN_DIR/staged-new.lst" ]; then
  [ -f "$SCAN_DIR/add.ok" ] && [ -f "$SCAN_DIR/add.lst" ] && cmp -s <(LC_ALL=C sort -u "$SCAN_DIR/add.ok") <(LC_ALL=C sort -u "$SCAN_DIR/add.lst") || { sed 's/^/  /' "$SCAN_DIR/staged-new.lst"; stop "new file(s) above are staged but no confirmed add list matches step 1's (add.ok = add.lst); name each exact path, confirm the echo, re-run step 1"; }
  LC_ALL=C comm -23 "$SCAN_DIR/staged-new.lst" <(LC_ALL=C sort -u "$SCAN_DIR/add.ok") > "$SCAN_DIR/unconfirmed.lst"
  [ ! -s "$SCAN_DIR/unconfirmed.lst" ] || { sed 's/^/  /' "$SCAN_DIR/unconfirmed.lst"; stop "new file(s) above are staged but were never named and confirmed; unstage them or name them"; }
fi
# hunk dependency check: an added line that references a vault skill (/name, .claude/skills/<name>/) or a vault path the
# staged tree does not carry stays home. Resolved against the index — what the destination will hold after this change.
git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached -U0 "$BASE" > "$SCAN_DIR/deps.diff" || stop "git diff for the dependency check failed"
( cd "$VAULT" && git -c core.quotePath=false ls-files ) > "$SCAN_DIR/deps-vault.lst" && git -c core.quotePath=false ls-files > "$SCAN_DIR/deps-index.lst" || stop "could not list the vault or the index for the dependency check"
# DEP_UNION=<remote> (share only): a path present anywhere on that remote — <remote>/main or any <remote>/topic/* tip — is
# present for this check. Unset/empty (push) = strict. A set union whose main does not resolve is CANNOT-CHECK, never strict.
if [ -n "${DEP_UNION:-}" ]; then
  git rev-parse -q --verify "refs/remotes/$DEP_UNION/main^{commit}" >/dev/null || stop "dependency union: refs/remotes/$DEP_UNION/main does not resolve — fetch $DEP_UNION first"
  git for-each-ref --format='%(refname)' "refs/remotes/$DEP_UNION/topic/" > "$SCAN_DIR/deps-union.refs" || stop "dependency union: could not list the $DEP_UNION topic tips"
  printf 'refs/remotes/%s/main\n' "$DEP_UNION" >> "$SCAN_DIR/deps-union.refs"
  : > "$SCAN_DIR/deps-union.lst"
  while IFS= read -r ur; do git -c core.quotePath=false ls-tree -r --name-only "$ur" >> "$SCAN_DIR/deps-union.lst" || { echo "  $ur"; stop "dependency union: could not list the tree above"; }; done < "$SCAN_DIR/deps-union.refs"
  [ -s "$SCAN_DIR/deps-union.lst" ] || stop "dependency union: the $DEP_UNION trees listed no paths"
  echo "dependency union: refs/remotes/$DEP_UNION/main + $(( $(wc -l < "$SCAN_DIR/deps-union.refs") - 1 )) topic tip(s), $(LC_ALL=C sort -u "$SCAN_DIR/deps-union.lst" | wc -l | tr -d ' ') path(s) counted present"
  cat "$SCAN_DIR/deps-union.lst" >> "$SCAN_DIR/deps-index.lst" || stop "dependency union: could not merge the union into the index list"
fi
deny "$SCAN_DIR/deps-vault.lst" > "$SCAN_DIR/deps-allowed.lst" && LC_ALL=C comm -23 <(LC_ALL=C sort "$SCAN_DIR/deps-vault.lst") <(LC_ALL=C sort "$SCAN_DIR/deps-allowed.lst") > "$SCAN_DIR/deps-denied.lst" || stop "could not apply the deny list for the dependency check"   # machine-local by design: a reference to one is documentation, never a dependency
python3 - "$SCAN_DIR/deps.diff" "$SCAN_DIR/deps-vault.lst" "$SCAN_DIR/deps-index.lst" "$SCAN_DIR/deps-denied.lst" > "$SCAN_DIR/deps.txt" <<'PY' || { cat "$SCAN_DIR/deps.txt"; stop "dependency check: the hunks above reference what the destination will not have — they stay home: unstage them, or name the dependency (an exact path, confirmed) and re-run from step 1"; }
import re, sys
diff, vf, xf, df = sys.argv[1:5]
def load(f):
    files = set(l.rstrip("\n") for l in open(f, encoding="utf-8") if l.strip()); dirs = set()
    for p in files:
        parts = p.split("/")
        for i in range(1, len(parts)): dirs.add("/".join(parts[:i]))
    return files, dirs
vfiles, vdirs = load(vf); xfiles, xdirs = load(xf); dfiles, ddirs = load(df)
local = 0
skills = {p.split("/")[2] for p in vfiles if re.fullmatch(r"\.claude/skills/[^/]+/SKILL\.md", p)}
SK = re.compile(r"(?<![A-Za-z0-9_./-])/([a-z0-9][a-z0-9-]*[a-z0-9])(?![A-Za-z0-9_/-]|\.[A-Za-z0-9_/-])")   # a /name mention; a trailing sentence `.` still counts (/name.ext does not)
PA = re.compile(r"\+ Extras/Templates/[A-Za-z0-9 _.-]+?\.md|[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)+/?")   # a slash path token (templates may hold spaces)
cur, n, lines, refs, bad = None, 0, 0, 0, []
for raw in open(diff, encoding="utf-8", errors="replace"):
    l = raw.rstrip("\n")
    if l.startswith("+++ "): cur = None if l == "+++ /dev/null" else l[6:].rstrip("\t"); continue
    if l.startswith("@@"): n = int(re.match(r"@@ -\S+ \+(\d+)", l).group(1)); continue
    if cur is None or not l.startswith("+"): continue
    t = l[1:]; lines += 1
    for m in SK.finditer(t):
        if m.group(1) in skills:
            refs += 1
            if ".claude/skills/%s/SKILL.md" % m.group(1) not in xfiles: bad.append((cur, n, "/" + m.group(1), "skill"))
    for m in PA.finditer(t):
        p = m.group(0).rstrip("/").rstrip(".,;:)")
        for pre in ("./",):
            if p.startswith(pre): p = p[len(pre):]
        if m.start() > 0 and t[m.start() - 1] == "$": p = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*/", "", p)   # "$VAULT/x", $HOME/x: the path after the variable
        if p in dfiles or (p in ddirs and not any(x.startswith(p + "/") for x in vfiles - dfiles)): local += 1; continue   # hard-denied: machine-local by design
        if p in vfiles or p in vdirs:
            refs += 1
            if p not in xfiles and p not in xdirs: bad.append((cur, n, p, "path"))
    n += 1
seen = set()
for f, ln, tok, kind in bad:
    if (f, ln, tok) in seen: continue
    seen.add((f, ln, tok)); print("  %s:%d references %s «%s» — absent at the destination" % (f, ln, kind, tok))
print("dependency check: %d added line(s), %d reference(s) to vault skills or paths, %d unresolved (skill: %d vault skills known; %d reference(s) to hard-denied machine-local paths, never dependencies)" % (lines, refs, len(seen), len(skills), local))
sys.exit(1 if seen else 0)
PY
tail -1 "$SCAN_DIR/deps.txt"
scan "path-list" "$SCAN_DIR/paths.txt"
git rev-parse --abbrev-ref HEAD > "$SCAN_DIR/branch.txt" || stop "cannot read the branch name"; scan "branch-name" "$SCAN_DIR/branch.txt"
while IFS=$'\t' read -r st rel newrel <&3; do   # not `status`/`path`: read-only or PATH-bound in zsh
  case "$st" in
    A|C*|R*)                   # scan the STAGED blob — what the commit will carry, not the worktree copy
      [ "${st#R}" != "$st" ] || [ "${st#C}" != "$st" ] && rel="$newrel"
      git show ":$rel" > "$SCAN_DIR/blob.txt" || stop "git show :$rel failed (submodule? unreadable index entry?)"
      if has_nul "$SCAN_DIR/blob.txt"; then stop "binary content (NUL bytes) in new file $rel — no text scanner can see into it; drop it from the change"; fi
      if has_text "$SCAN_DIR/blob.txt"; then scan "new:$rel" "$SCAN_DIR/blob.txt"; else skip "new:$rel" "skipped (empty or whitespace-only)"; fi ;;
    M|T)                       # the RAW staged blob first: git diffs a file whose NUL sits past its 8 KB probe as text, and awk cuts the line at the NUL
      git show ":$rel" > "$SCAN_DIR/blob.txt" || stop "git show :$rel failed (submodule? unreadable index entry?)"
      if has_nul "$SCAN_DIR/blob.txt"; then stop "binary content (NUL bytes) in the staged blob of $rel — no text scanner can see into it; drop it from the change"; fi
      git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" -- "$rel" > "$SCAN_DIR/hunk.diff" || stop "git diff failed on $rel"
      if LC_ALL=C command grep -q '^Binary files ' "$SCAN_DIR/hunk.diff"; then stop "binary content in $rel — drop it from the change"; fi
      : > "$SCAN_DIR/hunk.map"   # hunk.map: the new-file line number of each hunk.txt line, so every hit reports file:line
      LC_ALL=C awk -v map="$SCAN_DIR/hunk.map" '/^@@/{h=1; split($3, a, ","); n=substr(a[1], 2)+0; next} !h{next} /^\+/{print substr($0,2); print n > map; n++; next} /^[-\\]/{next} {n++}' "$SCAN_DIR/hunk.diff" > "$SCAN_DIR/hunk.txt" || stop "could not extract the added lines of $rel"   # header ends at the first @@; never keyed on `+++`
      if has_nul "$SCAN_DIR/hunk.txt"; then stop "binary content (NUL bytes) in the added lines of $rel — drop it from the change"; fi
      if ! LC_ALL=C command grep -q '^@@' "$SCAN_DIR/hunk.diff"; then   # 0 hunks: right only when the content did not change (a mode-only change)
        [ "$(git rev-parse -q --verify ":$rel")" = "$(git rev-parse -q --verify "$BASE:$rel")" ] || stop "$rel changed content but its diff yields 0 hunks (a diff driver, color or config is hiding them) — nothing was scanned"
        skip "hunks:$rel" "mode-only (same blob at $BASE) — skipped"; continue; fi
      if has_text "$SCAN_DIR/hunk.txt"; then scan "hunks:$rel" "$SCAN_DIR/hunk.txt" "$SCAN_DIR/hunk.map"; else skip "hunks:$rel" "0 added lines with text — skipped (deletion- or whitespace-only)"; fi ;;
    D)  skip "del:$rel" "deleted — name scanned in path-list" ;;
    *)  stop "unhandled git status '$st' for $rel" ;;
  esac
done 3< "$SCAN_DIR/outgoing.tsv"
for t in commit-msg pr-title pr-body; do has_text "$SCAN_DIR/$t.txt" 2>/dev/null || stop "$t.txt missing or empty — draft it before scanning"; scan "$t" "$SCAN_DIR/$t.txt"; done
# no routing: every NER hit goes to the agent (step 5b) as one id'd item per distinct (type, text); every pattern hit goes
# to the human view (step 5c), located. Nothing is counted away and nothing is remembered across runs — why:
# bootstrap/PII-SCAN-CONTRACT.md, "Why nothing is remembered".
python3 - "$SCAN_DIR" <<'PY' || stop "list builder failed (an unreadable hits file, or a location holding the ' | ' / ', ' separators — rename that path)"
import json, os, sys
sd = sys.argv[1]
hits = []
for row in open(os.path.join(sd, "hits.idx"), encoding="utf-8"):
    hits += [json.loads(l) for l in open(row.rstrip("\n").split("\t")[1], encoding="utf-8")]
show = lambda t: t.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r")   # one item per line: a hit spanning lines shows its \n (\r)
loc = lambda h: "%s:%s" % (h["file"], h["line"])
for h in hits:
    if " | " in loc(h) or ", " in loc(h): sys.exit("CANNOT-CHECK — a location holds ' | ' or ', ', which would break the lists: " + loc(h))
ner, pat = {}, []
for h in hits:
    if h["kind"] == "NER": ner.setdefault((h["type"], h["text"]), []).append(loc(h))
    else: pat.append((loc(h), h["text"]))
nh = sum(len(v) for v in ner.values())
# accounting against counts derived independently of the .hits rows: every finding in the scanner's JSON, every .pat line
jn = jp = 0
for row in open(os.path.join(sd, "findings.idx"), encoding="utf-8"):
    label, kind, f = row.rstrip("\n").split("\t")
    if kind == "NER": jn += len(json.load(open(f, encoding="utf-8"))["findings"])
    else: jp += sum(1 for _ in open(f, "rb"))
if (nh, len(pat)) != (jn, jp): sys.exit("hit accounting mismatch: listed %d NER + %d pattern hit(s); the scanner's JSON holds %d, the .pat files %d" % (nh, len(pat), jn, jp))
with open(os.path.join(sd, "ner.txt"), "w", encoding="utf-8") as N:
    for i, ((ty, t), ls) in enumerate(ner.items(), 1):
        print("n%d | %s | %s | «%s»" % (i, ty, ", ".join(dict.fromkeys(ls)), show(t)), file=N)
with open(os.path.join(sd, "patterns.txt"), "w", encoding="utf-8") as P:
    for (l, t) in pat: print("%s | «%s»" % (l, show(t)), file=P)
print("scan: %d NER hit(s) as %d distinct (type, text) item(s) → the agent (ner.txt, %s) · %d pattern hit(s) → the view (patterns.txt) · every hit listed"
      % (nh, len(ner), "n1..n%d" % len(ner) if ner else "none", len(pat)))
PY
printf 'pii-patterns sync: %s\nlocal-patterns=%s\n' "$PSYNC_STATE" "$LOCAL_N" > "$SCAN_DIR/scan-notes.txt" || stop "could not write scan-notes.txt"
echo "scan coverage (local-patterns=$LOCAL_N):"; echo "  pii-patterns sync: $PSYNC_STATE"; cat "$SCAN_DIR/coverage.txt"; echo "findings index: $(wc -l < "$SCAN_DIR/findings.idx" | tr -d ' ') entries"
{ git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" && cat "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" && git rev-parse --abbrev-ref HEAD; } | cksum > "$SCAN_DIR/scan.ok" || stop "could not stamp the scan"   # 5a, 5c and step 6 refuse lists built from other content
echo "NER list (the agent's): $SCAN_DIR/ner.txt · pattern hits (the view's): $SCAN_DIR/patterns.txt"
```

Rules for what happens next:

- **Exit `2`, `126`, `127` or anything but `0`/`1` from the scanner is CANNOT-CHECK** — the block above stops and deletes the scratch dir. Do not re-run with a pattern-only "fallback"; fix the scanner (`bootstrap/lib/install-pii-scan.sh`) and start over. A binary or non-UTF-8 file in the change is CANNOT-CHECK too: the block tests every text for NUL bytes before any `grep` reads it (a `grep` that skips binary input would call it empty and skip it), and the scanner refuses NUL bytes rather than scan gibberish. Drop that file from the change. Every `grep` in these blocks is `command grep`, so a shell function named `grep` (the Claude Code session defines one) never answers for it.
- **Read the findings only from the two lists the block writes** — `$SCAN_DIR/ner.txt` (the agent's) and `$SCAN_DIR/patterns.txt` (the view's) — and the per-label `*.json`, `*.urls`, `*.pat` and `*.hits` behind them with `Read` when a decision needs the detail; nothing else there (`local-patterns.txt` and `local-words.txt` are the machine's own pattern list, not findings). No wholesale `cat` of a JSON file into the conversation. Never paste a finding, a JSON excerpt or a matched line into a PR comment, a commit message, the report, or anything that leaves this machine. The `coverage.txt` lines — labels, byte counts, exit codes, hit counts — are the only scan output that may be quoted. (The Claude Code transcript is local and already holds the vault's own content; `.claude/projects/` is hard-denied above so it never travels.)
- **No question is asked here, and nothing is routed.** The block lists **every** hit with its `file:line` (it stops if the count listed differs from the count found), and nothing carries over to the next run:
  - **NER hits → the agent.** `ner.txt` holds one item per distinct `(type, text)`, `n<k> | <TYPE> | <file>:<line>, … | «<text>»`, every place it occurs listed (files, `commit-msg`, `pr-title`, `pr-body`, `branch-name`, `path-list`). Nothing is counted away first — no filename, code-shape or declared-fake class: the agent answers `ok` or `flag` for every id (step 5b, checked), applying the declared-fakes rule its brief carries. NER hits are not shown to the human.
  - **Pattern hits → the human view.** `patterns.txt` holds one line per hit, `<file>:<line> | «<the matched line>»`. They are deterministic, so they go straight to the view (step 5c) beside the agent's flags; each is a decision.
- **Never auto-block on a count and never auto-accept.** Source code is noisy: `--git` scores 0.85 as `PERSON`, the same as a real name. The agent reads past that noise; the human reads the agent's flags and the pattern hits.

In `--dry-run`, this step runs in full on the `dry-run/<change-slug>` branch from step 3 and prints coverage and the `scan:` line, and the run continues to step 5, which ends it (`push-skill: dry-run-end`).

### 5. Final check — scanners, an agent flag pass, then the human

This is **mandatory**. The scanners do not replace it: NER cannot tell a real colleague's first name from an example, misses handles, client names, codenames and deal amounts outright, and the pattern list only knows what someone enumerated. The agent is the primary detector; three passes, in order:

1. **Scanners** — step 4: NER hits listed for the agent, pattern hits listed for the human.
2. **Agent flag pass** — a reader with no stake in the port reads every added line of the outgoing diff, the commit message and the PR title and body for personal or business context, and answers every item of two lists: the **new-vocabulary list** (its focus list: every added prose line, code token, filename-like string and path segment holding a word or name the base tree has never contained) and the **NER list** from step 4.
3. **Human** — reads the agent's flags, the pattern hits, the files touched and the counts, and gives one explicit OK.

#### 5a. The diff, its new-vocabulary list and the agent's brief

```bash
# --- push-skill: full-diff ---
umask 077; cd "${TEMPLATE:?}" || exit 1; : "${SCAN_DIR:?}"; : "${BASE:?}"
rm -f "$SCAN_DIR/full.diff" "$SCAN_DIR/vocab.txt" "$SCAN_DIR/paths-5a.txt" "$SCAN_DIR/brief.txt" "$SCAN_DIR/flags.txt" "$SCAN_DIR/flags.ok" "$SCAN_DIR/digest.txt"   # a new diff invalidates any earlier list, brief, reply, flag pass and view
[ -f "$SCAN_DIR/ner.txt" ] && [ -f "$SCAN_DIR/patterns.txt" ] && [ -f "$SCAN_DIR/scan.ok" ] || { echo "STOP: CANNOT-CHECK — no step-4 scan in $SCAN_DIR (ner.txt, patterns.txt, scan.ok); run step 4 first"; exit 1; }
[ "$({ git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" && cat "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" && git rev-parse --abbrev-ref HEAD; } | cksum)" = "$(cat "$SCAN_DIR/scan.ok")" ] \
  || { echo "STOP: CANNOT-CHECK — the step-4 scan was of other content (the change or its message moved since); re-run step 4"; exit 1; }
git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" > "$SCAN_DIR/full.diff" || { echo "STOP: CANNOT-CHECK — git diff against $BASE failed"; exit 1; }
[ -s "$SCAN_DIR/full.diff" ] || { echo "STOP: CANNOT-CHECK — nothing staged against $BASE; there is nothing to read"; exit 1; }
git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached --name-only -z --no-renames "$BASE" > "$SCAN_DIR/paths-5a.txt" || { echo "STOP: CANNOT-CHECK — git diff --name-only against $BASE failed"; exit 1; }
FP="${VAULT:?}/.openbrain/lib/flag-pass.sh"; [ -f "$FP" ] || { echo "STOP: CANNOT-CHECK — .openbrain/lib/flag-pass.sh is missing or did not load; it ships with /push-openbrain-template — restore it from the template (git checkout <template>/main -- .openbrain/lib/flag-pass.sh)"; exit 1; }
. "$FP"; typeset -f focus_brief >/dev/null 2>&1 && typeset -f flags_check >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — .openbrain/lib/flag-pass.sh is missing or did not load; it ships with /push-openbrain-template — restore it from the template (git checkout <template>/main -- .openbrain/lib/flag-pass.sh)"; exit 1; }
focus_brief || exit 1   # the focus list and the brief, from .openbrain/lib/flag-pass.sh
[ -s "$SCAN_DIR/brief.txt" ] && [ -f "$SCAN_DIR/vocab.txt" ] || { echo "STOP: CANNOT-CHECK — focus_brief wrote no brief.txt or vocab.txt"; exit 1; }
echo "full diff: $SCAN_DIR/full.diff  ($(wc -l < "$SCAN_DIR/full.diff" | tr -d ' ') lines)"
echo "new-vocabulary list: $SCAN_DIR/vocab.txt  ($(wc -l < "$SCAN_DIR/vocab.txt" | tr -d ' ') entries) — the flag pass's focus list"
echo "NER list: $SCAN_DIR/ner.txt  ($(wc -l < "$SCAN_DIR/ner.txt" | tr -d ' ') items, from step 4)"
echo "agent brief: $SCAN_DIR/brief.txt  (fakes rule from $VAULT/$FLAG_PASS_FAKES_REL)"
```

#### 5b. Agent flag pass

Spawn a **fresh subagent** (no prior context — never a fork of this session) and give it **only** the text of `$SCAN_DIR/brief.txt`, verbatim (it names the seven files the agent reads: the diff, the focus list, the NER list, the commit message, the PR title, the PR body and the branch name), plus one line naming the user's own identifiers you already know (name, employer, email domains), so it can recognise them. Give it none of the porting reasoning: it is useful because it does not know what you meant to keep. The brief is generated by 5a at every run; its declared-fakes rule is built from `bootstrap/lib/pii-fakes.txt`, never written into this skill. Where the substrate has no subagents, do the pass yourself as a separate step, reading only those seven files, and say so on the `mode:` line.

Save its reply verbatim to `$SCAN_DIR/flags.txt`, with a first line `mode: subagent` or `mode: same-agent`, then check it. The agent counts nothing — the check computes the file and added-line totals from the diff itself — and it answers for four things: its item lines are **exactly** the ids of the focus list and of the NER list (a missing, extra or repeated id is CANNOT-CHECK: a skipped NER id is a STOP, never a pass), every other flag points at a real added `file:line` or a real line of the commit message, PR title, PR body or branch name, every flag's text is on what it cites (the focus item without its label, or its line or path; the NER item's text, unescaped; the cited line) as whole words — the rule the brief declares: at least 2 characters, one a letter or digit, no letter, digit or combining mark running on past either end (camelCase steps break: `get|ACME|Token`, `HTTP|Server`; so does a source escape ending right before it, `\u00a0|Name`, never decoded), NFC-normalised, any whitespace run as one space, otherwise verbatim, and the reply says `none found` when it flags nothing. A reply that skipped items, invented locations or said nothing is caught, not trusted:

```bash
# --- push-skill: flags-check ---
: "${SCAN_DIR:?}"; rm -f "$SCAN_DIR/flags.ok"   # FIRST: a run that stops at the preflight below leaves no stale pass
FP="${VAULT:?}/.openbrain/lib/flag-pass.sh"; [ -f "$FP" ] || { echo "STOP: CANNOT-CHECK — .openbrain/lib/flag-pass.sh is missing or did not load; it ships with /push-openbrain-template — restore it from the template (git checkout <template>/main -- .openbrain/lib/flag-pass.sh)"; exit 1; }
. "$FP"; typeset -f focus_brief >/dev/null 2>&1 && typeset -f flags_check >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — .openbrain/lib/flag-pass.sh is missing or did not load; it ships with /push-openbrain-template — restore it from the template (git checkout <template>/main -- .openbrain/lib/flag-pass.sh)"; exit 1; }
flags_check || exit 1   # the reply check, from .openbrain/lib/flag-pass.sh
```

#### 5c. The human view

```bash
# --- push-skill: digest ---
umask 077; cd "${TEMPLATE:?}" || exit 1
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"; [ -d "$SCAN_DIR" ] || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing"; exit 1; }
: "${BASE:?export BASE — the same base step 4 scanned against}"
[ -f "$SCAN_DIR/flags.ok" ] || { echo "STOP: CANNOT-CHECK — the agent flag pass has not passed flags-check (5b); the human reads flags first"; exit 1; }
for f in ner.txt patterns.txt scan.ok scan-notes.txt vocab.txt; do [ -f "$SCAN_DIR/$f" ] || { echo "STOP: CANNOT-CHECK — no step-4 lists in $SCAN_DIR ($f missing); run step 4, 5a and 5b"; exit 1; }; done
S="$({ git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" && cat "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" && git rev-parse --abbrev-ref HEAD; } | cksum)" || { echo "STOP: CANNOT-CHECK — could not stamp the staged change"; exit 1; }
[ "$S" = "$(cat "$SCAN_DIR/flags.ok")" ] && [ "$(cat "$SCAN_DIR/full.diff" "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" "$SCAN_DIR/branch.txt" | cksum)" = "$S" ] \
  || { echo "STOP: CANNOT-CHECK — the flag pass read other content (the change or its messages moved since 5a); re-run step 4, 5a and 5b"; exit 1; }
[ "$S" = "$(cat "$SCAN_DIR/scan.ok")" ] || { echo "STOP: CANNOT-CHECK — the step-4 scan was of other content (the change or its message moved since); re-run step 4, 5a and 5b"; exit 1; }
python3 - "$SCAN_DIR" "$BASE" > "$SCAN_DIR/digest.txt" <<'PY' || { rm -f "$SCAN_DIR/digest.txt" "$SCAN_DIR/flags.ok"; echo "STOP: CANNOT-CHECK — could not build the view (an unparseable diff, list or reply, or a flag the view did not show — above)"; exit 1; }
import os, re, sys, unicodedata
sd, base = sys.argv[1], sys.argv[2]
rd = lambda f: [l.rstrip("\n") for l in open(os.path.join(sd, f), encoding="utf-8", errors="replace")]
files, hdr, text, order = [], False, {}, {}
for l in rd("full.diff"):
    if l.startswith("diff --git "): files.append({"path": None, "kind": "modified", "a": 0, "d": 0, "git": l[11:]}); hdr = True; continue
    if hdr:
        if l.startswith("new file mode"): files[-1]["kind"] = "new"
        elif l.startswith("deleted file mode"): files[-1]["kind"] = "deleted"
        elif l.startswith("rename from "): files[-1]["kind"] = "renamed from " + l[12:]
        elif l.startswith("Binary files "): files[-1]["kind"] += ", binary"
        elif l.startswith("--- ") and l != "--- /dev/null": files[-1]["path"] = files[-1]["path"] or l[6:].rstrip("\t")
        elif l.startswith("+++ ") and l != "+++ /dev/null": files[-1]["path"] = l[6:].rstrip("\t")
        elif l.startswith("@@"):
            hdr = False; n = int(re.match(r"@@ -\S+ \+(\d+)", l).group(1)); order.setdefault(files[-1]["path"], len(order))
        continue
    if l.startswith("@@"): n = int(re.match(r"@@ -\S+ \+(\d+)", l).group(1)); continue
    if l.startswith("+"): files[-1]["a"] += 1; text["%s:%d" % (files[-1]["path"], n)] = l[1:]; n += 1
    elif l.startswith("-"): files[-1]["d"] += 1
    elif not l.startswith("\\"): n += 1
MSG = ("commit-msg", "pr-title", "pr-body", "branch-name", "path-list")
for t, f in (("commit-msg", "commit-msg.txt"), ("pr-title", "pr-title.txt"), ("pr-body", "pr-body.txt"), ("branch-name", "branch.txt"), ("path-list", "paths.txt")):
    if os.path.exists(os.path.join(sd, f)):
        for k, l in enumerate(rd(f), 1): text["%s:%d" % (t, k)] = l
vocab = {}
for l in rd("vocab.txt"):
    p = l.split(" | ")
    if len(p) >= 3: vocab[p[0]] = (p[1], p[2]); text.setdefault(p[1], p[1][:-5] if p[1].endswith(":path") else p[2])   # a path segment's path stands for its line
ner = {}
for l in rd("ner.txt"):
    p = l.split(" | ", 3)
    if len(p) == 4: ner[p[0]] = (p[1], p[2].split(", "), p[3])
fl = rd("flags.txt"); flags = []   # one (text, [locations], reason) per agent flag
who = {"mode: subagent": "A separate agent read the whole change",   # from the reply's mode line; any other line refuses the view
       "mode: same-agent": "The agent that prepared this change read the whole change itself (no separate agent was available)"}[fl[0] if fl else ""]
for l in fl[1:]:
    m = re.fullmatch(r"([vn]\d+) \| (ok|flag) \| (.+)", l.strip())
    if m:
        if m.group(2) != "flag": continue
        i = m.group(1); t, _, why = m.group(3).rpartition(" | ")
        if i[0] == "v": flags.append((t, [vocab[i][0]], why))
        else: flags.append((t, ner[i][1], why))
        continue
    if " | " in l and l.strip() != "none found" and not l.startswith("coverage:"):
        loc, _, rest = l.partition(" | "); t, _, why = rest.rpartition(" | "); flags.append((t, [loc], why))
nfc = lambda s: unicodedata.normalize("NFC", s); norm = lambda s: " ".join(nfc(nfc(s).casefold()).split())   # whitespace runs as one space, as flags-check reads them
def key(loc):
    f, _, ln = loc.rpartition(":"); ln = int(ln) if ln.isdigit() else 0
    return (1 + MSG.index(f), 0, ln) if f in MSG else (0, order.get(f, len(order)), ln)
bn = {}
for f in files: bn.setdefault(os.path.basename(f["path"] or ""), set()).add(f["path"])
def short(loc):   # a file's basename when no other file of the change shares it, else its path
    f, _, ln = loc.rpartition(":")
    return loc if f in MSG or os.path.basename(f) in MSG or len(bn.get(os.path.basename(f), ())) != 1 else "%s:%s" % (os.path.basename(f), ln)
def snip(t, loc, w=60):   # ~60 characters of the line centred on the flagged text, never more
    ln = " ".join(nfc(text.get(loc, "")).split()); t = " ".join(nfc(t).split()); i = ln.find(t)   # NFC, whitespace runs as one space (as flags-check reads it)
    if i < 0: return None
    if len(t) >= w: return t
    s0 = max(0, min(i - (w - len(t)) // 2, len(ln) - w)); e0 = min(len(ln), s0 + w)
    return ("…" if s0 else "") + ln[s0:e0] + ("…" if e0 < len(ln) else "")
groups = {}   # the flagged text, case- and NFC-insensitive → its spellings and its flags
for t, locs, why in flags:
    g = groups.setdefault(norm(t), {"sp": {}, "fl": []}); g["sp"].setdefault(nfc(t), None); g["fl"].append((locs, why))
N = lambda n, w, pl=None: "%d %s" % (n, w if n == 1 else (pl or w + "s"))   # 1 place / 3 places
out = []
for g in sorted(groups.values(), key=lambda g: min(key(x) for ls, _ in g["fl"] for x in ls)):
    locs = sorted({x for ls, _ in g["fl"] for x in ls}, key=key); whys = list(dict.fromkeys(w for _, w in g["fl"]))
    t = " / ".join("«%s»" % x for x in g["sp"]); hits = N(len(locs), "place")
    if len(whys) == 1: out += ["  %s — %s — %s" % (t, whys[0], hits), "    " + ", ".join(short(x) for x in locs)]
    else:
        out.append("  %s — %s, %d reasons:" % (t, hits, len(whys)))
        for w in whys: out.append("    %s — %s" % (w, ", ".join(short(x) for x in sorted({x for ls, y in g["fl"] if y == w for x in ls}, key=key))))
    ctx = next(((x, c) for x in locs for c in [next((snip(sp, x) for sp in g["sp"] if snip(sp, x)), None)] if c), None)
    if ctx: out.append("    context (%s): %s" % (short(ctx[0]), ctx[1]))
nflag, nloc = len(flags), len({x for _, ls, _ in flags for x in ls})
pats = [l for l in rd("patterns.txt") if l.strip()]
notes = rd("scan-notes.txt"); local = next((x.split("=", 1)[1] for x in notes if x.startswith("local-patterns=")), "?")
V = ["Agent review — %s in %s, %s:" % (N(nflag, "flag"), N(nloc, "place"), N(len(groups), "distinct text")) if nflag else
     "Agent review — nothing flagged. %s: all %s, all %s from the local personal-info (PII) scanner, the commit message, the PR text and the branch name." % (who, N(len(vocab), "checklist item"), N(len(ner), "detection"))] + out
V.append("Exact-match rules — %s. (Rules for keys, tokens, IDs, home paths and your private list; every match needs your decision.)" % (N(len(pats), "match", "matches") if pats else "nothing matched"))
V += ["  " + x for x in pats]
V.append("Blocking problems — none. (Any would have stopped the run before this summary.)")
for x in notes:   # the private-list sync's state, in plain words (an unknown state is shown as it came)
    if not x.startswith("pii-patterns sync: ") or x.startswith("pii-patterns sync: ok"): continue
    st = x[len("pii-patterns sync: "):]
    V.append("  warning: " + ("the template clone's private pattern list holds entries the vault's copy lacks, so it was not refreshed from the vault — the clone's copy ran as is" if st.startswith("WARN")
             else "this vault has no tool to sync the private pattern list (a template vault has none) — the clone's copy ran as is" if st.startswith("MISSING") else "the private pattern list's sync reported: " + st))
if local == "absent": V.append("  warning: this machine has no private pattern list — only the built-in rules ran")
V.append("Files changed (vs %s) — %s, +%d −%d:" % (base, N(len(files), "file"), sum(f["a"] for f in files), sum(f["d"] for f in files)))
V += ["  %s  +%d −%d  %s" % (f["path"] or f["git"], f["a"], f["d"], f["kind"]) for f in files]
V.append("Totals: %s and %s, all reviewed · %s%s · %s · your private list: %s"
      % (N(len(vocab), "checklist item"), N(len(ner), "scanner detection"), N(nflag, "agent flag"), " in " + N(nloc, "place") if nflag else "", N(len(pats), "rule match", "rule matches"),
         local if local in ("absent", "?") else N(int(local), "entry", "entries") if local.isdigit() else local))
V.append("To check the agent's work, ask to see the full change (%s), its checklist (%s) or the PII scanner's detections (%s)." % (N(len(rd("full.diff")), "line"), N(len(vocab), "item"), N(len(ner), "item")))
# no flag may disappear: read the finished view back — each flag is shown when one «text» block of the flags section
# carries its text, its reason and every one of its locations — and compare with a raw count of the reply's flag lines
blocks, cur = [], None
for x in V[1:]:
    if x.startswith("Exact-match rules — "): break
    if x.startswith("  «"): cur = [x]; blocks.append(cur)
    elif cur is not None: cur.append(x)
def shown_at(b, why):   # the locations a block shows under exactly this reason: a one-reason header ending « — <reason> — N places»
    body = [x for x in b[1:] if not x.startswith("    context (")]   # and its location line, or a «    <reason> — <locations>» line
    if not re.search(r" — \d+ places?, \d+ reasons:$", b[0]): return set(body[0][4:].split(", ")) if body and re.fullmatch(r".* — " + re.escape(why) + r" — \d+ places?", b[0]) else set()
    return {y for x in body if x.startswith("    %s — " % why) and " — " not in x[len("    %s — " % why):] for y in x[len("    %s — " % why):].split(", ")}   # a longer reason that starts with this one is not this one
seen = lambda t, locs, why: any("«%s»" % nfc(t) in b[0] and {short(x) for x in locs} <= shown_at(b, why) for b in blocks)
shown = sum(1 for f in flags if seen(*f))
raw = sum(1 for l in fl[1:] if l.strip() and l.strip() != "none found" and not l.startswith("coverage:") and not re.fullmatch(r"[vn]\d+ \| ok \| .+", l.strip()))
if not (shown == raw == len(flags)):
    sys.stderr.write("the view shows %d flag(s); the reply holds %d (parsed %d) — refusing a view that drops one\n" % (shown, raw, len(flags))); sys.exit(1)
print("\n".join(V))
PY
cat "$SCAN_DIR/digest.txt"
```

**Paste this view verbatim into your reply text, in full, as one fenced block** — every line the block printed, in its order: **Agent review** (the agent's flags grouped by the flagged text, case- and NFC-insensitive, each group with every reason and every place; the view refuses to build if a flag would go unshown), **Exact-match rules** (the pattern hits), **Blocking problems** with any warnings, **Files changed**, **Totals** and the footer. A summary, a paraphrase, a reordering or an excerpt is not the view, and a view that lives only in tool output has not been shown: on a remote or mobile surface the user cannot see tool output. A long view is pasted whole all the same. The view names no scratch file: the full change, the checklist (focus list), the detections (NER list) and the brief are `$SCAN_DIR/full.diff`, `vocab.txt`, `ner.txt` and `brief.txt` (5a printed them), opened only when the user asks. Do not open anything in an app for the user (the starters run on more than one OS). Then prompt the user via `AskUserQuestion` — **one decision for the whole run**:

> The agent flagged <nothing | K things in L places> across <V> checklist items and <N> scanner detections, and <no exact-match rule matched | P exact-match rules matched>. Does anything look wrong?
>
> Options:
> - **Looks good — commit**
> - **Decide each** — one `AskUserQuestion` per flag group and per pattern hit. A flag group is one reason line of a text's block in the view (the text is case- and NFC-insensitive, the reason exact): a text flagged for two reasons is two decisions, and each answer applies at every location the view lists for it — **Drop the file** drops every file among them. **Fix** (rewrite it generically per step 3, `git add -A`, re-run from step 4 — a fix can introduce new text, and only the index is scanned or committed), **Drop the file** (`git reset -q -- <file> && git checkout -q -- <file>` for a modified file, `git rm -q --cached <file> && rm <file>` for a new one, then re-run from step 4), or **Accept with reason** (recorded in the commit body as `PII-review: accepted <flag | pattern> in <file> — <reason>`, one line per file the group or hit touches and one per message it sits in (`in commit-msg`, `in pr-title`, `in pr-body`, `in branch-name`), the kind and the file, never the matched text; the message changed, so re-run from step 4)
> - **Revert all** (`git reset -q --hard && git checkout main && git branch -D <change-slug>` in the template repo, then `rm -rf "$SCAN_DIR"`)
> - **Show me X** — the full change, its checklist, the scanner detections, a staged file or a hunk

Only proceed to step 6 on an explicit **Looks good — commit** for this view. Silence, an answer to an earlier view or an OK given before the view was pasted is not one. Then delete the sensitive artefacts (this includes the step-1 path inventories — `vault.all` lists every note title in the vault — and both step-4 lists). The list is step 4's `shred_findings` list, minus the two stamps; `find`, not an `rm` glob, because zsh aborts an `rm` whose glob matches nothing. It keeps `commit-msg.txt`, `pr-title.txt`, `pr-body.txt`, `coverage.txt`, the step-5 files and the stamps `scan.ok` and `flags.ok`, which step 6 re-checks before it commits:

```bash
# --- push-skill: post-ok ---
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"; [ -d "$SCAN_DIR" ] || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing"; exit 1; }
find "$SCAN_DIR" -maxdepth 1 \( -name '*.json' -o -name '*.pat' -o -name '*.urls' -o -name '*.err' -o -name 'blob.txt' -o -name 'hunk.*' -o -name 'local-patterns.txt' \
  -o -name '*.all' -o \( -name '*.ok' ! -name 'scan.ok' ! -name 'flags.ok' \) -o -name '*.lst' -o -name 'outgoing.tsv' -o -name 'paths*.txt' -o -name 'branch.txt' -o -name 'findings.idx' \
  -o -name '*.hits' -o -name '*.map' -o -name 'hits.idx' -o -name 'ner.txt' -o -name 'patterns.txt' -o -name 'local-words.txt' -o -name 'deps.*' -o -name 'deps-*' \) -exec rm -f {} + || { echo "STOP: could not delete the sensitive artefacts in $SCAN_DIR"; exit 1; }
[ -f "$SCAN_DIR/scan.ok" ] && [ -f "$SCAN_DIR/flags.ok" ] || { echo "STOP: CANNOT-CHECK — scan.ok or flags.ok is missing; step 6 cannot re-check the change; re-run from step 4"; exit 1; }
echo "sensitive artefacts deleted; kept for step 6: drafts, coverage.txt, full.diff, scan.ok, flags.ok"
```

In `--dry-run`, run 5a, 5b and 5c in full and paste the view, then skip the prompt and end with the block below instead of step 6 — a full rehearsal that commits and pushes nothing. It refuses unless the flag pass and the view both ran, and it removes the dry-run branch and the scratch dir:

```bash
# --- push-skill: dry-run-end ---
cd "${TEMPLATE:?}" || exit 1; : "${SCAN_DIR:?}"; : "${DRY_BRANCH:?export DRY_BRANCH=<the dry-run/… branch step 3 made>}"
case "$DRY_BRANCH" in dry-run/?*) ;; *) echo "STOP: DRY_BRANCH '$DRY_BRANCH' is not a dry-run/ branch — refusing to delete it"; exit 1 ;; esac
[ -f "$SCAN_DIR/flags.ok" ] && [ -s "$SCAN_DIR/digest.txt" ] || { echo "STOP: CANNOT-CHECK — the dry run did not reach step 5 (no checked flag pass, or no view); run 5a–5c first"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "$DRY_BRANCH" ] || { echo "STOP: the clone is not on $DRY_BRANCH"; exit 1; }
git reset -q --hard && git checkout -q main && git branch -q -D "$DRY_BRANCH" && rm -rf "$SCAN_DIR" && echo "dry run complete through step 5: $DRY_BRANCH and the scratch dir removed; nothing committed or pushed"
```

### 6. Commit, push, and open PR

Commit with the scanned message (it carries the accept-with-reason lines). The commit block first runs the stamps check — its own marked block, `push-skill: stamps-check`, extracted and run, never copied. The check recomputes the stamp the way steps 4 and 5b wrote it and STOPs when either differs (a change or a message edited after the OK was never scanned, flagged or read), and it asserts `HEAD` is `BASE` (a commit already on the change branch carries a message no step scanned) and that `BASE` is published — an ancestor of `DEST_REF`, or for a stacked change of its own pushed ref — since a commit only on the local base rides along on the push unscanned.

```bash
# --- push-skill: stamps-check ---
set -o pipefail; cd "${TEMPLATE:?}" || exit 1
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"; : "${BASE:?export BASE — the same base step 4 scanned against}"; : "${DEST_REF:?export DEST_REF — the destination step 0a (push) or share-skill: dest printed}"
[ -f "$SCAN_DIR/scan.ok" ] && [ -f "$SCAN_DIR/flags.ok" ] || { echo "STOP: CANNOT-CHECK — scan.ok or flags.ok is missing from $SCAN_DIR; nothing committed; re-run from step 4"; exit 1; }
# BASE itself must already be published — on the destination, or (a stacked change) on the parent branch's published ref:
# a commit only on the local BASE was never scanned and would ride along on the push
PUBREF=""; git merge-base --is-ancestor "$BASE" "$DEST_REF" 2>/dev/null && PUBREF="$DEST_REF"
if [ -z "$PUBREF" ]; then BB="${BASE#refs/heads/}"
  while IFS= read -r rr; do [ "${rr#refs/remotes/*/}" = "$BB" ] && git merge-base --is-ancestor "$BASE" "$rr" && { PUBREF="$rr"; break; }; done < <(git for-each-ref --format='%(refname)' refs/remotes/)
fi
[ -n "$PUBREF" ] || { echo "STOP: BASE ($BASE) is not published — it is not on $DEST_REF nor on a pushed copy of itself; its own commits ($(git rev-list --count "$DEST_REF..$BASE" 2>/dev/null || echo '?') past $DEST_REF) were never scanned and would ride along; nothing committed"; exit 1; }
HC="$(git rev-parse -q --verify 'HEAD^{commit}')" && BC="$(git rev-parse -q --verify "$BASE^{commit}")" || { echo "STOP: CANNOT-CHECK — HEAD or BASE ($BASE) does not resolve; nothing committed"; exit 1; }
[ "$HC" = "$BC" ] || { echo "STOP: HEAD ($(git rev-parse --short HEAD)) is not BASE ($BASE = $(git rev-parse --short "$BC")) — the branch already carries $(git rev-list --count "$BC..HEAD" 2>/dev/null || echo '?') commit(s) past BASE whose messages no step scanned; nothing committed. Reset to BASE (keeping the change staged) or re-run from step 3"; exit 1; }
S="$({ git -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv --cached "$BASE" && cat "$SCAN_DIR/commit-msg.txt" "$SCAN_DIR/pr-title.txt" "$SCAN_DIR/pr-body.txt" && git rev-parse --abbrev-ref HEAD; } | cksum)" \
  || { echo "STOP: CANNOT-CHECK — could not recompute the stamp; nothing committed"; exit 1; }
[ "$S" = "$(cat "$SCAN_DIR/scan.ok")" ] && [ "$S" = "$(cat "$SCAN_DIR/flags.ok")" ] \
  || { echo "STOP: CANNOT-CHECK — the staged change or its message moved since the OK; the scan, the flag pass and the human read other content. Nothing committed; re-run from step 4"; exit 1; }
echo "stamps: the staged change, its message and its branch name are what step 4 scanned, 5b flagged and 5c showed; HEAD = BASE ($(git rev-parse --short HEAD)), published on $PUBREF"
```

```bash
# --- push-skill: commit ---
set -o pipefail; umask 077; cd "${TEMPLATE:?}" || exit 1
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0d printed>}"; : "${BASE:?export BASE — the same base step 4 scanned against}"
STAMPS="$(bash "${VAULT:?}/.openbrain/lib/extract-block.sh" "$VAULT/.claude/skills/push-openbrain-template/SKILL.md" 'push-skill: stamps-check')" \
  || { echo "STOP: CANNOT-CHECK — could not extract push-skill: stamps-check from the vault's push skill; nothing committed"; exit 1; }
eval "$STAMPS"
git commit -q -F "$SCAN_DIR/commit-msg.txt" && git log -1 --stat
```

**The public push is gated on the user's explicit go, in this session, for this push.** Ask via `AskUserQuestion` — "Push `<change-slug>` to `<origin URL>` and open the PR?" — and stop on anything but yes. A scheduled or non-interactive run never reaches this line.

```bash
cd "${TEMPLATE:?}" && git push -u origin HEAD || exit 1
if [ -n "${PR_BASE:-}" ]; then gh pr create --base "$PR_BASE" --title "$(cat "$SCAN_DIR/pr-title.txt")" --body-file "$SCAN_DIR/pr-body.txt"
else                           gh pr create                   --title "$(cat "$SCAN_DIR/pr-title.txt")" --body-file "$SCAN_DIR/pr-body.txt"; fi
```

(`PR_BASE` is the parent PR's branch for a stacked change; unset otherwise. Two literal invocations rather than `${PR_BASE:+--base "$PR_BASE"}`, which zsh expands to one word.) The PR body keeps the genericization checklist:

```markdown
## Summary
<1-3 bullet points describing what was ported>

## Genericization checklist
- [ ] No real names, emails, or account slugs
- [ ] No hardcoded paths (`/Users/...`)
- [ ] No Asana workspace gids
- [ ] No OAuth/Slack tokens
- [ ] CLAUDE.md placeholders (`{{USER_NAME}}` etc.) preserved
- [ ] Scanned: <coverage.txt summary — counts only>
```

Then drop this change's drafts and return the clone to `main`:

```bash
rm -f "$SCAN_DIR"/commit-msg.txt "$SCAN_DIR"/pr-title.txt "$SCAN_DIR"/pr-body.txt "$SCAN_DIR"/coverage.txt "$SCAN_DIR"/scan-notes.txt "$SCAN_DIR"/scan.ok "$SCAN_DIR"/flags.ok; cd "${TEMPLATE:?}" && git checkout main
```

Repeat steps 3–6 for the next change. After the last one, `rm -rf "$SCAN_DIR"`.

### 7. Report

Output to the user:

- **PR URL(s)** — one per change.
- **Scan coverage** — the `coverage.txt` lines (labels, sizes, exit codes, hit counts) and the disposition tally (fixed / dropped / accepted). Never the findings themselves.
- **Ported**: list of files changed in the template repo, one line each, with a 5–10 word summary of what was ported.
- **Skipped (personal-only)**: files where the diff was 100% personal data and nothing was worth porting.
- **Skipped (regression)**: files where the template was *ahead* of the vault — the user should run `/pull-openbrain-template` to pull these forward. Include a `git diff` snippet so they can see what's missing.
- **Flagged for manual review**: files where the genericization was non-trivial and the user should look at the PR diff before merging.
- **Vault-only files added**: new files added to the template repo.

## Output

A structured report (the items in §7) plus the PR URL(s).

## Notes

- This skill is **read-mostly on the vault side, write-only on the template side**. It must never edit the vault.
- The skill is **idempotent**: running it twice in a row should produce a no-op the second time, because the template will already match the genericized vault.
- The skill **never touches secrets**: it never reads `~/.config/openbrain/.env`, and everything it is about to publish goes through step 4 before the commit exists.
- The template's `pre-push` hook (`.openbrain/pre-push.sh`) is a protected-remote URL guard only — it scans no content and no commit messages. Step 4 is the content check; do not treat the hook as a backstop.
- If the user asks `/push-openbrain-template all` and the diff is huge, batch the work change-by-change with a brief progress line, rather than one giant report.
- This skill is itself a candidate for porting. The template version helps users keep their personal forks in sync with their own upstreams.
- Callers (any skill layered on these blocks, for enumerate/scan) extract the marked block range (`# --- push-skill: <name> ---` through the closing fence) and never read this file whole — a whole-file read is a ~70% per-run cost increase. Extraction runs through the shared helper, `.openbrain/lib/extract-block.sh` (ships alongside this skill) — see `/pull-openbrain-template`'s Notes for the command form (both `<file>` and the helper's own path always absolute — a caller's cwd may have moved into a clone) and cost figure. `deny()` and `in_roots()` are no longer extracted from this file's live text by anyone — every sync skill, including `/pull-openbrain-template`'s plan block, sources them directly from `.openbrain/lib/template-scope.sh`. Likewise `focus_brief()` (5a's two builders) and `flags_check()` (5b's reply check) live in `.openbrain/lib/flag-pass.sh`, sourced by this skill.
