#!/usr/bin/env bash
# mcp-local-build.sh <launcher-path>  —  the `--apply <mcp>` capability (shape=fork).
#   Takes the LAUNCHER PATH, not a bare name: it resolves dir= itself through
#   mcp_get (_mcp-decl.sh, sourced from BESIDE THIS SCRIPT — never beside the
#   launcher; override with $MCP_DECL_SH), so root=/owner=/.dir= overrides
#   apply the same way they do everywhere else — no hardcoded $HOME/<name>.
# mcp-local-build.sh --checkout <mcp-name> <dir> <sub> <branch> [entry]   (shape=checkout:
#   ff-pull <branch> in <dir>, install at the root, build + test <sub>, same
#   last-good dist protection and dist/.built-from provenance as the fork path.
#   [entry] = the declaration's entry= relative to <sub> (default dist/index.js) —
#   the file the post-build smoke check parses.)
#
# Rebuild a hand-managed MCP server's `local-build` branch from its fork's
# in-flight feature branches, then build dist — keeping the last-good dist if
# the build fails. Git-native (reads the fork; no file transfers). Reproducible
# on any machine that has the fork remote, so every machine converges by running it.
#
# Contract / safety:
#   * Refuses unless the repo has a non-origin "fork" remote (hand-managed).
#   * Refuses on a dirty working tree (won't clobber uncommitted work).
#   * local-build = <base> + every live fork feat/* branch, merged --no-ff.
#     A merge conflict ABORTS loud (resolve in the feature branch, never here):
#     the merge is aborted and local-build + HEAD restored, so the next run isn't
#     blocked by a half-merged checkout; dist/ is never touched on that path.
#   * THE ENGINE OWNS THE BUILD LOCK (<checkout>.openbrain-build.lock, _mcp-decl.sh)
#     for its whole run — taken before anything touches the checkout, released
#     only when this process exits — so the lock's lifetime is the build's
#     lifetime. No caller ever holds it on the engine's behalf (a caller that dies
#     would release it while this build still runs). Concurrent runs serialize.
#   * Build runs after backing up dist/ to .dist.bak; on failure — or on an
#     INT/TERM/HUP mid-build — the old dist/ is restored. A backup stranded by
#     an untrappable kill is restored at the start of the next run — only while
#     holding the lock (so no live build is using it), and BEFORE the dirty-tree
#     refusal (which would otherwise see .dist.bak and refuse forever).
#   * Stamp-time mixed check: a build stamps dist/.built-from only if every file
#     under dist/ is newer than the build's start marker (build-start.<pid>, kept
#     inside the lock dir, backdated 1 s so same-second writes never false-positive). A file that
#     predates the build — e.g. an age-stale lock (a build running past
#     $MCP_LOCK_STALE_MIN min) let another run restore an old dist/ underneath
#     this one — means dist/ is mixed: it is left UNSTAMPED and the run fails
#     loudly. A vanished marker means the lock itself was taken over: same (the
#     marker is per run, so a run never mistakes the new holder's marker for its own).
#     An unstamped dist/ still runs (the launcher keys on the entry existing); the
#     checker reports it (unproven-build) until --apply rebuilds it.
#   * MCP_BUILD_ONLY_IF_MISSING=<entry>: after taking the lock (and recovering),
#     exit 0 without building when <entry> exists — a launcher's lazy build that
#     queued behind a concurrent one does not rebuild what that one just built.
#   * Dependencies install with --ignore-scripts: no package lifecycle script
#     (prepare, postinstall, ...) runs; the build and tests run explicitly.
#     npm ci is skipped when node_modules was installed from the current lockfile
#     (a hash recorded in node_modules/.openbrain-lockfile-hash after a complete
#     install; npm ci removes node_modules first, so the marker never survives a
#     partial one).
#   * Fork mode builds local-build at the checkout root from <origin>/main and
#     runs dist/index.js: a non-default sub=/entry=/branch is a STOP
#     (mcp_fork_unsupported), never a silent build of something else.
#   * A feature branch already merged upstream merges as a no-op (harmless);
#     if `gh` is available we additionally REPORT merged PRs as drop candidates.
#   * MCP_APPLY_PIN=<pin> (set by check-updates.sh --apply <mcp> --pin <pin>): build
#     EXACTLY the approved composition, never whatever is live at apply time.
#       fork:     <pin> = main=<sha>[,feat/<name>=<sha>]... — local-build is rebuilt from
#                 that base + those tips, merged by sha. A feat pushed after the offer is
#                 simply not in it (the next check offers it); one in the old local-build
#                 but not in the pin is dropped. A pinned sha not present after the fetch
#                 is a loud failure naming it — never skipped.
#       checkout: <pin> = the approved <origin>/<branch> commit. The engine fast-forwards to
#                 it. If HEAD is then still PAST it with commits touching <sub> (local
#                 unpushed commits, or another server's apply moved a shared checkout) it
#                 builds nothing and EXITS 75 (held), writing the reason to $MCP_APPLY_VERDICT.
#     Every pin ends in ,built=<sha|none>: the build its offer was made against. Under the
#     lock, before anything touches the checkout, a pin whose built= is not the current build
#     (mcp_built_id) is STALE: nothing is built and the engine EXITS 76, writing why to
#     $MCP_APPLY_VERDICT. Every engine run writes dist/.built-from only under this lock, so the
#     build the check saw is the build this run replaces (a hand revert is a human step, run
#     while no apply is).
#     Unset/empty = unpinned (whatever is live — a direct human command, auto, or a launch).
#
# Env overrides (also used by the scratch test):
#   MCP_FORK_REMOTE (default: fork)   MCP_BASE_REMOTE (default: origin)
#   MCP_BASE_REF (default: <base-remote>/main)   MCP_BUILD_CMD (default: install_deps . && npm run build && npm run test --if-present)
#   MCP_DECL_SH (default: _mcp-decl.sh beside this script)   MCP_SKIP_FETCH (default: 0)
#   MCP_APPLY_PIN (default: unset — unpinned)   MCP_APPLY_VERDICT (file for the held reason)
# Exit: 0 built · 1 refused/failed (last-good dist kept) · 75 held (pinned checkout: nothing built)
#       · 76 stale (the pin's built= is not the current build: nothing built)
#
# NB (macOS): bash shebang (zsh won't word-split); `grep -vc` not `grep -qv`.
set -euo pipefail

PIN="${MCP_APPLY_PIN:-}"
ARG1="${1:?usage: mcp-local-build.sh <launcher-path>  OR  mcp-local-build.sh --checkout <mcp-name> <dir> <sub> <branch> [entry]}"
FORK_REMOTE="${MCP_FORK_REMOTE:-fork}"
BASE_REMOTE="${MCP_BASE_REMOTE:-origin}"
BASE_REF="${MCP_BASE_REF:-$BASE_REMOTE/main}"
BUILD_CMD="${MCP_BUILD_CMD:-install_deps . && npm run build && npm run test --if-present}"   # build, then test (same order as --checkout); tests gate the build: a failing feat/* keeps the last-good dist
SERVER="dist/index.js"

die(){ printf 'mcp-local-build: %s\n' "$*" >&2; exit 1; }
log(){ printf 'mcp-local-build: %s\n' "$*" >&2; }

# Beside THIS SCRIPT, never beside the launcher: a vault-run engine (this file,
# in .openbrain/lib) must load the vault's own _mcp-decl.sh even when asked to
# build an INSTALLED launcher — sourcing from the launcher's directory would
# hand a vault run the (possibly stale, pulled-but-not-deployed) installed
# parser and die with a bare `mcp_get: command not found`. Both modes need it
# (the build lock lives there).
DECL_SH="${MCP_DECL_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_mcp-decl.sh}"
[ -f "$DECL_SH" ] || die "_mcp-decl.sh not found at $DECL_SH (set MCP_DECL_SH, or deploy it next to this engine)"
# shellcheck source=_mcp-decl.sh
. "$DECL_SH"

# take_lock <checkout> : the engine's own build lock, held until this process exits.
take_lock(){
  _mcp_lock_acquire "$1" || die "could not take the build lock for $1"
}

# install_deps <root> : npm ci --ignore-scripts, skipped when node_modules was completely
# installed from the current package-lock.json (hash marker written only after success).
# No lockfile -> npm install --ignore-scripts --no-package-lock (nothing to compare against;
# always runs; writes no package-lock.json, which would leave the checkout dirty and make
# every later build refuse it).
install_deps(){
  local root="$1" hash mark="$1/node_modules/.openbrain-lockfile-hash"
  if [ ! -f "$root/package-lock.json" ]; then
    ( cd "$root" && npm install --ignore-scripts --no-package-lock --no-fund --no-audit ); return
  fi
  hash="$({ shasum -a 256 < "$root/package-lock.json" 2>/dev/null || sha256sum < "$root/package-lock.json"; } | awk '{print $1}')"
  [ -n "$hash" ] || die "could not hash $root/package-lock.json"
  if [ -d "$root/node_modules" ] && [ -f "$mark" ] && [ "$(cat "$mark")" = "$hash" ]; then
    log "package-lock.json unchanged since the last complete install — skipping npm ci"
    return 0
  fi
  ( cd "$root" && npm ci --ignore-scripts --no-fund --no-audit ) || return 1
  mkdir -p "$root/node_modules" && printf '%s\n' "$hash" > "$mark"
}

# after_lock <pkgdir> <pin-kind> : the steps that must follow taking the lock, in order. The
# stale-offer check runs after the recovery (the restored dist/ is the current build) and before
# any refusal or checkout change, so a refused go leaves everything as it was.
after_lock(){
  recover_stranded_dist "$1"
  if [ -n "${MCP_BUILD_ONLY_IF_MISSING:-}" ] && [ -f "$MCP_BUILD_ONLY_IF_MISSING" ]; then
    log "$MCP_BUILD_ONLY_IF_MISSING already exists (a concurrent run built it first) — nothing to do"
    exit 0
  fi
  refuse_stale_pin "$1" "$2"
}

# refuse_stale_pin <pkgdir> <pin-kind> : validate the pin, exit 76 when its built= is not the
# build dist/ holds now, else reduce PIN to the composition the rest of the run builds.
refuse_stale_pin(){
  local want cur msg
  [ -n "$PIN" ] || return 0
  mcp_pin_valid "$2" "$PIN" || die "$NAME: malformed pin '$PIN' — expected $(mcp_pin_form "$2")"
  want="$(mcp_pin_built "$PIN")"
  cur="$(mcp_built_id "$1")" || die "$NAME: cannot read the current build's stamp under $1, so the offer cannot be checked against it — nothing built"
  if [ "$want" != "$cur" ]; then
    msg="the offer was made against build ${want:0:7}, but the current build is ${cur:0:7} (an apply or build ran after the offer) — applying it could move the build backward. Nothing built; re-run /brain-update-check (or --offer $NAME) for a fresh offer."
    log "stale: $msg"
    [ -z "${MCP_APPLY_VERDICT:-}" ] || printf '%s\n' "$msg" > "$MCP_APPLY_VERDICT"
    exit 76
  fi
  PIN="$(mcp_pin_target "$PIN")"
}

# start_marker : the build's start time, inside the lock dir this run holds, backdated
# 1 s so a file written in the same second as the marker still reads as newer. Per run
# (build-start.<pid>): after a takeover the new holder's marker never stands in for ours.
start_marker(){
  local m="$_MCP_LOCK/build-start.$$" ts
  ts=$(( $(date +%s) - 1 ))
  : > "$m" && touch -t "$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$ts" +%Y%m%d%H%M.%S)" "$m" \
    || die "could not write the build start marker $m"
  printf '%s' "$m"
}

# mixed_reason <pkgdir> <marker> : "" when every file under dist/ was written by this
# build, else why dist/ must not be stamped.
mixed_reason(){
  local pkg="$1" m="$2" old n
  [ -f "$m" ] || { printf 'the build lock was taken over during this build (it ran past the %s-min stale window) — dist/ may have been changed underneath it' "$MCP_LOCK_STALE_MIN"; return 0; }
  old="$(find "$pkg/dist" -type f ! -newer "$m")" || { printf 'could not list dist/ to check it'; return 0; }
  [ -n "$old" ] || return 0
  n="$(printf '%s\n' "$old" | wc -l | tr -d ' ')"
  printf '%s file(s) under dist/ predate this build (e.g. %s) — dist/ is mixed' "$n" "$(printf '%s\n' "$old" | head -1)"
}

# recover_stranded_dist <pkgdir> : a .dist.bak left behind means a previous build was
# killed between backing up dist/ and finishing — restore it as the last-good dist
# (whatever dist/ holds now is that interrupted build's partial output). Call ONLY while
# holding the build lock: then no live build can be using that .dist.bak.
recover_stranded_dist(){
  local pkg="$1"
  [ -e "$pkg/.dist.bak" ] || return 0
  log "restoring the last-good dist/ an interrupted build left in $pkg/.dist.bak"
  rm -rf "$pkg/dist" && mv "$pkg/.dist.bak" "$pkg/dist" \
    || die "could not restore $pkg/.dist.bak — by hand: rm -rf $pkg/dist && mv $pkg/.dist.bak $pkg/dist"
}

# build_last_good <pkgdir> <commit-dir> <cmd> : run <cmd> in <pkgdir> with dist/ backed
# up; keep the new dist only if the command (build AND tests) succeeds and the entry
# parses; otherwise restore the previous dist. Writes dist/.built-from on success.
# INT/TERM/HUP during the build restore the previous dist before exiting.
build_last_good(){
  local pkg="$1" cdir="$2" cmd="$3" had_dist=0 mark why
  log "building ($cmd) ..."
  mark="$(start_marker)"   # before dist/ moves aside: a failure here strands nothing
  if [ -d "$pkg/dist" ]; then rm -rf "$pkg/.dist.bak"; mv "$pkg/dist" "$pkg/.dist.bak"; had_dist=1; fi
  _BLG_PKG="$pkg"; _BLG_HAD="$had_dist"
  trap '_blg_abort' INT TERM HUP
  if ( cd "$pkg" && eval "$cmd" ) >&2 \
     && [ -f "$pkg/$SERVER" ] \
     && node --check "$pkg/$SERVER" 2>/dev/null; then
    trap - INT TERM HUP
    why="$(mixed_reason "$pkg" "$mark")"
    if [ -n "$why" ]; then
      rm -f "$pkg/dist/.built-from"
      if [ "$had_dist" = 1 ]; then
        die "$why — NOT stamping; the previous dist/ stays in .dist.bak and the next launch or --apply restores it (the checker reports stranded-build)"
      fi
      die "$why — NOT stamping; dist/ is left unstamped and still runs (the checker reports unproven-build) — --apply rebuilds it"
    fi
    rm -rf "$pkg/.dist.bak"
    git -C "$cdir" rev-parse HEAD > "$pkg/dist/.built-from"   # content-based staleness marker (not mtime)
    log "OK — built and dist/ is current ($(git -C "$cdir" rev-parse --short HEAD))"
  else
    trap - INT TERM HUP
    rm -rf "$pkg/dist"
    die "build/test/smoke-test failed — $(_blg_restore "$pkg" "$had_dist"); fix the source and re-run"
  fi
}
# _blg_restore <pkgdir> <had-dist> : put the previous dist/ back when there was one, and
# print what the server runs now.
_blg_restore(){
  if [ "$2" = 1 ]; then mv "$1/.dist.bak" "$1/dist" && printf 'restored the previous dist/ (server still runs the last-good build)'
  else printf 'there was no previous build to keep (the server stays uninstalled until a build passes)'; fi
}
_blg_abort(){
  trap - INT TERM HUP
  rm -rf "$_BLG_PKG/dist"
  die "build interrupted — $(_blg_restore "$_BLG_PKG" "$_BLG_HAD")"
}

if [ "$ARG1" = "--checkout" ]; then
  NAME="${2:?usage: mcp-local-build.sh --checkout <mcp-name> <dir> <sub> <branch> [entry]}"
  CDIR="${3:?dir}"; SUB="${4:-.}"; BRANCH="${5:-main}"; SERVER="${6:-dist/index.js}"
  PKG="$CDIR"; [ "$SUB" = . ] || PKG="$CDIR/$SUB"
  [ -d "$CDIR/.git" ] || die "$CDIR is not a git repo"
  take_lock "$CDIR"
  after_lock "$PKG" checkout
  [ "$(git -C "$CDIR" symbolic-ref -q --short HEAD || true)" = "$BRANCH" ] \
    || die "$NAME: $CDIR is not on $BRANCH — refusing (the build tracks $BRANCH)"
  [ -z "$(git -C "$CDIR" status --porcelain -- "$SUB")" ] \
    || die "$NAME has uncommitted changes in $SUB — commit or stash them first (refusing to rebuild over dirty work)"
  if [ "${MCP_SKIP_FETCH:-0}" != "1" ]; then log "fetching $BASE_REMOTE ..."; git -C "$CDIR" fetch --quiet "$BASE_REMOTE"; fi
  TARGET="$BASE_REMOTE/$BRANCH"
  if [ -n "$PIN" ]; then
    git -C "$CDIR" cat-file -e "$PIN^{commit}" 2>/dev/null || die "$NAME: the approved commit $PIN is not in $CDIR after the fetch — nothing built"
    TARGET="$PIN"
  fi
  git -C "$CDIR" merge --ff-only --quiet "$TARGET" \
    || die "$NAME: $BRANCH cannot fast-forward to $TARGET (local commits?) — resolve by hand"
  # ff to an ancestor of HEAD is a no-op: HEAD may still be PAST the approved commit. Building
  # it would ship commits nobody approved for this server, so that is held, not built.
  if [ -n "$PIN" ] && [ "$(git -C "$CDIR" rev-parse HEAD)" != "$PIN" ]; then
    past="$(git -C "$CDIR" rev-list "$PIN..HEAD" -- "$SUB")" || die "$NAME: cannot list the commits between the approved ${PIN:0:7} and HEAD"
    if [ -n "$past" ]; then
      local_only="$(git -C "$CDIR" rev-list "$PIN..HEAD" --not "$BASE_REMOTE/$BRANCH" -- "$SUB")" || die "$NAME: cannot compare HEAD with $BASE_REMOTE/$BRANCH"
      n="$(printf '%s\n' "$past" | grep -c . || true)"; shas="$(printf '%s\n' "$past" | cut -c1-7 | tr '\n' ' ' | sed 's/ $//')"
      if [ -n "$local_only" ]; then why="they exist only on this machine (unpushed local commits) — push or drop them, then re-run /brain-update-check"
      else why="they are already on $BASE_REMOTE/$BRANCH: another server's apply moved this shared checkout — re-run /brain-update-check for an offer that covers them"; fi
      msg="HEAD is $n commit(s) past the approved ${PIN:0:7} touching $SUB ($shas); $why. Nothing built."
      log "held: $msg"
      [ -z "${MCP_APPLY_VERDICT:-}" ] || printf '%s\n' "$msg" > "$MCP_APPLY_VERDICT"
      exit 75
    fi
    log "HEAD is past the approved ${PIN:0:7} only outside $SUB — building $SUB at the approved source"
  fi
  build_last_good "$PKG" "$CDIR" "${MCP_CHECKOUT_BUILD_CMD:-install_deps \"$CDIR\" && npm run build && npm run test --if-present}"
  exit 0
fi

# --- shape=fork: ARG1 is a launcher path — resolve dir= through mcp_get ------
LAUNCHER="$ARG1"
[ -f "$LAUNCHER" ] || die "$LAUNCHER: launcher not found"
NAME="$(basename "$LAUNCHER" .sh)"
DIR="$(mcp_get "$LAUNCHER" dir)"
case "$DIR" in INVALID:*) die "${DIR#INVALID:}" ;; esac
UNSUP="$(mcp_fork_unsupported "$LAUNCHER")"
[ -z "$UNSUP" ] || die "$NAME: STOP — $UNSUP"

# --- preconditions ----------------------------------------------------------
[ -d "$DIR/.git" ] || die "$DIR is not a git repo"
take_lock "$DIR"
after_lock "$DIR" fork
# hand-managed = has the fork remote (use count, not grep -qv: BSD grep quirk)
[ "$(git -C "$DIR" remote | grep -c "^${FORK_REMOTE}$" || true)" -gt 0 ] \
  || die "$NAME has no '$FORK_REMOTE' remote — not a hand-managed fork checkout; nothing to do"
[ -z "$(git -C "$DIR" status --porcelain)" ] \
  || die "$NAME has uncommitted changes — commit or stash them first (refusing to rebuild over dirty work)"

# --- fetch ------------------------------------------------------------------
if [ "${MCP_SKIP_FETCH:-0}" != "1" ]; then
  log "fetching $BASE_REMOTE + $FORK_REMOTE ..."
  git -C "$DIR" fetch --quiet "$BASE_REMOTE"
  git -C "$DIR" fetch --quiet --prune "$FORK_REMOTE"   # --prune: a deleted feat/* must leave local-build, not linger as a stale remote ref
fi
git -C "$DIR" rev-parse --verify --quiet "$BASE_REF" >/dev/null \
  || die "base ref '$BASE_REF' not found after fetch"

# --- enumerate in-flight feature branches on the fork (feat/*) --------------
# `feat/` is an ENROLLMENT NAMESPACE, not a naming taxonomy. It does not mean
# "this branch is a feature" — it means "merge this into what the MCP actually
# runs, on every machine, automatically." Bugfixes belong here too; name them
# feat/*. Do NOT widen this glob to also match fix/*, chore/*, etc: a wider
# pattern silently sweeps abandoned spikes and superseded review branches into
# local-build, where they build cleanly and change behaviour with nothing
# prompting anyone to notice. Narrow-by-default is the safety property — a
# branch ships only because someone deliberately named it into the namespace.
# What to build, by sha: the approved pin, or (unpinned) one snapshot of what is live now.
branches=(); tips=()
if [ -n "$PIN" ]; then
  base_sha="${PIN%%,*}"; base_sha="${base_sha#main=}"; rest="${PIN#*,}"; [ "$rest" != "$PIN" ] || rest=""
  while [ -n "$rest" ]; do
    e="${rest%%,*}"; branches+=("$FORK_REMOTE/${e%=*}"); tips+=("${e##*=}")
    [ "$rest" != "${rest#*,}" ] && rest="${rest#*,}" || rest=""
  done
  for s in "$base_sha" ${tips[@]+"${tips[@]}"}; do
    git -C "$DIR" cat-file -e "$s^{commit}" 2>/dev/null \
      || die "$NAME: the approved commit $s is not in $DIR after the fetch (force-pushed away, or a mistyped pin) — nothing built"
  done
  log "building exactly the approved composition: $BASE_REF ${base_sha:0:7}${branches[*]+ + ${branches[*]}}"
else
  listing="$(mcp_fork_pin_listing "$DIR" "$BASE_REF" "$FORK_REMOTE")" \
    || die "could not read $BASE_REF and the $FORK_REMOTE/feat/* tips"
  base_sha="$(printf '%s\n' "$listing" | awk 'NR==1{print $2}')"
  while read -r b s; do [ -n "$b" ] && { branches+=("$b"); tips+=("$s"); }; done \
    < <(printf '%s\n' "$listing" | awk 'NR>1')
fi
if [ "${#branches[@]}" -eq 0 ]; then
  log "WARNING: no $FORK_REMOTE/feat/* branches found — local-build will just mirror $BASE_REF"
else
  log "feature branches to integrate: ${branches[*]}"
fi

# --- redundancy report (optional, informational; merging merged = no-op) ----
if command -v gh >/dev/null 2>&1; then
  # ${arr[@]+...} guard: bash 3.2 + set -u treats an empty array as unbound
  for b in ${branches[@]+"${branches[@]}"}; do
    head="${b#${FORK_REMOTE}/}"
    state="$(gh pr list --repo "$(git -C "$DIR" remote get-url "$FORK_REMOTE" | sed -E 's#.*github.com[:/]##; s#\.git$##')" \
              --head "$head" --state merged --json number --jq '.[0].number' 2>/dev/null || true)"
    [ -n "$state" ] && log "NOTE: $head appears MERGED upstream (PR #$state) — consider dropping it from the fork"
  done
fi

# --- refuse to drop hand commits ---------------------------------------------
# local-build is derived, never authored: `checkout -B` below recreates it, so a
# commit on it that is in neither the base nor any fork feat/* branch would
# silently drop off the branch. Refuse instead, naming count + short shas only
# (never messages — those are content). Remedy: move them to fork/feat/<slug>.
# A rebuilt local-build's first-parent chain is the base plus this engine's own
# --no-ff merges; feature commits sit only behind second parents. So a hand
# commit is a NON-merge commit on the first-parent chain. (Plain reachability
# would also flag the engine's merge commits and a since-deleted feat/*'s
# commits — dropping those is the point of rebuilding.)
if git -C "$DIR" rev-parse -q --verify refs/heads/local-build >/dev/null; then
  hand="$(git -C "$DIR" rev-list --first-parent --no-merges local-build --not "$base_sha" ${tips[@]+"${tips[@]}"})" \
    || die "could not list local-build commits outside $BASE_REF + $FORK_REMOTE/feat/*"
  if [ -n "$hand" ]; then
    die "local-build has $(printf '%s\n' "$hand" | wc -l | tr -d ' ') commit(s) in neither $BASE_REF nor any $FORK_REMOTE/feat/* ($(printf '%s\n' "$hand" | cut -c1-7 | tr '\n' ' ' | sed 's/ $//')) — rebuilding would drop them; push them to $FORK_REMOTE/feat/<slug>, then re-run"
  fi
fi

# --- rebuild local-build ----------------------------------------------------
# Record where git stands so a failed merge can put it back: local-build's tip
# (empty = none yet) and HEAD (a branch ref, or a sha when detached).
lb_rc=0; git -C "$DIR" show-ref --verify --quiet refs/heads/local-build || lb_rc=$?
case "$lb_rc" in
  0) prev_lb="$(git -C "$DIR" rev-parse refs/heads/local-build)" ;;
  1) prev_lb="" ;;
  *) die "could not tell whether local-build exists (git show-ref rc=$lb_rc)" ;;
esac
prev_head="$(git -C "$DIR" symbolic-ref -q HEAD || git -C "$DIR" rev-parse HEAD)"
# dist/ is build output, never merged: a feat/* tracking files there would overwrite the
# last-good dist mid-rebuild (and a failed merge's restore would then delete them).
i=0
while [ "$i" -lt "${#branches[@]}" ]; do
  b="${branches[$i]}"; i=$((i+1))
  dp="$(git -C "$DIR" diff --name-only "$base_sha...${tips[$((i-1))]}" -- dist/)" || die "could not diff $b against $BASE_REF"
  [ -z "$dp" ] || die "$b changes dist/ ($(printf '%s' "$dp" | tr '\n' ' ' | sed 's/ $//')) — dist/ is build output; remove it from that feature branch, then re-run"
done
# merge_failed <branch> <git output> <branch-sha> : abort the merge, restore local-build + HEAD, then
# die. A conflict names <branch>, the base and/or already-merged branches touching the
# conflicted files, and those files; any other failure relays git's own output.
# Each restore step that fails dies with its manual remedy.
merge_failed(){
  local b="$1" out="$2" bsha="$3" f m j=0 with="" files=() was="its prior absence"
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done \
    < <(git -C "$DIR" diff --name-only --diff-filter=U)
  if git -C "$DIR" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git -C "$DIR" merge --abort \
      || die "merging $b failed and 'git merge --abort' failed too — run it by hand in $DIR"
  fi
  if [ -n "$prev_lb" ]; then
    git -C "$DIR" checkout -q -B local-build "$prev_lb" \
      || die "merging $b failed; could not restore local-build — by hand: git -C $DIR checkout -B local-build $prev_lb"
  fi
  if [ "$prev_head" != refs/heads/local-build ]; then
    case "$prev_head" in
      refs/heads/*) git -C "$DIR" checkout -q "${prev_head#refs/heads/}" ;;
      *)            git -C "$DIR" checkout -q --detach "$prev_head" ;;
    esac || die "merging $b failed; could not return to ${prev_head#refs/heads/} — check it out by hand in $DIR"
    if [ -z "$prev_lb" ]; then
      git -C "$DIR" branch -q -D local-build \
        || die "merging $b failed; could not delete the partial local-build — by hand: git -C $DIR branch -D local-build"
    fi
  fi
  [ -z "$prev_lb" ] || was="${prev_lb:0:7}"
  [ "${#files[@]}" -gt 0 ] \
    || die "merging $b failed (not a conflict) — merge aborted, local-build restored to $was; git said: $(printf '%s' "$out" | tr '\n' ' ')"
  printf '%s\n' "$out" >&2
  git -C "$DIR" --literal-pathspecs diff --quiet "$bsha...$base_sha" -- "${files[@]}" || with="$BASE_REF"
  while [ "$j" -lt "${#merged[@]}" ]; do
    m="${merged[$j]}"
    git -C "$DIR" --literal-pathspecs diff --quiet "$base_sha...${merged_tips[$j]}" -- "${files[@]}" || with="$with${with:+, }$m"
    j=$((j+1))
  done
  die "merge conflict integrating $b with ${with:-$BASE_REF} (conflicted: ${files[*]}) — merge aborted, local-build restored to $was; resolve it in that feature branch (never hand-edit local-build), then re-run"
}
log "rebuilding local-build from $BASE_REF ..."
git -C "$DIR" checkout -q -B local-build "$base_sha"
merged=(); merged_tips=()
i=0
while [ "$i" -lt "${#branches[@]}" ]; do
  b="${branches[$i]}"; s="${tips[$i]}"; i=$((i+1))
  log "  merge $b (${s:0:7})"
  # by sha (the verified snapshot), with the message a merge by name would have had
  out="$(git -C "$DIR" merge --no-ff --no-edit -m "Merge remote-tracking branch '$b' into local-build" "$s" 2>&1)" || merge_failed "$b" "$out" "$s"
  printf '%s\n' "$out"
  merged+=("$b"); merged_tips+=("$s")
done

# --- build with last-good protection ----------------------------------------
build_last_good "$DIR" "$DIR" "$BUILD_CMD"
