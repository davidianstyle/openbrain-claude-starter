---
name: pull-openbrain-template
description: Pull the latest changes from the upstream openbrain-claude-starter repo into this vault — a take of the template's public main from the last dispositioned point, per-file 3-way merge, one marker row when everything is dispositioned.
---

# /pull-openbrain-template

Pull improvements from the upstream [openbrain-claude-starter](https://github.com/davidianstyle/openbrain-claude-starter) repo into this vault. The inverse of `/push-openbrain-template`. This skill hosts the shared plan/apply/mark mechanism directly, with `upstream` as its own built-in topic: the topic is the template's public `main`, the marker is the `upstream` row of `.openbrain/local/taken.tsv`, and nothing is inferred from file contents — what is incoming is exactly what `main` changed since the last dispositioned sha. A vault-side change is never "incoming" (Notes).

The template repo must be cloned locally — by default at `~/openbrain-claude-starter`. Set `OPENBRAIN_TEMPLATE_DIR` to override. The clone's `upstream` remote is the template; a clone of the template itself (a colleague's) has only `origin`, which is then used.

## Inputs

- `$1` (optional): `--dry-run` — plan, write nothing, delete the scratch dir.

Scope (`PORTABLE_ROOTS`) and the hard-deny list are both defined once in `.openbrain/lib/template-scope.sh` and sourced by the plan block below — the same file `/push-openbrain-template` sources; `.openbrain/template-ignore` is this vault's own file, read directly by this skill.

## Procedure

### 0. Preconditions

```bash
# --- pull-skill: preflight ---
VAULT="$(pwd)"; TEMPLATE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
[ ! "$VAULT" -ef "$TEMPLATE" ] || { echo "STOP: run this from the vault root, not the template clone ($VAULT)"; exit 1; }
[ -d "${TEMPLATE:?}/.git" ] || { echo "STOP: no template clone at $TEMPLATE"; exit 1; }
UPR=origin; (cd "$TEMPLATE" && git remote) > "${TMPDIR:-/tmp}/pull-remotes.$$" || { echo "STOP: CANNOT-CHECK — git remote failed"; exit 1; }; LC_ALL=C command grep -qx upstream "${TMPDIR:-/tmp}/pull-remotes.$$" && UPR=upstream; HAS_STAGING=0; LC_ALL=C command grep -qx staging "${TMPDIR:-/tmp}/pull-remotes.$$" && HAS_STAGING=1; rm -f "${TMPDIR:-/tmp}/pull-remotes.$$"
( cd "$TEMPLATE" && git checkout -q main && [ -z "$(git status --porcelain)" ] && GIT_TERMINAL_PROMPT=0 git fetch -q --prune "$UPR" && { [ "$HAS_STAGING" -eq 0 ] || GIT_TERMINAL_PROMPT=0 git fetch -q --prune staging; } ) || { echo "STOP: template clone is not clean on main, or fetching $UPR/staging failed"; exit 1; }   # staging too: the plan's direction check compares against taken topic shas, which live there
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'pull-scan.*' -user "$(id -un)" -exec rm -rf {} +
SCAN_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/pull-scan.XXXXXX")" && chmod 700 "$SCAN_DIR" && echo "SCAN_DIR=$SCAN_DIR" && echo "TOPIC=upstream ($UPR/main = $(cd "$TEMPLATE" && git rev-parse --short "$UPR/main"))" || exit 1
```

Shell state does not persist between tool calls: every later block re-derives `VAULT`/`TEMPLATE` and re-exports `SCAN_DIR`, `TOPIC=upstream` and (after the plan) `TIP`.

### 1. Plan — what changed since the last take of this topic, merged into scratch, vault untouched

The **applied marker** is `.openbrain/local/taken.tsv` in the vault: one row per take, `upstream	<sha>	<utc time>` for this skill's runs; the last row for a branch is where the next take starts. The topic this skill's preflight sets (`TOPIC=upstream`) is the public template's `main` (`upstream/main`, or `origin/main` when the clone has no `upstream` remote — a colleague's clone of the template itself), the marker row is `upstream`, and it starts **only from its own declared row** — no merge-base fallback and no start from another topic's row — so a pull with no `upstream` row STOPs and asks for a declared baseline (`bootstrap/setup.sh` records one when it sets a vault up: `git merge-base HEAD <template>/main`, the last template commit the vault carries). Why each start rule: `bootstrap/PII-SCAN-CONTRACT.md`, "Design notes". Nothing is inferred from file contents, tags or a ledger.

```bash
# --- pull-skill: plan ---
set -o pipefail; umask 077
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0 printed>}"; : "${TOPIC:?export TOPIC=<topic name>}"
VAULT="${VAULT:?}"; TEMPLATE="${TEMPLATE:?}"; MARK="$VAULT/.openbrain/local/taken.tsv"
ROW="topic/$TOPIC"; case "$TOPIC" in upstream) UPR=origin; (cd "$TEMPLATE" && git remote) > "$SCAN_DIR/remotes.txt" || { echo "STOP: CANNOT-CHECK — git remote failed"; exit 1; }; LC_ALL=C command grep -qx upstream "$SCAN_DIR/remotes.txt" && UPR=upstream; BR="$UPR/main"; ROW=upstream; echo "upstream preset: the topic is $BR (public template main); marker row 'upstream'" ;; *) BR="staging/topic/$TOPIC" ;; esac   # /take-openbrain-template runs this block with TOPIC=<name> for a staging topic (take ships alongside or after pull)
[ -d "$SCAN_DIR" ] || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing"; exit 1; }
rm -f "$SCAN_DIR/plan.tsv" "$SCAN_DIR/tip.txt"   # FIRST, before anything can STOP: a re-plan that stops part-way leaves no plan and no tip, so apply/mark cannot certify the previous plan for a new tip
cd "$TEMPLATE" || exit 1
LIB="$VAULT/.openbrain/lib/template-scope.sh"
[ -f "$LIB" ] || { echo "STOP: CANNOT-CHECK — template-scope.sh missing at $LIB; restore it from git, or re-pull the template — it ships alongside /push-openbrain-template"; exit 1; }
source "$LIB"
typeset -f deny >/dev/null 2>&1 && typeset -f in_roots >/dev/null 2>&1 || { echo "STOP: CANNOT-CHECK — template-scope.sh sourced but deny()/in_roots() did not load"; exit 1; }
TIP="$(git rev-parse --verify -q "$BR^{commit}")" || { echo "STOP: no $BR in this clone — did the fetch in step 0 run? does the topic exist?"; exit 1; }
FROM=""; ORIGIN=""
if [ -f "$MARK" ]; then FROM="$(LC_ALL=C awk -F'\t' -v b="$ROW" '$1==b {s=$2} END {print s}' "$MARK")"; fi
if [ -n "$FROM" ]; then
  git cat-file -e "$FROM^{commit}" 2>/dev/null || { echo "STOP: CANNOT-CHECK — marker sha $FROM for $ROW is not in this clone (rewritten branch?)"; exit 1; }
  FROM="$(git rev-parse --verify "$FROM^{commit}")"   # a hand-declared row may carry a short sha; every later test compares full shas
  git merge-base --is-ancestor "$FROM" "$TIP" || { echo "STOP: CANNOT-CHECK — marker $FROM ($ROW) is not an ancestor of $TIP: the topic was rewritten; re-take by hand or remove the marker row"; exit 1; }
  ORIGIN="applied marker"
else
  if [ "$TOPIC" = upstream ]; then FROM=""; bestn=999999999   # upstream has no merge-base fallback: the start is a declared row, never a guess
  else FROM="$(git merge-base staging/main "$TIP")" || { echo "STOP: CANNOT-CHECK — no merge-base between staging/main and $BR"; exit 1; }
    ORIGIN="merge-base with staging/main (first take of this topic here)"; bestn="$(git rev-list --count "$FROM..$TIP")" || { echo "STOP: CANNOT-CHECK — git rev-list $FROM..$TIP failed"; exit 1; }; fi
  # A topic STACKED on another starts from the NEAREST taken sha (any topic) that is an ancestor of TIP, when one is,
  # not from the merge-base (which would replay the base topic's snapshot). Upstream never does this.
  if [ -f "$MARK" ] && [ "$TOPIC" != upstream ]; then   # upstream never starts from another topic's row: a topic cut from a newer main carries main's content in its TREE but its take planned only its own commits
    while IFS=$'\t' read -r tb ts tt || [ -n "$tb$ts" ]; do   # a hand-edited file may lack the final newline; the last row still counts
      [ -n "$ts" ] || continue
      git cat-file -e "$ts^{commit}" 2>/dev/null || { echo "note: marker row $tb $ts is not in this clone — ignored as a start point"; continue; }
      git merge-base --is-ancestor "$ts" "$TIP" || continue
      n="$(git rev-list --count "$ts..$TIP")" || { echo "STOP: CANNOT-CHECK — git rev-list $ts..$TIP failed"; exit 1; }
      if [ "$n" -lt "$bestn" ]; then FROM="$ts"; bestn="$n"; ORIGIN="stacked on the applied marker of $tb — nearest taken ancestor, $n commit(s) behind the tip"; fi
    done < "$MARK"
  fi
  [ -n "$FROM" ] || { printf '%s\n' "STOP: first pull here — no 'upstream' row in $MARK (a staging topic's row is never a substitute: its take planned only that topic's own commits). Declare the baseline — the last $BR commit this vault is known to carry — with TAB-separated fields:" "  mkdir -p \"$(dirname "$MARK")\" && printf 'upstream\\t%s\\t%s\\n' <sha> \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> \"$MARK\"" "then re-run. Nothing is inferred from file contents."; exit 1; }
fi
echo "take $ROW: $FROM → $TIP ($ORIGIN)"; echo "TIP=$TIP"
if [ "$FROM" = "$TIP" ]; then
  case "$ORIGIN" in applied*) echo "nothing new: the marker already points at the branch tip — 0 changed paths, proven by sha equality" ;;
    stacked*) echo "nothing new: this tip was already taken under another topic's marker ($ORIGIN) — its content is in the vault; no row is written for $ROW" ;;
    *) echo "nothing to take: topic/$TOPIC is already contained in staging/main — its content arrives through /pull-openbrain-template, not here" ;; esac; exit 0
fi
git -c core.quotePath=false diff --name-status "$FROM" "$TIP" > "$SCAN_DIR/incoming.tsv" || { echo "STOP: CANNOT-CHECK — git diff $FROM $TIP failed"; exit 1; }
[ -s "$SCAN_DIR/incoming.tsv" ] || { echo "STOP: CANNOT-CHECK — $FROM and $TIP differ but the diff lists no paths"; exit 1; }
git -c core.quotePath=false ls-tree -r "$TIP" > "$SCAN_DIR/modes.tsv" || { echo "STOP: CANNOT-CHECK — git ls-tree $TIP failed"; exit 1; }   # mode SP type SP sha TAB path
cut -f2- "$SCAN_DIR/incoming.tsv" | tr '\t' '\n' > "$SCAN_DIR/incoming-paths.txt"
if LC_ALL=C command grep -q '^"' "$SCAN_DIR/incoming-paths.txt"; then echo "STOP: a path in the topic needs git quoting (tab, quote or backslash) — refuse"; exit 1; fi
deny "$SCAN_DIR/incoming-paths.txt" > "$SCAN_DIR/incoming-denied-ok.txt"
if [ "$TOPIC" = upstream ]; then   # the public template's main is scoped to PORTABLE_ROOTS too — an upstream-only top-level path outside the roots is out of scope, same as a hard-denied one
  in_roots "$SCAN_DIR/incoming-denied-ok.txt" > "$SCAN_DIR/incoming-allowed.txt" || { echo "STOP: CANNOT-CHECK — in_roots filter failed"; exit 1; }
else   # a staging topic is never additionally roots-gated here — /share-openbrain-template already scoped it at its own enumerate step (inherited from push), including a deliberate bootstrap-hint topic that reaches outside the roots on purpose
  cp "$SCAN_DIR/incoming-denied-ok.txt" "$SCAN_DIR/incoming-allowed.txt" || { echo "STOP: CANNOT-CHECK — could not stage incoming-allowed.txt"; exit 1; }
fi
if ! cmp -s "$SCAN_DIR/incoming-paths.txt" "$SCAN_DIR/incoming-allowed.txt"; then
  LC_ALL=C comm -23 <(LC_ALL=C sort -u "$SCAN_DIR/incoming-paths.txt") <(LC_ALL=C sort -u "$SCAN_DIR/incoming-allowed.txt") > "$SCAN_DIR/denied.lst"
  if [ "$TOPIC" = upstream ]; then echo "out of scope for a pull: $(wc -l < "$SCAN_DIR/denied.lst" | tr -d ' ') path(s) the template ships but a vault never takes from it ($(tr '\n' ' ' < "$SCAN_DIR/denied.lst" | sed 's/ $//')) — never taken (plan rows of kind out-of-scope)"   # + content scaffolding, .env*, bin/, or anything outside PORTABLE_ROOTS: the roots + deny list are the pull's scope
  else echo "STOP: the topic carries hard-denied paths — it should never have been shared; nothing taken:"; cat "$SCAN_DIR/denied.lst"; exit 1; fi
fi
# template-ignore: the vault's declared permanent divergences (one path or glob per line). Matching paths are never taken (a no-byte `ignored` plan row) —
# a permanent decline lives HERE, not in a skip. Never silent: the count and list are printed; a stale exact entry is named.
IGN="$VAULT/.openbrain/template-ignore"; : > "$SCAN_DIR/ignored.lst"
if [ -f "$IGN" ]; then
  while IFS= read -r pat || [ -n "$pat" ]; do
    pat="${pat%$'\r'}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"; pat="${pat#./}"; case "$pat" in ''|'#'*) continue ;; esac
    while IFS= read -r ip; do bash -c 'case "$2" in $1) exit 0 ;; esac; exit 1' _ "$pat" "$ip" && printf '%s\n' "$ip" >> "$SCAN_DIR/ignored.lst"; done < "$SCAN_DIR/incoming-paths.txt"   # glob evaluated by bash: under zsh, `case … in $pat)` matches the text literally
    case "$pat" in *[\*\?\[]*) ;; *) if [ -d "$VAULT/$pat" ]; then echo "template-ignore: '$pat' is a DIRECTORY — entries are file paths or globs; it matches nothing (use '$pat/*')"; else LC_ALL=C command grep -qxF -- "$pat" "$SCAN_DIR/incoming-paths.txt" || [ -e "$VAULT/$pat" ] || git cat-file -e "$TIP:$pat" 2>/dev/null || echo "template-ignore: stale entry '$pat' — gone from both the vault and $BR"; fi ;; esac
  done < "$IGN"
fi
LC_ALL=C sort -u -o "$SCAN_DIR/ignored.lst" "$SCAN_DIR/ignored.lst"; nign="$(wc -l < "$SCAN_DIR/ignored.lst" | tr -d ' ')"
if [ "$nign" -gt 0 ]; then echo "template-ignore: $nign path(s) skipped ($(tr '\n' ' ' < "$SCAN_DIR/ignored.lst" | sed 's/ $//'))"; else echo "template-ignore: 0 path(s) skipped"; fi
if [ -f "$IGN" ] && LC_ALL=C command grep -qxE '[[:space:]]*(\./)?[*]+(/[*]+)*[[:space:]]*' "$IGN"; then echo "STOP: template-ignore has a bare match-everything entry (like '*') — it would ignore the whole template; fix the manifest"; exit 1; fi   # a delta that touches only ignored paths is legitimate: those plan as no-byte `ignored` rows
rm -rf "$SCAN_DIR/merged" "$SCAN_DIR/conflicts"; mkdir -p "$SCAN_DIR/merged" "$SCAN_DIR/conflicts"; : > "$SCAN_DIR/plan.tsv"; : > "$SCAN_DIR/digests.tsv"; : > "$SCAN_DIR/noop.lst"
plan() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SCAN_DIR/plan.tsv"; }; dchecked=0; dflag=0; dgone=0
mode_of() { LC_ALL=C awk -F'\t' -v r="$1" '$2==r {split($1,a," "); print a[1]}' "$SCAN_DIR/modes.tsv"; }
while IFS=$'\t' read -r st rel newrel <&3; do            # not `status`/`path`: zsh specials
  if LC_ALL=C command grep -qxF -- "$rel" "$SCAN_DIR/ignored.lst" || { [ -n "$newrel" ] && LC_ALL=C command grep -qxF -- "$newrel" "$SCAN_DIR/ignored.lst"; }; then plan "${newrel:-$rel}" ignored "template-ignore entry — never taken"; continue; fi   # template-ignore: a no-byte plan row (either side of a rename), counted above
  case "$st" in                                  # out-of-scope check (denied/out-of-roots, counted above) — rename-aware: a rename's source and destination are independent roots questions, not one
    R*)
      newin=1; srcin=1
      if [ "$TOPIC" = upstream ]; then
        LC_ALL=C command grep -qxF -- "$newrel" "$SCAN_DIR/incoming-allowed.txt" || newin=0
        LC_ALL=C command grep -qxF -- "$rel"    "$SCAN_DIR/incoming-allowed.txt" || srcin=0
      fi
      if [ "$newin" -eq 0 ] && [ "$srcin" -eq 0 ]; then plan "$newrel" out-of-scope "outside the pull's scope (hard-denied or outside PORTABLE_ROOTS) — never taken"; continue; fi   # neither side in scope: a no-byte row
      if [ "$newin" -eq 0 ]; then   # destination out of scope: the vault's copy of the (in-scope) source, if any, is now stale — but never orphan a CLAUDE.md-shaped source, and never orphan a source the vault never had
        case "$(printf '%s' "$rel" | tr 'A-Z' 'a-z')" in   # case-folded: APFS is case-insensitive; same test the claude-md and delete rows use
          claude.md|*/claude.md|claude.local.md|*/claude.local.md) plan "$rel" claude-md "renamed to an out-of-scope path ($newrel) in the topic — never applied by the apply block; approve hunk by hunk, edit by hand" ;;
          *) if [ ! -e "$VAULT/$rel" ] && [ ! -L "$VAULT/$rel" ]; then plan "$rel" identical "renamed to an out-of-scope path ($newrel) in the topic; the vault never had $rel — nothing to orphan"
             else plan "$rel" orphan "renamed to an out-of-scope path ($newrel) in the topic — the vault's copy is stale; delete it when ready"; fi ;;
        esac
        continue
      fi
      [ "$srcin" -eq 1 ] && plan "$rel" orphan "renamed away in the topic → $newrel; the old file stays in the vault until you delete it"   # source in scope too: orphan the old path as before; if the source was OUT of scope, the vault never had it under that name, so this destination is a plain 'new', not a rename-with-orphan
      rel="$newrel" ;;
    C*)
      if [ "$TOPIC" = upstream ]; then LC_ALL=C command grep -qxF -- "$newrel" "$SCAN_DIR/incoming-allowed.txt" || { plan "$newrel" out-of-scope "outside the pull's scope (hard-denied or outside PORTABLE_ROOTS) — never taken"; continue; }; fi
      rel="$newrel" ;;
    *)
      if [ "$TOPIC" = upstream ]; then LC_ALL=C command grep -qxF -- "$rel" "$SCAN_DIR/incoming-allowed.txt" || { plan "$rel" out-of-scope "outside the pull's scope (hard-denied or outside PORTABLE_ROOTS) — never taken"; continue; }; fi ;;
  esac
  case "$st" in
    D) if [ ! -e "$VAULT/$rel" ] && [ ! -L "$VAULT/$rel" ]; then plan "$rel" identical "deleted in the topic and already absent from the vault"
       elif [ -f "$VAULT/$rel" ] && [ "$(git hash-object "$VAULT/$rel")" = "$(git rev-parse -q --verify "$FROM:$rel" 2>/dev/null)" ]; then plan "$rel" delete "deleted in the topic; the vault's copy equals what was deleted — nothing is deleted without your explicit approval"
       else plan "$rel" delete "deleted in the topic, but the vault's copy DIFFERS from what was deleted (local edits, or a symlink) — deleting loses them; nothing is deleted without your explicit approval"; fi ;;
    A|M|T|R*|C*)
      case "$(mode_of "$rel")" in 100644|100755) ;; 120000) plan "$rel" symlink "a symlink in the topic — create it by hand if you want it"; continue ;; *) echo "STOP: CANNOT-CHECK — unexpected git mode for $rel"; exit 1 ;; esac
      git show "$TIP:$rel" > "$SCAN_DIR/theirs" || { echo "STOP: CANNOT-CHECK — git show $TIP:$rel failed"; exit 1; }
      if [ -L "$VAULT/$rel" ] || { [ -e "$VAULT/$rel" ] && [ ! -f "$VAULT/$rel" ]; }; then kind=conflict; note="the vault has a symlink or directory at this path — resolve by hand (nothing is written through a link)"
      elif [ ! -e "$VAULT/$rel" ]; then
        mkdir -p "$SCAN_DIR/merged/$(dirname "$rel")" && cp "$SCAN_DIR/theirs" "$SCAN_DIR/merged/$rel"; kind=new; note="not in the vault yet"; printf 'ABSENT\t%s\n' "$rel" >> "$SCAN_DIR/digests.tsv"
      elif cmp -s "$VAULT/$rel" "$SCAN_DIR/theirs"; then kind=identical; note="the vault already carries this content"
      else
        printf '%s\t%s\n' "$(shasum -a 256 < "$VAULT/$rel" | cut -d' ' -f1)" "$rel" >> "$SCAN_DIR/digests.tsv"   # what the merge was computed against
        if git cat-file -e "$FROM:$rel" 2>/dev/null; then git show "$FROM:$rel" > "$SCAN_DIR/base"; else : > "$SCAN_DIR/base"; fi
        rc=0; git merge-file -p -L "vault" -L "base $FROM" -L "topic/$TOPIC" "$VAULT/$rel" "$SCAN_DIR/base" "$SCAN_DIR/theirs" > "$SCAN_DIR/merge.out" || rc=$?
        if [ "$rc" -eq 0 ]; then mkdir -p "$SCAN_DIR/merged/$(dirname "$rel")" && cp "$SCAN_DIR/merge.out" "$SCAN_DIR/merged/$rel"; kind=merge
          if cmp -s "$SCAN_DIR/merge.out" "$VAULT/$rel"; then note="3-way merge clean; result equals the vault (a written no-op — skippable)"; printf '%s\n' "$rel" >> "$SCAN_DIR/noop.lst"; else note="3-way merge clean; your local edits kept"; fi
        elif [ "$rc" -lt 128 ]; then mkdir -p "$SCAN_DIR/conflicts/$(dirname "$rel")" && cp "$SCAN_DIR/merge.out" "$SCAN_DIR/conflicts/$rel"; kind=conflict; note="$rc conflicting hunk(s) — resolve by hand from $SCAN_DIR/conflicts/$rel; vault file untouched"
        else kind=cannot-merge; note="git merge-file could not merge this file (binary?) — decide by hand: keep yours, or copy theirs from $TIP"; fi
      fi
      # Direction: does the topic re-offer a revision OLDER than one another taken topic already offered for this path (a topic
      # rooted on an old snapshot of another)? A fact about the ledger (what a topic OFFERED at a taken sha), not about what the
      # vault accepted, so the note asks for a comparison, it does not prescribe a side.
      if { [ "$kind" = merge ] || [ "$kind" = conflict ] || [ "$kind" = new ]; } && [ -f "$MARK" ]; then
        inblob="$(git rev-parse -q --verify "$TIP:$rel")" || { echo "STOP: CANNOT-CHECK — cannot resolve $TIP:$rel"; exit 1; }; dir=""; dchecked=$((dchecked+1))
        while IFS=$'\t' read -r tb ts tt || [ -n "$tb$ts" ]; do
          [ -n "$ts" ] || continue; git cat-file -e "$ts^{commit}" 2>/dev/null || { dgone=$((dgone+1)); continue; }   # counted: a row this clone cannot resolve is a row NOT compared
          git merge-base --is-ancestor "$ts" "$TIP" && continue   # an ANCESTOR of the tip is this topic's own past: newer commits that restore old content are a revert, not a stale re-offer
          tblob="$(git rev-parse -q --verify "$ts:$rel" 2>/dev/null)" || tblob=""   # empty: the taken tree has no such path (deleted or never there)
          [ "$tblob" = "$inblob" ] && continue   # the same revision another topic offered: nothing to say about direction
          hit="$(git log --format=%H --find-object="$inblob" "$ts" -- "$rel")" || { echo "STOP: CANNOT-CHECK — git log --find-object for $rel at $ts failed"; exit 1; }   # one git call: did this exact blob ever sit at this path in the taken history?
          case "$hit" in ?*) if [ -n "$tblob" ]; then dir="OLDER than the revision $tb offered at $(git rev-parse --short "$ts") (taken.tsv) — compare with the vault's copy before resolving 'theirs'"; else dir="OLDER than $tb@$(git rev-parse --short "$ts"), which later DELETED this path — taking it resurrects it"; fi; break ;; esac
        done < "$MARK"
        [ -z "$dir" ] || { note="$note; incoming is $dir"; dflag=$((dflag+1)); }
      fi
      case "$(printf '%s' "$rel" | tr 'A-Z' 'a-z')" in claude.md|*/claude.md|claude.local.md|*/claude.local.md) [ "$kind" = identical ] || { kind=claude-md; note="never applied by the apply block ($note) — approve hunk by hunk, edit by hand"; } ;; esac   # case-folded: APFS is case-insensitive
      plan "$rel" "$kind" "$note" ;;
    *) echo "STOP: CANNOT-CHECK — unhandled git status '$st' for $rel"; exit 1 ;;
  esac
done 3< "$SCAN_DIR/incoming.tsv"
rm -f "$SCAN_DIR/theirs" "$SCAN_DIR/base" "$SCAN_DIR/merge.out"
LC_ALL=C awk -F'\t' '{n[$2]++} END {printf "plan: new %d, merge %d, identical %d, conflict %d, cannot-merge %d, delete %d, orphan %d, symlink %d, claude-md %d, ignored %d, out-of-scope %d\n", n["new"],n["merge"],n["identical"],n["conflict"],n["cannot-merge"],n["delete"],n["orphan"],n["symlink"],n["claude-md"],n["ignored"],n["out-of-scope"]}' "$SCAN_DIR/plan.tsv"
if [ -f "$MARK" ]; then echo "direction: $dchecked row(s) checked against $(LC_ALL=C awk 'NF' "$MARK" | wc -l | tr -d ' ') marker row(s), $dflag flagged OLDER, $dgone marker-row lookups skipped (sha not in this clone — those rows were NOT compared)"; else echo "direction: not checked — no taken.tsv yet"; fi
cat "$SCAN_DIR/plan.tsv"
printf '%s\n' "$FROM" > "$SCAN_DIR/from.txt" && printf '%s\n' "$TIP" > "$SCAN_DIR/tip.txt" || { echo "STOP: CANNOT-CHECK — could not record the plan's tip"; exit 1; }   # LAST act: tip.txt exists only for a plan that completed
```

Export the `TIP` it printed.

### 2. De-genericize the scratch copies

Edit `$SCAN_DIR/merged/<path>` (never the vault) for every `new`/`merge` row the user will be offered, reversing the template's genericization: `{{USER_NAME}}`/`{{USER_EMAIL}}`/`{{BOOTSTRAP_DATE}}` → the vault's values; `{{GOOGLE_ACCOUNTS_TABLE}}`, `{{SLACK_WORKSPACES_TABLE}}`, `{{ASANA_ROUTING_TABLE}}`, `{{FATHOM_TABLE}}` → **keep the vault's existing resolved tables** (never overwrite resolved tables with placeholders); `~/OpenBrain` → the vault's path; `mcp__google_<slug>__*`, `mcp__slack_<workspace_slug>__*`, `<slug>` → the vault's concrete names where they already exist. Port structure and procedure, not identity.

### 3. Present

Show the plan to the user and, for each row:

- **new / merge** — show the diff the vault will receive (`diff -u "$VAULT/<path>" "$SCAN_DIR/merged/<path>"`, with `/dev/null` as the left side for a new file), then one `AskUserQuestion` listing all clean items with the options take all / pick / **skip**. Approved paths go one per line to `$SCAN_DIR/approved.lst`; clean items the user declines go to `$SCAN_DIR/skipped.lst`. **Skip is offered only for `new` rows and for merges whose note says the result equals the vault** (a written no-op); a merge that changes the vault cannot be skipped — the mark block refuses. Such a merge is applied, or the user edits the vault by hand and **re-runs the plan** so the row re-classifies (identical, or a no-op merge). A skip is a disposition: the marker advances and the report names the count. **A skipped item is not offered again** (the marker moves past the commit that introduced it); only `.openbrain/local/skipped.tsv` remembers it — to take it later, restore it by hand from the topic. A permanent "never" belongs in `template-ignore`. **Ignore** (append the path to `.openbrain/template-ignore`, then re-run the plan) is the permanent decline, for any row kind and any topic. For an upstream row, apply the de-genericization above before showing the diff.
- **conflict** — the vault file is not changed. Show `$SCAN_DIR/conflicts/<path>` (it carries `<<<<<<< vault` / `>>>>>>> topic/upstream` markers); the user resolves by hand in the vault. When they have, add the path to `$SCAN_DIR/resolved.lst`. **If the row says the incoming side is OLDER than a revision another topic offered, show the vault's copy next to it before the user picks a side** — "theirs" is often a regression there; the comparison is the user's, not the ledger's.
- **claude-md** — never auto-applied, whatever the merge said, for any `CLAUDE.md` or `CLAUDE.local.md` at any depth. Present each hunk with its own `AskUserQuestion`; apply approved hunks with `Edit`. Add the path to `resolved.lst` **only if every hunk was applied** — a declined hunk keeps the item pending, so the marker stays and the hunk is offered again next time.
- **delete / orphan / symlink / cannot-merge** — hand items: ask; if approved, do it yourself (`git -C "$VAULT" rm`, `ln -s`, `git -C "$TEMPLATE" show "$TIP:<path>" > …`), then add the path to `resolved.lst`. Never delete without the answer.
- **identical** — nothing to do.

**CLAUDE.md rows are per-instance human-approved, hunk by hunk, never written by the apply block** — an unattended run halts and flags at the first CLAUDE.md decision. `bootstrap/` rows: flag "careful review — may need `bootstrap/setup.sh` re-run".

### 4. Apply the approved clean items

```bash
# --- pull-skill: apply ---
set -o pipefail; umask 022                                # vault files are 644/755, not scratch-private
: "${SCAN_DIR:?}"; : "${TOPIC:?}"; VAULT="${VAULT:?}"
[ -s "$SCAN_DIR/approved.lst" ] || { : > "$SCAN_DIR/applied.lst"; echo "STOP: nothing approved — write the approved paths, one per line, to $SCAN_DIR/approved.lst (or skip every clean item and go straight to the mark block)"; exit 1; }
touch "$SCAN_DIR/skipped.lst"; both="$(LC_ALL=C comm -12 <(LC_ALL=C awk 'NF' "$SCAN_DIR/approved.lst" | LC_ALL=C sort -u) <(LC_ALL=C awk 'NF' "$SCAN_DIR/skipped.lst" | LC_ALL=C sort -u))"
[ -z "$both" ] || { echo "STOP: approved AND skipped — decide one way: $both"; exit 1; }
: > "$SCAN_DIR/applied.lst"; changed=0; same=0
LC_ALL=C awk 'NF && !seen[$0]++' "$SCAN_DIR/approved.lst" > "$SCAN_DIR/approved.sorted"   # a path listed twice is written once and counted once; the user's order is kept
while IFS= read -r rel <&3; do
  [ -n "$rel" ] || continue
  case "$(printf '%s' "$rel" | tr 'A-Z' 'a-z')" in claude.md|*/claude.md|claude.local.md|*/claude.local.md) echo "STOP: $rel is never written by this block — approve its hunks one by one and edit it directly"; exit 1 ;; esac
  kind="$(LC_ALL=C awk -F'\t' -v r="$rel" '$1==r && ($2=="new"||$2=="merge") {print $2}' "$SCAN_DIR/plan.tsv")"
  [ -n "$kind" ] || { echo "STOP: '$rel' is not a clean new/merge item in the plan — conflicts, deletes, orphans and symlinks are handled by hand, not here"; exit 1; }
  [ -f "$SCAN_DIR/merged/$rel" ] || { echo "STOP: CANNOT-CHECK — merged copy for $rel is missing"; exit 1; }
  want="$(LC_ALL=C awk -F'\t' -v r="$rel" '$2==r {print $1}' "$SCAN_DIR/digests.tsv")"   # the vault file the plan merged against must be unchanged since
  if [ "$want" = ABSENT ]; then [ ! -e "$VAULT/$rel" ] && [ ! -L "$VAULT/$rel" ] || { echo "STOP: $rel appeared in the vault after the plan was made — re-run the plan"; exit 1; }
  else [ -f "$VAULT/$rel" ] && [ ! -L "$VAULT/$rel" ] && [ "$(shasum -a 256 < "$VAULT/$rel" | cut -d' ' -f1)" = "$want" ] || { echo "STOP: $rel changed in the vault since the plan was made — re-run the plan so the merge sees your edit"; exit 1; }; fi
  mode="$(LC_ALL=C awk -F'\t' -v r="$rel" '$2==r {split($1,a," "); print a[1]}' "$SCAN_DIR/modes.tsv")"
  case "$mode" in 100755) perm=755 ;; 100644) perm=644 ;; *) echo "STOP: CANNOT-CHECK — no git mode recorded for $rel"; exit 1 ;; esac
  if [ -f "$VAULT/$rel" ] && cmp -s "$SCAN_DIR/merged/$rel" "$VAULT/$rel"; then st="already identical"; same=$((same+1))   # a 3-way merge whose result equals the vault: nothing is written (no mtime bump, no mode change)
  else st=changed; changed=$((changed+1)); mkdir -p "$VAULT/$(dirname "$rel")" && cp "$SCAN_DIR/merged/$rel" "$VAULT/$rel" && chmod "$perm" "$VAULT/$rel" || { echo "STOP: write failed for $rel — $(wc -l < "$SCAN_DIR/applied.lst" | tr -d ' ') file(s) were applied before it (see applied.lst)"; exit 1; }; fi
  printf '%s\n' "$rel" >> "$SCAN_DIR/applied.lst"; echo "applied ($kind, $perm, $st): $rel"
done 3< "$SCAN_DIR/approved.sorted"
echo "applied $(LC_ALL=C sort -u "$SCAN_DIR/applied.lst" | wc -l | tr -d ' ') file(s): $changed changed, $same already identical"
```

The applied files already carry the vault's identity (§2 already de-genericized the scratch copies; a skill layered on these blocks that does not run §2 re-personalizes after apply itself). If anything under `.openbrain/` or `bootstrap/` was applied, run the runtime check in step 5b below.

### 4b. Post-apply verification — does the vault the apply just wrote still run?

Runs **immediately after apply, before the marker advances in step 5** — not after it: it writes into `$SCAN_DIR` and reads `applied.lst`, and `mark` deletes `$SCAN_DIR` as its last act.

A take can land a skill or hook that calls a lib the topic didn't carry (a partial share, or a genericization the receiving side never de-genericized); this block catches that right after the write. **A verify failure is reported, not fatal, and its result never gates step 5's marker advance** — mark reads nothing this block writes, and this block never inspects mark's outcome; the take happened, and this run's report says that what it took is broken.

```bash
# --- pull-skill: verify ---
set -o pipefail
: "${SCAN_DIR:?export SCAN_DIR=<the path step 0 printed>}"; VAULT="${VAULT:?}"
[ -d "$SCAN_DIR" ] || { echo "STOP: CANNOT-CHECK — scratch dir '$SCAN_DIR' missing (verify runs before mark; mark removes it)"; exit 1; }
[ -d "$VAULT" ] || { echo "STOP: CANNOT-CHECK — VAULT '$VAULT' is not a directory; cannot run post-apply verification"; exit 1; }   # a cd failure here is an environment problem, never a test FAIL
nrun=0; nfail=0; nabsent=0; nnorunner=0; nnointerp=0; nmissing=0; nuncovered=0
verify_line() { printf 'verify: %s %s\n' "$1" "$2"; }
vrun() {   # vrun <label> <interpreter> <rel-path> — runs from $VAULT, </dev/null so a test can never eat this loop's remaining input, records PASS/FAIL. Never name a local `path`: it clobbers $PATH under zsh. `--` before the path: a path starting with `+` or `-` (e.g. under `+ Extras/Templates/`) is otherwise misread as an interpreter option
  local label="$1" interp="$2" relp="$3" rc=0
  ( cd "$VAULT" && "$interp" -- "$relp" ) > "$SCAN_DIR/verify-$(printf '%s' "$label" | tr '/' '_').out" 2>&1 </dev/null || rc=$?
  nrun=$((nrun+1))
  if [ "$rc" -eq 0 ]; then verify_line "$label" PASS; else nfail=$((nfail+1)); verify_line "$label" "FAIL(rc $rc)"; fi
}
V="$VAULT/bootstrap/lib/validate.sh"
if [ -f "$V" ]; then vrun validate.sh bash "$V"
else nabsent=$((nabsent+1)); verify_line validate.sh absent; echo "verify: validate.sh absent — not run"; fi
S="$VAULT/bootstrap/lib/smoke-test.sh"
if [ -f "$S" ]; then vrun smoke-test.sh bash "$S"
else nabsent=$((nabsent+1)); verify_line smoke-test.sh absent; echo "verify: smoke-test.sh absent — not run"; fi
if [ ! -e "$SCAN_DIR/applied.lst" ]; then
  nabsent=$((nabsent+1)); echo "verify: no applied.lst in $SCAN_DIR — apply did not run or wrote nothing; topic tests not checked"
elif [ ! -s "$SCAN_DIR/applied.lst" ]; then
  echo "verify: 0 applied paths"   # present, genuinely empty — a real "nothing to check," stays eligible for CLEAN, unlike an ABSENT file (which means apply never ran at all)
else
  while IFS= read -r rel <&3; do   # fd 3, not stdin: a spawned test that itself reads stdin must never eat this loop's remaining rows
    [ -n "$rel" ] || continue
    case "$rel" in bootstrap/lib/validate.sh|bootstrap/lib/smoke-test.sh) continue ;; esac   # already run above; do not double-count
    if [ ! -e "$VAULT/$rel" ]; then nmissing=$((nmissing+1)); verify_line "$rel" "missing from the vault after apply"; continue; fi
    case "$(printf '%s' "$rel" | tr 'A-Z' 'a-z')" in
      *-test.sh)
        if command -v bash >/dev/null 2>&1; then vrun "$rel" bash "$rel"
        else nnointerp=$((nnointerp+1)); verify_line "$rel" "not run — no bash on PATH"; fi ;;
      *-test.py)
        if command -v python3 >/dev/null 2>&1; then vrun "$rel" python3 "$rel"
        else nnointerp=$((nnointerp+1)); verify_line "$rel" "not run — no python3 on PATH"; fi ;;
      *-test.*) nnorunner=$((nnorunner+1)); verify_line "$rel" "not run — no runner for that extension" ;;
      *) nuncovered=$((nuncovered+1)) ;;   # not a *-test.* path — outside this block's contract; counted honestly, never silently dropped
    esac
  done 3< "$SCAN_DIR/applied.lst"
fi
if   [ "$nfail" -gt 0 ]; then outcome=FINDINGS
elif [ "$nrun" -eq 0 ] || [ "$nabsent" -gt 0 ] || [ "$nnorunner" -gt 0 ] || [ "$nnointerp" -gt 0 ] || [ "$nmissing" -gt 0 ]; then outcome=CANNOT-CHECK
else outcome=CLEAN
fi
echo "verify: $outcome — $nrun run, $nfail failed, $nabsent absent, $nnorunner no-runner, $nnointerp no-interpreter, $nmissing missing-after-apply, $nuncovered applied path(s) not covered by any runner"
exit 0   # reported, never fatal — this block's own outcome, however bad, never stops the run; step 5 (mark) does not read anything this block writes
```

Any skill layered on these blocks runs this one by reference, exactly like apply and mark.

### 5. Advance the marker — only when nothing is left hanging

```bash
# --- pull-skill: mark ---
: "${SCAN_DIR:?}"; : "${TOPIC:?}"; : "${TIP:?export TIP=<the sha the plan printed>}"; VAULT="${VAULT:?}"; ROW="topic/$TOPIC"; [ "$TOPIC" != upstream ] || ROW=upstream
[ -d "$SCAN_DIR" ] && [ -s "$SCAN_DIR/plan.tsv" ] || { echo "STOP: CANNOT-CHECK — no plan in $SCAN_DIR (already marked and cleaned up, or the plan never ran); nothing to certify, no row written"; exit 1; }
[ "$(cat "$SCAN_DIR/tip.txt" 2>/dev/null)" = "$TIP" ] || { echo "STOP: CANNOT-CHECK — exported TIP is not the sha this plan was made for ($(cat "$SCAN_DIR/tip.txt" 2>/dev/null)); the marker records only what was planned"; exit 1; }
touch "$SCAN_DIR/applied.lst" "$SCAN_DIR/resolved.lst" "$SCAN_DIR/skipped.lst"
pending="$(LC_ALL=C awk -F'\t' 'FILENAME==ARGV[1] {r[$0]=1; next} ($2=="conflict"||$2=="cannot-merge"||$2=="claude-md"||$2=="delete"||$2=="orphan"||$2=="symlink") && !($1 in r) {n++} END {print n+0}' "$SCAN_DIR/resolved.lst" "$SCAN_DIR/plan.tsv")"   # FILENAME, not FNR==NR: an empty first file would swallow the second
LC_ALL=C awk -F'\t' '$2=="new"||$2=="merge" {print $1}' "$SCAN_DIR/plan.tsv" | LC_ALL=C sort -u > "$SCAN_DIR/planned.sorted"; planned="$(wc -l < "$SCAN_DIR/planned.sorted" | tr -d ' ')"
LC_ALL=C awk 'NF' "$SCAN_DIR/applied.lst" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$SCAN_DIR/planned.sorted" > "$SCAN_DIR/applied.sorted"   # what the apply block WROTE, restricted to THIS plan (a stale list from an earlier plan pays for nothing)
LC_ALL=C awk 'NF' "$SCAN_DIR/skipped.lst" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$SCAN_DIR/planned.sorted" > "$SCAN_DIR/skipped.sorted"   # only planned clean items count as skipped
applied="$(wc -l < "$SCAN_DIR/applied.sorted" | tr -d ' ')"; skipped="$(wc -l < "$SCAN_DIR/skipped.sorted" | tr -d ' ')"
both="$(LC_ALL=C comm -12 "$SCAN_DIR/applied.sorted" "$SCAN_DIR/skipped.sorted")"; [ -z "$both" ] || { echo "marker NOT advanced: applied AND skipped — $both"; exit 1; }
touch "$SCAN_DIR/noop.lst"   # skip is allowed for NEW rows and for merges whose result equals the vault; a merge that CHANGES the vault must be applied or resolved
badskip="$(LC_ALL=C awk -F'\t' 'FILENAME==ARGV[1] {k[$1]=$2; next} FILENAME==ARGV[2] {noop[$1]=1; next} k[$0]=="merge" && !($0 in noop) {print}' "$SCAN_DIR/plan.tsv" "$SCAN_DIR/noop.lst" "$SCAN_DIR/skipped.sorted")" || { echo "marker NOT advanced: CANNOT-CHECK — could not read plan.tsv/noop.lst/skipped.lst"; exit 1; }
[ -z "$badskip" ] || { echo "marker NOT advanced: skip REFUSED — these merges change the vault; apply them, or edit the vault by hand and re-run the plan so they re-classify (a skipped changing merge would make every later merge of the path use a base the vault never had): $badskip"; exit 1; }
while IFS= read -r sk; do   # a no-op skip is only a no-op against the vault file the plan saw: re-verify the digest, as the apply block does
  LC_ALL=C command grep -qx -- "$sk" "$SCAN_DIR/noop.lst" || continue
  want="$(LC_ALL=C awk -F'\t' -v r="$sk" '$2==r {print $1}' "$SCAN_DIR/digests.tsv")"
  [ -f "$VAULT/$sk" ] && [ "$(shasum -a 256 < "$VAULT/$sk" | cut -d' ' -f1)" = "$want" ] || { echo "marker NOT advanced: $sk changed in the vault since the plan called it a no-op — re-run the plan"; exit 1; }
done < "$SCAN_DIR/skipped.sorted"
undisposed="$(LC_ALL=C sort -u "$SCAN_DIR/applied.sorted" "$SCAN_DIR/skipped.sorted" | LC_ALL=C comm -13 - "$SCAN_DIR/planned.sorted")"   # SET difference: every planned clean path must be in one of the two lists
unresolved=0
while IFS= read -r rel <&3; do   # a "resolved" conflict must actually be resolved: no markers left in the vault file
  [ -n "$rel" ] && LC_ALL=C awk -F'\t' -v r="$rel" '$1==r && $2=="conflict" {f=1} END {exit !f}' "$SCAN_DIR/plan.tsv" && [ -f "$VAULT/$rel" ] && LC_ALL=C command grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$VAULT/$rel" && { echo "still has conflict markers: $rel"; unresolved=$((unresolved+1)); }
done 3< "$SCAN_DIR/resolved.lst"
if [ "$pending" -gt 0 ] || [ "$unresolved" -gt 0 ] || [ -n "$undisposed" ]; then
  echo "marker NOT advanced: $pending hand item(s) undecided, $unresolved marked resolved but still carrying markers, $applied written + $skipped skipped of $planned clean items — finish them and re-run this block (keep $SCAN_DIR), or rm -rf it to abandon; the same delta is offered next time"; [ -z "$undisposed" ] || printf 'neither written nor skipped: %s\n' $undisposed
  stray="$(LC_ALL=C awk 'NF' "$SCAN_DIR/skipped.lst" | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$SCAN_DIR/planned.sorted")"; [ -z "$stray" ] || printf 'skipped.lst line matching no clean plan row (typo, trailing space, or a hand item): %s\n' "$stray"; exit 1
fi
if [ "$skipped" -gt 0 ]; then echo "$skipped clean item(s) skipped by the operator"; FROM0="$(cat "$SCAN_DIR/from.txt" 2>/dev/null || echo unknown)"; mkdir -p "$VAULT/.openbrain/local"
  while IFS= read -r sk; do printf '%s\t%s\t%s\t%s\n' "$ROW" "$TIP" "$FROM0" "$sk" >> "$VAULT/.openbrain/local/skipped.tsv"; done < "$SCAN_DIR/skipped.sorted"; fi   # audit ledger only: topic, tip, base, path
mkdir -p "$VAULT/.openbrain/local" && printf '%s\t%s\t%s\n' "$ROW" "$TIP" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VAULT/.openbrain/local/taken.tsv" \
  && echo "marker: $ROW taken through $TIP" && rm -rf "$SCAN_DIR"
```

The marker row `upstream <sha>` is appended only when every planned clean item of *this* plan was written by the apply block or skipped by the user, and every hand item was resolved. Declining a **hand** item leaves the marker where it is; the same delta is offered next time. Skip is refused for a merge that changes the vault (see step 3). A skipped `new` file is behind the marker and is not offered again unless the topic changes it; the ledger row is the record. Every skip is appended to `.openbrain/local/skipped.tsv` (topic, tip, base, path) so it can be audited after the scratch dir is gone.

### 5b. Deploy to runtime (pulled == live)

MCP launchers and Claude-hook wiring have their runtime elsewhere (`~/.config/openbrain/lib/`, `.claude/settings.json`). If anything under `.openbrain/` or `bootstrap/` was applied:

```bash
R="${VAULT:?export VAULT=<the vault root>}/.openbrain/lib/reconcile-runtime.sh"; [ -f "$R" ] || { echo "runtime: CANNOT-CHECK — reconcile-runtime.sh missing"; exit 1; }
rc=0; bash "$R" --check || rc=$?; case "$rc" in 0) echo "runtime: in sync" ;; 10) echo "runtime: DRIFT — ask: Deploy now (bash $R --apply; relay RESTART REQUIRED verbatim) / Defer (say so in the report)" ;; *) echo "runtime: CANNOT-CHECK — reconcile-runtime exit $rc" ;; esac
```

### 6. Report

Taken: `upstream` from `<FROM>` (and why that start point) to `<TIP>`; the plan counts, template-ignore and direction lines; applied files with modes, changed vs already identical; skipped; **verify lines and the outcome-led coverage line (CANNOT-CHECK/FINDINGS/CLEAN — N run, M failed, ...)** — from step 4b, which ran before the marker line below and never gated it; conflicts and CLAUDE.md hunks left for the user; marker advanced or why not; runtime line. In `--dry-run`, stop after step 1 (its plan, or its nothing-new line), then `rm -rf "$SCAN_DIR"`.

## Notes

- Read-only on the template side, write-only on the vault side; never reads `~/.config/openbrain/.env`; never commits (the Stop hook does).
- First pull on a machine: `bootstrap/setup.sh` records the `upstream` baseline row when it sets a vault up — `git merge-base HEAD <template>/main`, the last template commit the vault carries, from this skill's own source (the template clone, its `upstream` remote, else `origin`, fetched first; no clone or no shared history: no row) — so a fresh vault's first pull plans from there. Without that row (a vault set up before setup.sh did this, or a machine whose `.openbrain/local/` is new) the plan STOPs until one is declared (TAB-separated; a short sha is accepted and normalised): the last upstream commit the vault is known to carry.
- After one of your topics is squash-merged upstream, expect conflict rows on exactly the files you pushed (generic vs your de-genericized copy); resolve ours, or move the `upstream` row to the squash sha by hand when that content is verifiably yours.
- Vault-ahead content is not this skill's to find: `/push-openbrain-template` enumerates it. A file both sides changed plans as a 3-way merge, conflicts included.
- Never writes into a hard-denied path (a topic carrying one stops the whole run; for `TOPIC=upstream`, hard-denied paths the template ships, like `+ ` scaffolding and `.gitkeep`s, are simply **out of scope**: listed with a count line and planned as no-byte `out-of-scope` rows, never taken — a pull never writes into content folders); never deletes without an explicit hand-item approval; never overwrites a conflicting local edit. The vault's own `git` history is the undo.
- `.openbrain/template-ignore` is where a permanent decline lives: matching paths are never taken (count + list printed every run, one no-byte `ignored` plan row each; a stale exact entry is named). **Un-ignoring later** gives that path a first merge whose base the vault never took — expect a conflict and resolve it by hand.
- Taking a topic that replaces `.openbrain/lib/template-scope.sh` itself — the file the plan block sources `deny()`/`in_roots()` from — works because the plan block sources it once, before any file is written; later blocks do not re-source it. A self-modifying run (this file included, since it is itself a candidate `/push-openbrain-template` can port) is expected, not an error.
- The marker file (`.openbrain/local/taken.tsv`) is per machine and gitignored. **Rows accumulate — one per take, never tidied to one row per branch.** Readers use the last row per label for the start point; the direction check reads the whole history (every sha a topic was ever taken at), so deleting older rows blinds it.
- Callers extract the marked block range (`# --- pull-skill: <name> ---` through the closing fence) and never read this file whole. This applies to the five CODE blocks (`preflight`/`plan`/`apply`/`verify`/`mark`) only — a step this skill's callers reach by section reference instead (e.g. pull §2 "De-genericize the scratch copies" / §3 "Present") is read by the executor at that heading (they are `###` steps; `--section` serves `##` sections such as a `## Findings` ledger), never by extracting the whole file. Extraction runs through the shared helper — depends on `.openbrain/lib/extract-block.sh` (ships alongside `/push-openbrain-template`): `bash "$VAULT/.openbrain/lib/extract-block.sh" "$VAULT/.claude/skills/pull-openbrain-template/SKILL.md" 'pull-skill: plan'` (swap the marker name for the other four blocks; both paths always absolute — this skill's own preflight cds into the template clone, so a relative form would read the wrong copy, or nothing). Same stable command string for every call site. Three outcomes: `0` body on stdout, `2` CANNOT-CHECK (message says which of file unreadable / missing marker / duplicate marker / missing fence (marker mode only — a section's end is EOF-valid) / empty body / bad usage), `127` the helper is not at that absolute path — restore it from git, or re-pull the template.
