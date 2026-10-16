#!/usr/bin/env bash
# taken-status.sh — the ONE read-only answer to "is anything new on a template
# branch since this vault last took it?". The
# /pull-openbrain-template plan block still carries its own copy of the
# start-point rule below — a known second definition; keep the two in step.
#
# Read-only: never merges, never writes taken.tsv, never touches the vault.
# The only side effect is `git fetch --prune` in the template clone (--all mode).
#
# Start point = exactly the pull plan block's rule (pull SKILL.md step 1):
#   - the branch's LAST taken.tsv row, which must be an ancestor of the tip;
#   - no row, upstream   → CANNOT-CHECK (pull demands a declared baseline);
#   - no row, topic      → nearest taken sha (any row) that is an ancestor of
#                          the tip, else merge-base with staging/main.
#
# Three outcomes, never two (CLAUDE.md "Checker norms"):
#   nothing-new    exit 0   tip == start point, proven by sha equality
#   new            exit 10  N commits past the start point
#   cannot-check   exit 20  anything that prevents the comparison — never
#                           collapses into nothing-new
#
# Enumeration (--all) is from LIVE refs, never from taken.tsv rows: upstream
# main + every branch under staging's refs/heads/topic/* per `git ls-remote`.
# No `staging` remote → prints `staging: not configured` and checks upstream only.
# Rows for branches that no longer exist are never asked about — and never
# deleted: rows accumulate by design (pull SKILL.md "Rows accumulate").
#
# Usage:
#   bash .openbrain/lib/taken-status.sh --all            # report every live branch
#   bash .openbrain/lib/taken-status.sh upstream         # one branch, no fetch
#   bash .openbrain/lib/taken-status.sh topic/<name>     # one branch, no fetch
#   source .openbrain/lib/taken-status.sh; taken_status topic/<name>
# Env: VAULT (default: this file's vault), OPENBRAIN_TEMPLATE_DIR (default
# ~/openbrain-claude-starter), TAKEN_TSV (default $_TS_VAULT/.openbrain/local/taken.tsv).
#
# Output, one line per branch:  <branch>\t<status>\t<detail>

_ts_init() {
  _TS_VAULT="${VAULT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  _TS_TEMPLATE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
  _TS_MARK="${TAKEN_TSV:-$_TS_VAULT/.openbrain/local/taken.tsv}"
}

_ts_git() { git -C "$_TS_TEMPLATE" "$@"; }

# The public template's remote: `upstream`, or `origin` in a clone of the template itself (pull's rule).
_ts_upr() {
  local r; r="$(_ts_git remote)" || return 1
  if printf '%s\n' "$r" | LC_ALL=C grep -qx upstream; then echo upstream; else echo origin; fi
}

# taken_status <upstream|topic/<name>> — prints one line, returns 0/10/20. No fetch.
taken_status() {
  _ts_init
  local b="$1" ref tip from origin n upr tb ts _tt bestn paths
  local cc=20
  case "$b" in
    upstream) upr="$(_ts_upr)" || { printf '%s\tcannot-check\tgit remote failed in %s\n' "$b" "$_TS_TEMPLATE"; return $cc; }; ref="$upr/main" ;;
    topic/?*) ref="staging/$b" ;;
    *) printf '%s\tcannot-check\tnot a branch name this checks (upstream | topic/<name>)\n' "$b"; return $cc ;;
  esac
  [ -d "$_TS_TEMPLATE/.git" ] || { printf '%s\tcannot-check\tno template clone at %s\n' "$b" "$_TS_TEMPLATE"; return $cc; }
  [ -f "$_TS_MARK" ] || { printf '%s\tcannot-check\tno taken.tsv at %s\n' "$b" "$_TS_MARK"; return $cc; }
  [ -r "$_TS_MARK" ] || { printf '%s\tcannot-check\ttaken.tsv unreadable: %s\n' "$b" "$_TS_MARK"; return $cc; }
  tip="$(_ts_git rev-parse --verify -q "$ref^{commit}")" || { printf '%s\tcannot-check\tno %s in the clone\n' "$b" "$ref"; return $cc; }

  from="$(LC_ALL=C awk -F'\t' -v k="$b" '$1==k {s=$2} END {print s}' "$_TS_MARK")" || { printf '%s\tcannot-check\tcould not read taken.tsv\n' "$b"; return $cc; }
  if [ -n "$from" ]; then
    _ts_git cat-file -e "$from^{commit}" 2>/dev/null || { printf '%s\tcannot-check\tlast taken sha %s is not in the clone (rewritten branch?)\n' "$b" "$from"; return $cc; }
    from="$(_ts_git rev-parse --verify "$from^{commit}")" || { printf '%s\tcannot-check\tcould not resolve %s\n' "$b" "$from"; return $cc; }
    _ts_git merge-base --is-ancestor "$from" "$tip" || { printf '%s\tcannot-check\tlast taken %s is not an ancestor of %s — the branch was rewritten\n' "$b" "$(_ts_git rev-parse --short "$from")" "$(_ts_git rev-parse --short "$tip")"; return $cc; }
    origin="last taken $(_ts_git rev-parse --short "$from")"
  elif [ "$b" = upstream ]; then
    printf '%s\tcannot-check\tno upstream row in taken.tsv — /pull-openbrain-template needs a declared baseline first\n' "$b"; return $cc
  else
    from="$(_ts_git merge-base staging/main "$tip")" || { printf '%s\tcannot-check\tno merge-base between staging/main and %s\n' "$b" "$ref"; return $cc; }
    bestn="$(_ts_git rev-list --count "$from..$tip")" || { printf '%s\tcannot-check\tgit rev-list failed\n' "$b"; return $cc; }
    origin="never taken here; from its merge-base with staging/main"
    while IFS=$'\t' read -r tb ts _tt || [ -n "$tb$ts" ]; do
      [ -n "$ts" ] || continue
      _ts_git cat-file -e "$ts^{commit}" 2>/dev/null || continue   # a row whose sha is gone is a note to pull, not a start point here
      _ts_git merge-base --is-ancestor "$ts" "$tip" || continue
      n="$(_ts_git rev-list --count "$ts..$tip")" || { printf '%s\tcannot-check\tgit rev-list failed\n' "$b"; return $cc; }
      if [ "$n" -lt "$bestn" ]; then from="$(_ts_git rev-parse "$ts^{commit}")"; bestn="$n"; origin="never taken here; stacked on $tb@$(_ts_git rev-parse --short "$ts")"; fi
    done < "$_TS_MARK"
  fi

  if [ "$from" = "$tip" ]; then
    printf '%s\tnothing-new\t%s == tip (%s)\n' "$b" "$(_ts_git rev-parse --short "$tip")" "$origin"; return 0
  fi
  n="$(_ts_git rev-list --count "$from..$tip")" || { printf '%s\tcannot-check\tgit rev-list failed\n' "$b"; return $cc; }
  [ "$n" -gt 0 ] || { printf '%s\tcannot-check\tstart %s differs from tip but 0 commits between them\n' "$b" "$from"; return $cc; }
  # the pull plan works by changed PATHS, not commits: commits that change nothing (empty, commit+revert) make it STOP — mirror it
  paths="$(_ts_git diff --name-only "$from" "$tip")" || { printf '%s\tcannot-check\tgit diff failed\n' "$b"; return $cc; }
  [ -n "$paths" ] || { printf '%s\tcannot-check\t%s commit(s) but no changed paths — the pull plan STOPs here too; inspect by hand\n' "$b" "$n"; return $cc; }
  printf '%s\tnew\t%s commit(s) → %s (%s)\n' "$b" "$n" "$(_ts_git rev-parse --short "$tip")" "$origin"; return 10
}

# taken_status_all — fetch, enumerate live refs, report each + a coverage line. Returns 0/10/20.
taken_status_all() {
  _ts_init
  local upr remotes ls rc nls sha name live tracked nn=0 nnew=0 ncc=0 nclean=0 worst=0 st out gone
  [ -d "$_TS_TEMPLATE/.git" ] || { echo "cannot-check: no template clone at $_TS_TEMPLATE"; return 20; }
  upr="$(_ts_upr)" || { echo "cannot-check: git remote failed in $_TS_TEMPLATE"; return 20; }
  remotes="$(_ts_git remote)" || { echo "cannot-check: git remote failed in $_TS_TEMPLATE"; return 20; }
  GIT_TERMINAL_PROMPT=0 _ts_git fetch -q --prune "$upr" || { echo "cannot-check: fetching $upr failed — nothing was compared"; return 20; }
  # no `staging` remote is a declared state (a template user has none), not a failure: say so and check upstream alone.
  # A staging remote that is present but unreachable stays cannot-check (the fetch below).
  if ! printf '%s\n' "$remotes" | LC_ALL=C grep -qx staging; then
    echo "staging: not configured"
    out="$(taken_status upstream)"; st=$?; printf '%s\n' "$out"
    case $st in 0) nclean=1 ;; 10) nnew=1 ;; *) ncc=1 ;; esac
    echo "coverage: 1 branch(es) checked ($upr/main; staging not configured) — $nnew new, $nclean nothing-new, $ncc cannot-check"
    return $st
  fi
  GIT_TERMINAL_PROMPT=0 _ts_git fetch -q --prune staging || { echo "cannot-check: fetching staging failed — nothing was compared"; return 20; }
  ls="$(GIT_TERMINAL_PROMPT=0 _ts_git ls-remote --heads staging 'refs/heads/topic/*')"; rc=$?
  [ "$rc" -eq 0 ] || { echo "cannot-check: git ls-remote staging failed (exit $rc)"; return 20; }

  out="$(taken_status upstream)"; st=$?; printf '%s\n' "$out"; nn=$((nn+1))
  case $st in 0) nclean=$((nclean+1)) ;; 10) nnew=$((nnew+1)) ;; *) ncc=$((ncc+1)) ;; esac
  [ $st -gt $worst ] && worst=$st
  live=""
  while IFS=$'\t' read -r sha name; do
    [ -n "$name" ] || continue
    name="${name#refs/heads/}"; live="$live$name"$'\n'; nn=$((nn+1))
    tracked="$(_ts_git rev-parse -q --verify "refs/remotes/staging/$name")"
    if [ "$tracked" != "$sha" ]; then
      printf '%s\tcannot-check\tlocal staging/%s (%s) != live %s after fetch\n' "$name" "$name" "${tracked:-missing}" "$sha"; st=20
    else
      out="$(taken_status "$name")"; st=$?; printf '%s\n' "$out"
    fi
    case $st in 0) nclean=$((nclean+1)) ;; 10) nnew=$((nnew+1)) ;; *) ncc=$((ncc+1)) ;; esac
    [ $st -gt $worst ] && worst=$st
  done <<< "$ls"
  # coverage self-check: every ls-remote line must have produced a verdict (a loop that skips rows would otherwise read clean)
  nls=0; [ -n "$ls" ] && nls="$(printf '%s\n' "$ls" | LC_ALL=C grep -c .)"
  if [ "$((nn-1))" -ne "$nls" ]; then echo "cannot-check: staging listed $nls topic(s) but $((nn-1)) were checked"; worst=20; fi
  # zero topics is a proven state here: ls-remote exited 0 against the live remote (upstream is still reported above)

  gone="$(LC_ALL=C awk -F'\t' '$1 ~ /^topic\// {print $1}' "$_TS_MARK" 2>/dev/null | LC_ALL=C sort -u | LC_ALL=C grep -vxF -f <(printf '%s' "$live") || true)"
  echo "coverage: $nn branch(es) checked ($upr/main + $((nn-1)) live staging topic(s)) — $nnew new, $nclean nothing-new, $ncc cannot-check"
  [ -n "$gone" ] && echo "not asked: $(printf '%s\n' "$gone" | wc -l | tr -d ' ') taken.tsv branch(es) no longer on staging ($(printf '%s' "$gone" | tr '\n' ' ' | sed 's/ $//')) — rows kept by design"
  return $worst
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --all) taken_status_all ;;
    upstream|topic/?*) taken_status "$1" ;;
    *) echo "usage: $0 --all | upstream | topic/<name>" >&2; exit 2 ;;
  esac
fi
