#!/usr/bin/env bash
# Fixture tests for .openbrain/lib/taken-status.sh, in two halves.
#   1. SYNTHETIC (every machine, same result): a DECLARED fixture this file builds — its own upstream and staging bare
#      repos (file:// remotes), its own template clone and its own taken.tsv. Every case runs here, --all included.
#   2. REAL DATA (a declared check on THIS machine): the per-branch cases again, on a COPY of this machine's template clone
#      (OPENBRAIN_TEMPLATE_DIR, else the skills' default) and of the main checkout's .openbrain/local/taken.tsv. No fetch
#      of any kind — only what the clone already holds; the live files are never written. A missing input (no clone, or
#      no taken.tsv: a fresh checkout) is a declared SKIP, printed with its reason and counted apart from PASS; so is a
#      clone with no staging remote or zero staging topics (the topic cases skip, the upstream cases run). Half 1 always
#      runs, so a run is never green on skips alone.
# Both directions: it must report genuinely new work as `new`, and every way it cannot tell as `cannot-check`, never
# `nothing-new`.
#
#   bash .openbrain/tests/taken-status.sh     # exit 0 = all pass
set -u
VAULT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$VAULT/.openbrain/lib/taken-status.sh"
[ -f "$LIB" ] || { echo "CANNOT-CHECK: $LIB missing"; exit 20; }
# real-data inputs, captured before the synthetic half re-points OPENBRAIN_TEMPLATE_DIR. taken.tsv is per-machine state of
# the MAIN checkout (a linked worktree has none): resolve it from the first `git worktree list` record.
REAL_CLONE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
WT_LIST="$(git -C "$VAULT" worktree list --porcelain)"; WT_RC=$?   # rc kept: a failed listing is CANNOT-CHECK, not "nothing taken"
REAL_MAIN="$(printf '%s\n' "$WT_LIST" | awk '/^worktree /{print substr($0, 10); exit}')"
REAL_TSV_SRC="${REAL_MAIN:-<unresolved>}/.openbrain/local/taken.tsv"

W="$(mktemp -d "${TMPDIR:-/tmp}/taken-status-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
# fake identity for the throwaway fixture commits (the machine's git identity is never needed or read)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# --- the fixture: upstream main u1..u5; staging main = u5 with topic/alpha (2 commits, taken at its tip) and topic/beta
# (1 commit, never taken); a clone with remotes upstream + staging; taken.tsv = an old upstream row (u1) + alpha's row
F="$W/src"; f() { git -C "$F" "$@"; }
fixture() {
  git init -q -b main "$F" || return 1
  for i in 1 2 3 4 5; do printf 'u%s\n' "$i" > "$F/u.txt"; f add u.txt && f commit -qm "u$i" || return 1; done
  git init -q --bare "$W/fx-upstream.git" && f push -q "$W/fx-upstream.git" main:refs/heads/main || return 1
  git init -q --bare "$W/fx-staging.git" && f push -q "$W/fx-staging.git" main:refs/heads/main || return 1
  f checkout -q -b topic/alpha main && printf 'a1\n' > "$F/a.txt" && f add a.txt && f commit -qm a1 && printf 'a2\n' >> "$F/a.txt" && f commit -qam a2 || return 1
  f checkout -q -b topic/beta main && printf 'b1\n' > "$F/b.txt" && f add b.txt && f commit -qm b1 || return 1
  f push -q "$W/fx-staging.git" topic/alpha:refs/heads/topic/alpha topic/beta:refs/heads/topic/beta || return 1
  git init -q "$W/clone" && git -C "$W/clone" remote add upstream "file://$W/fx-upstream.git" && git -C "$W/clone" remote add staging "file://$W/fx-staging.git" || return 1
  git -C "$W/clone" fetch -q upstream && git -C "$W/clone" fetch -q staging || return 1
  { printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$(f rev-parse main~4)"; printf 'topic/alpha\t%s\t2026-01-02T00:00:00Z\n' "$(f rev-parse topic/alpha)"; } > "$W/base.tsv"
}
fixture || { echo "CANNOT-CHECK: could not build the fixture repos"; exit 20; }
CLONE="$W/clone"; BASE_TSV="$W/base.tsv"   # the clone and declared ledger the cases run on (each case copies the ledger, then appends)
export OPENBRAIN_TEMPLATE_DIR="$CLONE" VAULT TAKEN_TSV="$W/taken.tsv"
g() { git -C "$CLONE" "$@"; }
pass=0; fail=0; skip=0
check() {  # check <name> <expected-status> <expected-rc> <branch|--all>
  local name="$1" want="$2" wantrc="$3" arg="$4" out rc
  out="$(bash "$LIB" "$arg" 2>&1)"; rc=$?
  if [ "$rc" -eq "$wantrc" ] && printf '%s\n' "$out" | LC_ALL=C grep -q -- "$want"; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc, want $wantrc / '$want')"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
check_not() {  # check_not <name> <forbidden-pattern> <branch|--all> — the output must NOT match
  local name="$1" nope="$2" arg="$3" out
  out="$(bash "$LIB" "$arg" 2>&1)"
  if ! printf '%s\n' "$out" | LC_ALL=C grep -q -- "$nope"; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (matched '$nope')"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
tsv() { cp "$BASE_TSV" "$W/taken.tsv"; export TAKEN_TSV="$W/taken.tsv"; }
# a commit that really changes content (one new file) — the pull plan works by changed paths
content_commit() { local blob tree; blob="$(printf 'fixture\n' | g hash-object -w --stdin)"; tree="$( { g ls-tree "$1^{tree}"; printf '100644 blob %s\tzz-fixture.txt\n' "$blob"; } | g mktree)"; g commit-tree -p "$1" -m fixture "$tree"; }

# branch_cases <label> <fail|skip> — every per-branch case (no fetch) against $CLONE + $BASE_TSV; sets UPR UTIP TOPIC
# TOPIC_SHA. The second argument says what a clone with no staging remote, or zero staging topics, means: `fail` for the
# fixture (it always builds topics), `skip` for real data (an upstream user's clone has no staging): the topic cases are
# then a declared SKIP and the upstream cases still run. Topics present but none with a taken row in the clone is a FAIL.
# Each case sets its own starting state on the clone it runs on (always a copy): the chosen topic's tracking ref is put at
# the sha its LAST taken.tsv row records, and "new" is built on top of that — so the expectation never depends on where a
# live tip happens to be (a fetched-but-not-yet-taken share leaves the real tip past its row).
last_row() { awk -F'\t' -v k="$1" '$1==k {s=$2} END {print s}' "$BASE_TSV"; }
branch_cases() {
  UPR=upstream; g remote | grep -qx upstream || UPR=origin
  UTIP="$(g rev-parse "$UPR/main")"
  TOPIC=; TOPIC_SHA=; nostage=
  if ! g remote | grep -qx staging; then nostage="the clone has no staging remote"
  elif [ -z "$(g for-each-ref --format=x 'refs/remotes/staging/topic/*')" ]; then nostage="the clone tracks zero staging topics"; fi
  if [ -n "$nostage" ]; then
    [ "$2" = skip ] || { fail=$((fail+1)); echo "FAIL $1: $nostage — the topic cases cannot run"; return 1; }
    skip=$((skip+1)); echo "SKIP $1: $nostage — the topic cases did not run (the upstream cases still do)"
    echo "$1: $UPR/main=$(g rev-parse --short "$UTIP"), no taken topic"
  else
  TOPIC="$(g for-each-ref --format='%(refname:short)' 'refs/remotes/staging/topic/*' | while read -r r; do b="${r#staging/}"; s="$(last_row "$b")"; [ -n "$s" ] && g rev-parse -q --verify "$s^{commit}" >/dev/null && { echo "$b"; break; }; done)"
  [ -n "$TOPIC" ] || { fail=$((fail+1)); echo "FAIL $1: no staging topic whose last taken.tsv row is in the clone — the topic cases cannot run"; return 1; }
  TOPIC_SHA="$(g rev-parse "$(last_row "$TOPIC")^{commit}")"
  g update-ref "refs/remotes/staging/$TOPIC" "$TOPIC_SHA" || { fail=$((fail+1)); echo "FAIL $1: could not set staging/$TOPIC to its taken row"; return 1; }
  echo "$1: $UPR/main=$(g rev-parse --short "$UTIP"), taken topic=$TOPIC (set to its taken row $(g rev-parse --short "$TOPIC_SHA"))"
  fi

  # --- clean direction
  tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$UTIP" >> "$TAKEN_TSV"
  check "$1: upstream at its taken tip → nothing-new" 'nothing-new' 0 upstream

  # --- new direction ----------------------------------------------------------
  # three linear content commits built on the tip (never assume the real tip~3.. is 3 commits: merges, empty commits)
  u3="$UTIP"; for _ in 1 2 3; do u3="$(content_commit "$u3")" || break; done
  g update-ref "refs/remotes/$UPR/main" "$u3"
  tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$UTIP" >> "$TAKEN_TSV"
  check "$1: upstream taken 3 back → new 3" 'new	3 commit' 10 upstream
  g update-ref "refs/remotes/$UPR/main" "$UTIP"   # restore
  if [ -n "$TOPIC" ]; then
  tsv; g update-ref "refs/remotes/staging/$TOPIC" "$(content_commit "$TOPIC_SHA")"
  check "$1: content commit on top of a taken topic → new 1" 'new	1 commit' 10 "$TOPIC"
  g update-ref "refs/remotes/staging/$TOPIC" "$(g commit-tree -p "$TOPIC_SHA" -m empty "$TOPIC_SHA^{tree}")"
  check "$1: empty commit on a taken topic → cannot-check (the pull plan STOPs), not new" 'cannot-check.*no changed paths' 20 "$TOPIC"
  g update-ref "refs/remotes/staging/$TOPIC" "$TOPIC_SHA"   # restore
  tsv; g update-ref refs/remotes/staging/topic/zz-fixture "$(content_commit "$(g rev-parse staging/main)")"
  check "$1: untaken topic off staging/main → new (never taken)" 'never taken here' 10 topic/zz-fixture
  tsv; g update-ref refs/remotes/staging/topic/zz-fixture "$(g rev-parse "staging/$TOPIC")"
  check "$1: untaken topic == another topic's taken tip → nothing-new (stacked)" 'nothing-new.*stacked' 0 topic/zz-fixture
  g update-ref -d refs/remotes/staging/topic/zz-fixture
  fi

  # --- cannot-check direction: break the input, the checker must scream -------
  tsv; rm -f "$TAKEN_TSV"
  check "$1: taken.tsv missing → cannot-check" 'cannot-check' 20 upstream
  tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' 0123456789abcdef0123456789abcdef01234567 >> "$TAKEN_TSV"
  check "$1: last taken sha not in clone → cannot-check" 'not in the clone' 20 upstream
  tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$(g commit-tree -m orphan "$UPR/main^{tree}")" >> "$TAKEN_TSV"
  check "$1: last taken not an ancestor (rewrite) → cannot-check" 'rewritten' 20 upstream
  tsv; grep -v '^upstream	' "$BASE_TSV" > "$TAKEN_TSV"
  check "$1: no upstream row → cannot-check, not new" 'cannot-check.*baseline' 20 upstream
  tsv
  check "$1: branch absent from clone → cannot-check" 'cannot-check' 20 topic/does-not-exist
}

# ================= 1. SYNTHETIC =================
branch_cases fixture fail || { echo "taken-status: $pass passed, $fail failed"; exit 1; }
g remote set-url staging "file://$W/nonexistent"
check "--all with unreachable staging → cannot-check, rc 20" 'cannot-check: fetching staging failed' 20 --all
g remote set-url staging "file://$W/fx-staging.git"

# --- --all end to end, offline: staging pointed at a local bare mirror -------
REAL_STAGING_URL="file://$W/fx-staging.git"
# --no-verify: harmless here (the fixture clone has no hooks); kept so a hook can never slow a throwaway mirror push
mkbare() { rm -rf "$W/staging.git"; git init -q --bare "$W/staging.git" || return 1
  if [ "$1" = topics ]; then g push -q --no-verify "$W/staging.git" 'refs/remotes/staging/*:refs/heads/*' </dev/null
  else g push -q --no-verify "$W/staging.git" 'refs/remotes/staging/main:refs/heads/main' </dev/null; fi; }
tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$UTIP" >> "$TAKEN_TSV"
mkbare topics || { echo "CANNOT-CHECK: could not build the bare staging mirror"; exit 20; }
g remote set-url staging "file://$W/staging.git"
g push -q --no-verify "$W/staging.git" "$(content_commit "$TOPIC_SHA"):refs/heads/$TOPIC" </dev/null || { echo "CANNOT-CHECK: could not advance $TOPIC in the mirror"; exit 20; }
NT="$(git -C "$W/staging.git" for-each-ref 'refs/heads/topic/' | wc -l | tr -d ' ')"
LIVE_NT="$(g for-each-ref 'refs/remotes/staging/topic/' | wc -l | tr -d ' ')"
[ "$NT" -eq "$LIVE_NT" ] || { echo "CANNOT-CHECK: mirror has $NT topics, the clone tracks $LIVE_NT"; exit 20; }
check "--all: advanced topic shows new, rc 10" "$TOPIC	new	1 commit" 10 --all
check "--all: coverage counts every live topic ($NT)" "upstream/main + $NT live staging topic" 10 --all
# a tracked topic ref the fetch did not refresh (a narrowed fetch refspec leaves it stale) is never trusted: the verdict is
# cannot-check naming the mismatch — comparing the stale ref would report the topic's older state as current
g config remote.staging.fetch '+refs/heads/main:refs/remotes/staging/main'
g push -q --no-verify "$W/staging.git" "$(content_commit "$(git -C "$W/staging.git" rev-parse "refs/heads/$TOPIC")"):refs/heads/$TOPIC" </dev/null || { echo "CANNOT-CHECK: could not advance $TOPIC in the mirror again"; exit 20; }
check "--all: local staging ref stale after fetch (!= live) → cannot-check naming it, rc 20" "$TOPIC	cannot-check	local staging/$TOPIC (.*) != live" 20 --all
g config remote.staging.fetch '+refs/heads/*:refs/remotes/staging/*'
# coverage self-check: a listed topic that produced no verdict (here a git shim adds a nameless ls-remote line, which the
# loop skips) makes the run cannot-check, never a clean count of the topics it did check
REAL_GIT="$(command -v git)"; mkdir -p "$W/shim"
printf '#!/bin/sh\n"%s" "$@"; rc=$?\nfor a in "$@"; do [ "$a" = ls-remote ] && printf "%%s\\n" 0123456789abcdef0123456789abcdef01234567; done\nexit $rc\n' "$REAL_GIT" > "$W/shim/git"; chmod +x "$W/shim/git"
OLDPATH="$PATH"; export PATH="$W/shim:$PATH"
check "--all: a listed topic the loop never checked → cannot-check (listed vs checked), rc 20" 'cannot-check: staging listed [0-9]* topic(s) but [0-9]* were checked' 20 --all
export PATH="$OLDPATH"
mkbare main-only; g remote set-url staging "file://$W/staging.git"
tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$(g rev-parse "$UTIP~3")" >> "$TAKEN_TSV"
check "--all: zero staging topics still reports upstream new" 'upstream	new	3 commit' 10 --all
# remote present (and reachable): staging is checked, never reported as unconfigured
check_not "--all with a staging remote → never 'staging: not configured'" 'staging: not configured' --all
g remote set-url staging "$REAL_STAGING_URL"

# --- no staging remote at all (a template user): upstream checked normally, staging reported as not configured
# (a missing remote is a declared state, not a failure; a remote that is present but broken stays cannot-check, above)
g remote remove staging || { echo "CANNOT-CHECK: could not remove staging from the clone copy"; exit 20; }
tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$UTIP" >> "$TAKEN_TSV"
check "--all, no staging remote → 'staging: not configured'" '^staging: not configured' 0 --all
check "--all, no staging remote → upstream still checked (nothing-new, rc 0)" 'upstream	nothing-new' 0 --all
check "--all, no staging remote → coverage counts upstream only" 'coverage: 1 branch(es) checked (upstream/main; staging not configured)' 0 --all
check_not "--all, no staging remote → no cannot-check verdict (the coverage line's '0 cannot-check' is a count)" '	cannot-check\|^cannot-check' --all
tsv; printf 'upstream\t%s\t2026-01-01T00:00:00Z\n' "$(g rev-parse "$UTIP~3")" >> "$TAKEN_TSV"
check "--all, no staging remote → upstream new still reported, rc 10" 'upstream	new	3 commit' 10 --all
tsv; grep -v '^upstream	' "$BASE_TSV" > "$TAKEN_TSV"
check "--all, no staging remote, no upstream row → still cannot-check (upstream is checked, not skipped)" 'upstream	cannot-check.*baseline' 20 --all
g remote add staging "$REAL_STAGING_URL"

# ================= 2. REAL DATA — a declared check on THIS machine =================
# The per-branch cases on a copy of this machine's clone and taken.tsv, as they stand: no fetch of any kind (branch mode
# never fetches; --all is synthetic-only above). A missing input is a declared SKIP (counted, with its reason). FAIL
# (CANNOT-CHECK): the main checkout cannot be resolved; the clone is not a standalone repo (a linked worktree or a dir
# inside another repo: its copy would share the live ref store, and the cases write refs); a copy fails.
echo "real data: clone $REAL_CLONE ($(git -C "$REAL_CLONE" for-each-ref --format=x refs/remotes/upstream/main refs/remotes/origin/main refs/remotes/staging/ 2>&1 | grep -c '^x$') upstream/origin/staging ref(s), as last fetched); taken.tsv $REAL_TSV_SRC"
CLONE_GITDIR="$(git -C "$REAL_CLONE" rev-parse --absolute-git-dir 2>&1)"; CLONE_RC=$?
if [ "$CLONE_RC" -ne 0 ]; then skip=$((skip+1)); echo "SKIP real data: no template clone at $REAL_CLONE (set OPENBRAIN_TEMPLATE_DIR) — the real-data cases did not run"
elif [ "$CLONE_GITDIR" != "$(cd "$REAL_CLONE" && pwd -P)/.git" ]; then fail=$((fail+1)); echo "FAIL real data: CANNOT-CHECK — $REAL_CLONE is not a standalone clone (git dir $CLONE_GITDIR); a copy would share its live refs"
elif [ "$WT_RC" -ne 0 ] || [ -z "$REAL_MAIN" ]; then fail=$((fail+1)); echo "FAIL real data: CANNOT-CHECK — could not resolve the vault's main checkout (git worktree list rc=$WT_RC), so taken.tsv cannot be located"
elif [ ! -f "$REAL_TSV_SRC" ]; then skip=$((skip+1)); echo "SKIP real data: no taken.tsv at $REAL_TSV_SRC (nothing taken here yet) — the real-data cases did not run"
elif ! cp -R "$REAL_CLONE" "$W/real-clone" || ! cp "$REAL_TSV_SRC" "$W/real-base.tsv"; then fail=$((fail+1)); echo "FAIL real data: could not copy the clone or taken.tsv"
else
  CLONE="$W/real-clone"; BASE_TSV="$W/real-base.tsv"; export OPENBRAIN_TEMPLATE_DIR="$CLONE"
  branch_cases "real data" skip
fi

echo "taken-status: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
