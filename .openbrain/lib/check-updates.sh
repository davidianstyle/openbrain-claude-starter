#!/usr/bin/env bash
# check-updates.sh  —  "do this brain's MCP servers need updating?"
#
#   --check           cheap, LOCAL-only, on-start-safe nag. No network, never mutates. Honors --snooze.
#   --full            fetch + consult npm, then AUTO-APPLY every MCP whose policy is auto, then report.
#   --report          --full without auto-apply (report only).
#   --apply <mcp>     update one MCP now, per its declared shape (the user's go; either mode):
#                       fork -> mcp-local-build.sh <mcp>; checkout -> mcp-local-build.sh --checkout ...;
#                       npm  -> record the latest published version (the launcher pins to it).
#   --snooze          acknowledge the current FINDINGS (silences --check until they change).
#                     CANNOT-CHECK is never snoozed: missing evidence is reported every time.
#
# WHAT IS CHECKED is declared, never inferred: each ~/.config/openbrain/lib/*-mcp.sh
# launcher carries one `# openbrain-mcp: shape=...` line (grammar + policy: _mcp-decl.sh).
# The launcher executes from that line, so what is checked is what runs.
#
# UPDATE POLICY (per machine, per MCP: `<launcher>.update=auto|ask` lines in
# ~/.config/openbrain/mcp-config; absent -> ask; grammar: _mcp-decl.sh):
#   ask    report only; /brain-update-check offers --apply on the user's go
#   auto   --full applies it — held only when a human must act first (dirty-tree, off-branch,
#          unpushed, shape-mismatch, bad-declaration, unenrolled, unsupported-key, fork-mismatch, origin-mismatch).
#          fork/checkout/canary: the engine's tests gate
#          the build. Plain npm (stable): NO test gate — auto records the latest publish.
#   An invalid mode is CANNOT-CHECK here and the launcher refuses to start, never a default.
# CHANNELS (shape=npm only; per machine, in the same policy file — grammar: _mcp-decl.sh):
#   stable  npm checks: unpinned / update-available / publish-lag / stale npx processes
#   canary  the server runs from <src>/<sub> on main, so it is checked + applied exactly like
#           shape=checkout (source-behind after --full's fetch, dirty-tree, dist-stale,
#           unproven-build, stale-process). "Unreleased vs npm" (commits touching <sub> since
#           the published gitHead) is an `info` line: never a finding, never on --check's line.
#   Either channel flags processes still running the OTHER channel (switch = restart).
#   An invalid channel is CANNOT-CHECK (the launcher refuses to start), never a default.
# Every fork/checkout/canary apply goes through mcp-local-build.sh (tests gate it; last-good
# dist kept on failure); every apply logs to ~/.config/openbrain/mcp-updates/applied.log and
# ends with: installed — restart Claude Code to apply.
#
# Three outcomes, three exit codes (report + --check):
#   0  CLEAN        every registered server resolved to a declaration and every check compared evidence
#   10 FINDINGS     something to act on (each line carries its remedy)
#   20 CANNOT-CHECK some evidence could not be gathered -> NOT a clean bill (20 wins over 10)
# Coverage is stated on every run. Autodetection is RECONCILIATION: every stdio server
# registered in ~/.claude.json (user scope + this vault's project entry) must resolve to a
# declared launcher; one that does not is a finding (with a suggested declaration — a
# proposal for a human, never load-bearing). Nothing else is read: a project .mcp.json is
# out of scope, and the coverage line names the one source.
#
# NB (macOS): bash 3.2 shebang (zsh won't word-split); grep -c not grep -qv.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${MCP_HOME:-$HOME}"
LIB="${MCP_LIB_DIR:-$HOME_DIR/.config/openbrain/lib}"
REG_LIB="${MCP_REGISTERED_LIB:-$LIB}"     # dir the registrations point into (differs only in tests)
CLAUDE_JSON="${MCP_CLAUDE_JSON:-$HOME_DIR/.claude.json}"
VAULT="${OPENBRAIN_VAULT:-$(cd "$HERE/../.." && pwd)}"
FORK_REMOTE="${MCP_FORK_REMOTE:-fork}"
APPLY_SH="${MCP_LOCAL_BUILD_SH:-$HERE/mcp-local-build.sh}"
SNOOZE_FILE="${OPENBRAIN_UPDATE_SNOOZE:-$HOME_DIR/.config/openbrain/update-snooze}"
NPM="${MCP_NPM:-npm}"
PS_FILE="${MCP_PS_FILE:-}"                # tests: canned `ps -axo pid=,lstart=,command=` output
NETWORK=0
NO_FETCH="${MCP_NO_FETCH:-0}"
RESTART_MSG="installed — restart Claude Code to apply"

log(){ printf '%s\n' "$*" >&2; }

# Source BESIDE THIS SCRIPT, never the installed copy at $LIB and no fallback
# chain: one rule everywhere a .openbrain/lib/*.sh sources _mcp-decl.sh. The
# checker and its resolver must always agree; only launchers and bootstrap use
# the installed copy (they run from it by construction).
[ -f "$HERE/_mcp-decl.sh" ] || { printf 'cannot\t-\tdeclaration parser _mcp-decl.sh not found beside %s\n' "$HERE"; exit 20; }
. "$HERE/_mcp-decl.sh"
STATE="$MCP_UPDATE_STATE"

# emit helpers — TAB-separated:  mcp <name> <class> <remedy> | cannot <name> <why> | cov <key> <value>
#                                act <name> <verdict> <detail>   (auto-apply outcome, --full only)
F(){ printf 'mcp\t%s\t%s\t%s\n' "$1" "$2" "$3"; }
C(){ printf 'cannot\t%s\t%s\n' "$1" "$2"; }
V(){ printf 'cov\t%s\t%s\n' "$1" "$2"; }

I(){ printf 'info\t%s\t%s\n' "$1" "$2"; }      # informational only: never a finding, never in --check

pkgdir(){ mcp_pkgdir "$1"; }       # one definition, shared with the launchers (_mcp-decl.sh)
entry_of(){ mcp_entry "$1"; }

# registered : key US command US args US type US inlib   (US = \x1f)
# Scope: ~/.claude.json user servers, then its project entry for this vault (later wins).
# inlib=1 when the command is a *-mcp.sh directly inside $REG_LIB, compared by REALPATH —
# the same filter reconcile-runtime.sh's registered_launcher_names uses, so a symlinked lib
# path can never make the two disagree. A missing/unparseable file fails the whole call
# (the caller reports CANNOT-CHECK), never a silently smaller set.
registered(){
  python3 - "$CLAUDE_JSON" "$VAULT" "$REG_LIB" <<'PY'
import json, os, sys
path, vault, reg_lib = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
servers = dict(d.get("mcpServers") or {})
servers.update(((d.get("projects") or {}).get(vault) or {}).get("mcpServers") or {})
lib_real = os.path.realpath(reg_lib)
for k, v in sorted(servers.items()):
    t = v.get("type", "stdio")
    if t != "stdio":
        print(f"{k}\x1f-\x1f-\x1f{t}\x1f0"); continue
    cmd = v.get("command", "")
    d1, base = os.path.split(cmd)
    inlib = "1" if cmd and base.endswith("-mcp.sh") and os.path.realpath(d1 or ".") == lib_real else "0"
    print(f"{k}\x1f{cmd}\x1f{' '.join(v.get('args') or [])}\x1fstdio\x1f{inlib}")
PY
}

# ---------------------------------------------------------------------------
# stale processes: a server started before its current build is running old code
# ---------------------------------------------------------------------------
# LC_ALL=C: lstart's day/month names follow the locale, and STALE_PY parses the C form.
ps_lines(){ if [ -n "$PS_FILE" ]; then cat "$PS_FILE"; else LC_ALL=C ps -axo pid=,lstart=,command=; fi; }

# stale_scan dist <entry> <marker>  : node processes whose argv contains <entry>; stale if
#                                     started before <marker>'s mtime (dist/.built-from, else entry).
# stale_scan npx  <pkg>   <expected> : node processes under .../_npx/<h>/node_modules/.bin/ whose <h>
#                                     installs <pkg>; stale if started before that install, or running
#                                     a version != <expected> (when known).
# Prints "<n_seen> <n_stale> <n_unparsed>". ps output arrives on stdin (never interpolated
# into code). A non-blank line whose start time can't be parsed (another locale's day/month
# names) is counted as unparsed — the caller reports CANNOT-CHECK, never "0 stale".
STALE_PY='
import os, re, sys, time, json
mode, target, extra = sys.argv[1], sys.argv[2], sys.argv[3]
seen = stale = unparsed = 0
for line in sys.stdin:
    if not line.strip(): continue
    m = re.match(r"\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)", line)
    t0 = None
    if m:
        try: t0 = time.mktime(time.strptime(" ".join(m.group(2).split()), "%a %b %d %H:%M:%S %Y"))
        except ValueError: t0 = None
    if t0 is None:
        unparsed += 1; continue
    cmd = m.group(3)
    if not re.match(r"(\S*/)?node\s", cmd): continue
    if mode == "dist":
        if not re.search(r"(^|\s)" + re.escape(target) + r"(\s|$)", cmd): continue
        seen += 1
        ref = extra if os.path.exists(extra) else target
        if os.path.exists(ref) and t0 < int(os.path.getmtime(ref)): stale += 1
    else:
        mm = re.search(r"(/\S*/_npx/[0-9a-f]+)/node_modules/\.bin/", cmd)
        if not mm: continue
        pj = os.path.join(mm.group(1), "node_modules", *target.split("/"), "package.json")
        if not os.path.exists(pj): continue
        seen += 1
        try: ver = json.load(open(pj)).get("version", "")
        except Exception: ver = ""
        if t0 < int(os.path.getmtime(pj)) or (extra and ver != extra): stale += 1
print(seen, stale, unparsed)
'
stale_scan(){
  local procs; procs="$(ps_lines)" || return 1
  [ -n "$procs" ] || return 1
  python3 -c "$STALE_PY" "$1" "$2" "${3:-}" <<< "$procs"
}

check_stale(){  # $1=name $2=launcher $3=shape [$4=expected npm version]
  local out seen stale unparsed what
  if [ "$3" = npm ]; then what="$(decl_get "$2" pkg)"; out="$(stale_scan npx "$what" "${4:-}")" || { C "$1" "ps failed — cannot tell whether an open session runs an old build"; return 0; }
  else                  what="$(entry_of "$2")";      out="$(stale_scan dist "$what" "$(pkgdir "$2")/dist/.built-from")" || { C "$1" "ps failed — cannot tell whether an open session runs an old build"; return 0; }
  fi
  read -r seen stale unparsed <<< "$out"
  [ -n "${unparsed:-}" ] || { C "$1" "process scan produced no result"; return 0; }
  printf 'cov\tprocs\t%s: %s running, %s stale\n' "$1" "$seen" "$stale"
  [ "$unparsed" -eq 0 ] || { C "$1" "$unparsed ps line(s) in an unrecognised format (locale?) — cannot tell whether an open session runs an old build"; return 0; }
  [ "$stale" -eq 0 ] || F "$1" stale-process "!restart Claude Code to apply — $stale of $seen running process(es) predate the current build (an open session is running an old build)"
}

# ---------------------------------------------------------------------------
# per-shape checks.  $1=name  $2=launcher
# ---------------------------------------------------------------------------
# check_origin <name> <launcher> <dir> : git remote get-url origin vs the resolved
# declaration URL (mcp_get), URL-normalized. Changing owner=/.url= on an existing
# clone otherwise does nothing, silently.
check_origin(){
  local name="$1" l="$2" dir="$3" want actual
  want="$(mcp_get "$l" url)"; case "$want" in INVALID:*) C "$name" "${want#INVALID:}"; return 0 ;; esac
  [ -n "$want" ] || return 0
  actual="$(git -C "$dir" remote get-url origin 2>&1)" || { C "$name" "git remote get-url origin failed in $dir: $actual"; return 0; }
  _mcp_url_eq "$actual" "$want" \
    || F "$name" origin-mismatch "!git -C $dir remote set-url origin $want   # was: $actual — or, if that origin is intentional, set $name.url= (or owner=) in $MCP_CONFIG_FILE"
}

# stranded_build <name> <pkgdir> <checkout> : a .dist.bak is either a LIVE build's backup
# (the checkout's build lock exists and is not stale -> info "build in progress", never a
# finding) or what an interrupted build left behind (its last-good dist/ -> stranded-build;
# the next build run restores it). Either way it is excluded from the dirty-tree check,
# which would otherwise call it uncommitted work.
stranded_build(){
  local lk="$3.openbrain-build.lock"
  [ -e "$2/.dist.bak" ] || return 0
  if [ -d "$lk" ] && ! _mcp_lock_stale "$lk"; then
    I "$1" "build in progress ($lk is held) — $2/.dist.bak is that build's backup, not a leftover"
  else
    F "$1" stranded-build "--apply $1   # an interrupted build left the last-good dist/ in $2/.dist.bak — --apply restores it and rebuilds"
  fi
}

check_fork(){
  local name="$1" l="$2" dir head cur built dirty head_main ref refs remotes unsup rc
  dir="$(mcp_get "$l" dir)"; case "$dir" in INVALID:*) C "$name" "${dir#INVALID:}"; return 0 ;; esac
  unsup="$(mcp_fork_unsupported "$l")"
  [ -z "$unsup" ] || F "$name" unsupported-key "!$unsup"
  local cfg_fork; cfg_fork="$(mcp_get "$l" fork)"   # --apply can add the fork remote only from a .fork= line
  case "$cfg_fork" in INVALID:*) cfg_fork="" ;; esac   # reported as CANNOT-CHECK below
  if [ ! -d "$dir/.git" ]; then
    if [ -n "$cfg_fork" ]; then F "$name" missing "--apply $name   # clones $(mcp_get "$l" url), adds the '$FORK_REMOTE' remote and builds local-build (or just launch it)"
    else F "$name" missing "!launch it once (lazy install clones $(mcp_get "$l" url)), then add the '$FORK_REMOTE' remote, or set $name.fork= in $MCP_CONFIG_FILE and --apply $name"; fi
    return 0
  fi
  remotes="$(git -C "$dir" remote)" || { C "$name" "git remote failed in $dir"; return 0; }
  if [ "$(printf '%s\n' "$remotes" | grep -c "^${FORK_REMOTE}$" || true)" -eq 0 ]; then
    if [ -n "$cfg_fork" ]; then
      F "$name" shape-mismatch "--apply $name   # the effective shape is fork but $dir has no '$FORK_REMOTE' remote yet — --apply adds it from $name.fork= and builds local-build (or drop $name.fork= to keep it a checkout)"
    else
      F "$name" shape-mismatch "!declared shape=fork but $dir has no '$FORK_REMOTE' remote — add the remote, or set $name.fork= in $MCP_CONFIG_FILE and --apply $name, or fix the declaration"
    fi
    return 0
  fi
  check_origin "$name" "$l" "$dir"
  if fork_is_redundant "$l"; then
    I "$name" ".fork= equals the resolved origin — redundant; the shape resolver already treats this as checkout"
  fi
  # Fork-remote mismatch (URL-normalized), same comparison as check_origin: changing
  # .fork= in mcp-config on an EXISTING clone otherwise does nothing, silently — this
  # only REPORTS it (a re-point command); the build engine never silently re-points it.
  local want_fork actual_fork
  want_fork="$(mcp_get "$l" fork)"
  case "$want_fork" in
    INVALID:*) C "$name" "${want_fork#INVALID:}" ;;
    "") : ;;
    *)
      actual_fork="$(git -C "$dir" remote get-url "$FORK_REMOTE")" \
        || { C "$name" "git remote get-url $FORK_REMOTE failed in $dir — cannot compare it with .fork="; actual_fork=""; }
      if [ -n "$actual_fork" ] && ! _mcp_url_eq "$actual_fork" "$want_fork"; then
        F "$name" fork-mismatch "!git -C $dir remote set-url $FORK_REMOTE $want_fork   # was: $actual_fork"
      fi ;;
  esac
  if ! git -C "$dir" rev-parse -q --verify local-build >/dev/null 2>&1; then
    F "$name" no-local-build "--apply $name"; return 0
  fi
  head="$(git -C "$dir" rev-parse local-build)"
  # The stamp only proves dist/ was built from local-build while HEAD is on it: a hand
  # build on another branch leaves the old stamp in place (tsc never deletes it).
  cur="$(git -C "$dir" symbolic-ref -q --short HEAD || echo DETACHED)"
  [ "$cur" = local-build ] || F "$name" off-branch "!git -C $dir switch local-build   # the fork runs dist/ built on local-build; HEAD is $cur, so dist/ may hold a build of it — then --apply $name"
  built="$(cat "$dir/dist/.built-from" 2>/dev/null || true)"
  if [ -f "$dir/dist/index.js" ] && ! mcp_stamped "$dir"; then
    F "$name" unproven-build "--apply $name   # dist has no provenance marker (an interrupted, mixed, hand or pre-provenance build); it still runs until rebuilt"
  else
    [ "$built" = "$head" ] || F "$name" dist-stale "--apply $name"
  fi
  stranded_build "$name" "$dir" "$dir"
  dirty="$(git -C "$dir" status --porcelain -- . ':(exclude).dist.bak')" || { C "$name" "git status failed in $dir"; return 0; }
  [ -z "$dirty" ] || F "$name" dirty-tree "!commit or stash in $dir, then --apply $name"
  head_main="$(git -C "$dir" rev-parse -q --verify origin/main || true)"
  [ -n "$head_main" ] || { C "$name" "no origin/main ref in $dir"; return 0; }
  # Behind = origin/main is not contained in local-build. An upstream force-push leaves
  # no common history at all — that is behind too (rc 1), never a silent clean.
  rc=0; git -C "$dir" merge-base --is-ancestor "$head_main" local-build || rc=$?
  case "$rc" in
    0) : ;;
    1) F "$name" source-behind "--apply $name   # origin/main ${head_main:0:7} is not in local-build" ;;
    *) C "$name" "git merge-base failed in $dir (rc $rc) — cannot tell whether local-build is behind origin/main" ;;
  esac
  refs="$(git -C "$dir" for-each-ref --format='%(refname:short)' "refs/remotes/$FORK_REMOTE")" \
    || { C "$name" "git for-each-ref failed in $dir — fork branches not enumerated"; return 0; }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$FORK_REMOTE"/feat/*)   # enrolled: its tip must be in local-build, else --apply merges it
        rc=0; git -C "$dir" merge-base --is-ancestor "$ref" local-build || rc=$?
        case "$rc" in
          0) : ;;
          1) F "$name" source-behind "--apply $name   # $ref $(git -C "$dir" rev-parse --short "$ref") is not in local-build" ;;
          *) C "$name" "git merge-base failed for $ref (rc $rc) — cannot tell whether local-build carries it" ;;
        esac
        continue ;;
      "$FORK_REMOTE"|"$FORK_REMOTE"/HEAD|"$FORK_REMOTE"/main|"$FORK_REMOTE"/master) continue ;;
    esac
    rc=0; git -C "$dir" merge-base --is-ancestor "$ref" "$head_main" || rc=$?
    case "$rc" in
      0) continue ;;
      1) F "$name" unenrolled "!git -C $dir push $FORK_REMOTE --delete ${ref#"$FORK_REMOTE"/}   # or re-push as feat/<slug> to enroll" ;;
      *) C "$name" "git merge-base failed for $ref (rc $rc) — cannot tell whether it is merged" ;;
    esac
  done <<< "$refs"
  # The other direction: commits local-build carries that neither origin/main nor any live
  # fork/feat/* does (a feat/* deleted on the fork unmerged, or a hand commit) — the running
  # build has code nothing enrolls any more. --apply rebuilds without it (or refuses, naming it).
  local feats lost
  feats="$(git -C "$dir" for-each-ref --format='%(refname)' "refs/remotes/$FORK_REMOTE/feat")" \
    || { C "$name" "git for-each-ref failed in $dir — fork/feat/* not enumerated"; return 0; }
  # $feats unquoted on purpose: one ref per word (a refname cannot contain whitespace).
  # shellcheck disable=SC2086
  lost="$(git -C "$dir" rev-list --no-merges local-build --not "$head_main" $feats)" \
    || { C "$name" "git rev-list failed in $dir — cannot tell whether local-build carries unenrolled commits"; return 0; }
  # Commits made ON local-build (first-parent, non-merge) are what the engine refuses to drop:
  # the remedy is to move them, not --apply (which would refuse, every run under auto).
  local hand
  # shellcheck disable=SC2086
  hand="$(git -C "$dir" rev-list --first-parent --no-merges local-build --not "$head_main" $feats)" \
    || { C "$name" "git rev-list failed in $dir — cannot tell whether local-build carries hand commits"; return 0; }
  if [ -n "$hand" ]; then
    F "$name" unpushed "!move them to $FORK_REMOTE/feat/<slug>, or drop them: git -C $dir switch -C local-build origin/main — then --apply $name   # $(printf '%s\n' "$hand" | grep -c . || true) commit(s) on local-build outside origin/main and $FORK_REMOTE/feat/* (a hand commit, or upstream rewrote main); --apply refuses to drop them"
  elif [ -n "$lost" ]; then F "$name" source-behind "--apply $name   # local-build carries $(printf '%s\n' "$lost" | grep -c . || true) commit(s) in neither origin/main nor any live $FORK_REMOTE/feat/* (a feature branch deleted on the fork?) — --apply rebuilds without them"; fi
  return 0
}

check_checkout(){
  local name="$1" l="$2" dir sub branch entry cur built up behind ahead tb th dirty
  dir="$(mcp_root "$l")"; case "$dir" in INVALID:*) C "$name" "${dir#INVALID:}"; return 0 ;; esac
  sub="$(mcp_sub "$l")"
  branch="$(mcp_get "$l" branch)"; case "$branch" in INVALID:*) C "$name" "${branch#INVALID:}"; return 0 ;; esac
  entry="$(entry_of "$l")"
  [ -d "$dir" ] || { F "$name" missing "--apply $name   # or just launch it: the launcher lazy-installs"; return 0; }
  [ -d "$dir/.git" ] || { C "$name" "$dir exists but is not a git checkout"; return 0; }
  check_origin "$name" "$l" "$dir"
  cur="$(git -C "$dir" symbolic-ref -q --short HEAD || echo DETACHED)"
  [ "$cur" = "$branch" ] || F "$name" off-branch "!git -C $dir switch $branch   # the build tracks $branch; HEAD is $cur — or, if that's intentional, set $name.branch=$cur in $MCP_CONFIG_FILE"
  stranded_build "$name" "$(pkgdir "$l")" "$dir"
  local bak=.dist.bak; [ "$sub" = . ] || bak="$sub/.dist.bak"
  dirty="$(git -C "$dir" status --porcelain -- "$sub" ":(exclude)$bak")" || { C "$name" "git status failed in $dir"; return 0; }
  [ -z "$dirty" ] || F "$name" dirty-tree "!commit or stash in $(pkgdir "$l"), then --apply $name"
  up="$(git -C "$dir" rev-parse -q --verify "origin/$branch" || true)"
  if [ -z "$up" ]; then C "$name" "no origin/$branch ref in $dir"; else
    behind="$(git -C "$dir" rev-list --count "HEAD..origin/$branch" -- "$sub")" || { C "$name" "rev-list failed"; return 0; }
    ahead="$(git -C "$dir" rev-list --count "origin/$branch..HEAD" -- "$sub")"   || { C "$name" "rev-list failed"; return 0; }
    [ "$behind" -eq 0 ] || F "$name" source-behind "--apply $name   # $behind commit(s) on origin/$branch touch $sub"
    [ "$ahead"  -eq 0 ] || F "$name" unpushed "!git -C $dir push   # $ahead local commit(s) touch $sub (runs only on this machine)"
  fi
  [ -f "$entry" ] || { F "$name" no-dist "--apply $name"; return 0; }
  built="$(cat "$(pkgdir "$l")/dist/.built-from" 2>/dev/null || true)"
  if [ -z "$built" ] || ! git -C "$dir" cat-file -e "$built^{commit}" 2>/dev/null; then
    F "$name" unproven-build "--apply $name   # dist has no provenance marker; rebuild records one"
    return 0
  fi
  # Compare the package's SOURCE TREE, not the commit (sibling commits in a monorepo must not
  # make a package look stale). rev-parse echoes its arg on failure: never chain `a || b` in $().
  local tspec=":$sub"; [ "$sub" = . ] && tspec="^{tree}"
  tb="$(git -C "$dir" rev-parse -q --verify "$built$tspec")" || { C "$name" "cannot resolve $sub at ${built:0:7}"; return 0; }
  th="$(git -C "$dir" rev-parse -q --verify "HEAD$tspec")"   || { C "$name" "cannot resolve $sub at HEAD"; return 0; }
  [ "$tb" = "$th" ] || F "$name" dist-stale "--apply $name   # built from ${built:0:7}; $sub source differs at HEAD"
  return 0
}

check_npm(){
  local name="$1" l="$2" pkg src sub applied_ver latest githead changed
  pkg="$(decl_get "$l" pkg)"
  [ -n "$pkg" ] || { F "$name" bad-declaration "!shape=npm needs pkg= in $(basename "$l")"; return 0; }
  applied_ver="$(cat "$STATE/$name.applied" 2>/dev/null || true)"
  [ -n "$applied_ver" ] || F "$name" unpinned "--apply $name   # no applied version recorded — the launcher floats to latest"
  if [ "$NETWORK" -eq 1 ]; then
    latest="$("$NPM" view "$pkg" version 2>/dev/null)" || { C "$name" "npm registry lookup failed for $pkg"; latest=""; }
    if [ -n "$latest" ] && [ -n "$applied_ver" ] && [ "$latest" != "$applied_ver" ]; then
      F "$name" update-available "--apply $name   # $applied_ver -> $latest"
    fi
  else
    V deferred "$name: registry comparison (--full only)"
  fi
  check_stale "$name" "$l" npm "$applied_ver"
  sub="$(mcp_sub "$l")"
  # No src= declared at all is the common, valid "consume-only" case (most npm
  # MCPs have no publisher checkout on this machine) — resolve through mcp_get
  # ONLY when src= is actually declared, so a config problem (bad root=/.dir=)
  # surfaces as CANNOT-CHECK instead of being folded into the same "consume-only".
  if [ -z "$(decl_get "$l" src)" ]; then V consume-only "$name"; return 0; fi
  src="$(mcp_get "$l" src)"; case "$src" in INVALID:*) C "$name" "${src#INVALID:}"; return 0 ;; esac
  if [ ! -d "$src/.git" ]; then V consume-only "$name"; return 0; fi
  [ "$NETWORK" -eq 1 ] || { V deferred "$name: publish-lag (--full only)"; return 0; }
  githead="$("$NPM" view "$pkg" gitHead 2>/dev/null)" || { C "$name" "npm view gitHead failed for $pkg"; return 0; }
  [ -n "$githead" ] || { C "$name" "$pkg published without gitHead — cannot prove publish currency"; return 0; }
  git -C "$src" cat-file -e "$githead^{commit}" 2>/dev/null \
    || { C "$name" "published gitHead ${githead:0:7} not in $src (fetch?)"; return 0; }
  changed="$(git -C "$src" diff --name-only "$githead" HEAD -- "$sub/src" "$sub/package.json" "$sub/tsconfig.json")" \
    || { C "$name" "git diff failed in $src"; return 0; }
  if [ -n "$changed" ]; then
    F "$name" publish-lag "!bump + npm publish from $src/$sub (public — your go)   # $(printf '%s\n' "$changed" | grep -c . || true) input file(s) changed since published ${githead:0:7}"
  fi
  return 0
}

# check_other_channel <name> <launcher> <channel> : processes still running the OTHER channel
# (a switch takes effect only at restart). stable -> look for node on the canary entry;
# canary -> look for npx installs of pkg.
check_other_channel(){
  local name="$1" l="$2" ch="$3" out seen other
  if [ "$ch" = stable ]; then
    [ -n "$(decl_get "$l" src)" ] || return 0   # literal presence check only — no path resolution needed here
    other=canary; out="$(stale_scan dist "$(mcp_entry "$l")" /nonexistent)" || { C "$name" "ps failed — cannot tell which channel open sessions run"; return 0; }
  else
    other=stable; out="$(stale_scan npx "$(decl_get "$l" pkg)" "")" || { C "$name" "ps failed — cannot tell which channel open sessions run"; return 0; }
  fi
  local stale unparsed
  read -r seen stale unparsed <<< "$out"
  [ -n "${unparsed:-}" ] || { C "$name" "process scan produced no result"; return 0; }
  [ "$unparsed" -eq 0 ] || { C "$name" "$unparsed ps line(s) in an unrecognised format (locale?) — cannot tell which channel open sessions run"; return 0; }
  [ "$seen" -eq 0 ] || F "$name" stale-process "!restart Claude Code to apply — $seen running process(es) still on the $other channel (channel is now $ch)"
  return 0
}

# unreleased_info <name> <launcher> : canary only — commits touching <sub> since the published
# gitHead. INFO by design (running ahead of npm is the point of canary): never a finding.
unreleased_info(){
  local name="$1" l="$2" pkg src sub gh ver n
  [ "$NETWORK" -eq 1 ] || { V deferred "$name: unreleased-vs-npm info (--full only)"; return 0; }
  pkg="$(decl_get "$l" pkg)"; src="$(mcp_root "$l")"; sub="$(mcp_sub "$l")"
  [ -d "$src/.git" ] || return 0
  ver="$("$NPM" view "$pkg" version 2>/dev/null || true)"; gh="$("$NPM" view "$pkg" gitHead 2>/dev/null || true)"
  if [ -z "$gh" ] || ! git -C "$src" cat-file -e "$gh^{commit}" 2>/dev/null; then
    I "$name" "unreleased vs npm: unknown (published gitHead ${gh:-?} not resolvable in $src)"; return 0
  fi
  n="$(git -C "$src" rev-list --count "$gh..HEAD" -- "$sub" 2>/dev/null)" || { I "$name" "unreleased vs npm: unknown (rev-list failed)"; return 0; }
  I "$name" "unreleased vs npm: $n commit(s) touch $sub since published ${ver:-?} (${gh:0:7})"
}

suggest_for(){  # $1=command $2=args -> a proposed declaration line (inference; a proposal only)
  local cmd="$1" args="$2" p top rel root relpath
  case "$cmd" in
    npx|*/npx) printf '# openbrain-mcp: shape=npm pkg=%s' "$(printf '%s' "$args" | tr ' ' '\n' | grep -m1 '^@\|^[a-z]' || true)"; return ;;
  esac
  root="$(_mcp_root_dir 2>/dev/null || true)"; case "$root" in INVALID:*) root="" ;; esac
  while IFS= read -r p; do
    case "$p" in /*.js)
      top="$(git -C "$(dirname "$p")" rev-parse --show-toplevel 2>/dev/null || true)"
      if [ -n "$top" ]; then
        rel="${p#"$top"/}"
        # Relative dir= (the tracked norm) when the checkout lives under root=;
        # otherwise an absolute (tilde-form) escape hatch, same as a declaration allows.
        if [ -n "$root" ] && [ "${top#"$root"/}" != "$top" ]; then relpath="${top#"$root"/}"
        else relpath="${top/#$HOME/~}"; fi
        printf '# openbrain-mcp: shape=checkout dir=%s sub=%s url=%s' "$relpath" "${rel%/dist/*}" \
          "$(git -C "$top" remote get-url origin 2>/dev/null || echo '?')"
        return
      fi ;;
    esac
  done < <(printf '%s %s\n' "$cmd" "$args" | tr ' ' '\n')
  printf 'no suggestion — write the declaration by hand'
}

# undeclared_remedy <name> <installed-launcher> : the fix for an installed launcher with no
# declaration. The installed copy is a deploy target — any hand edit there is overwritten by
# the next redeploy — so the remedy is always a redeploy, after fixing the TRACKED source
# when that is what lacks the line.
undeclared_remedy(){
  local name="$1" f="$2" tracked="$VAULT/.openbrain/lib/$1.sh" redeploy
  redeploy="bash $VAULT/.openbrain/lib/reconcile-runtime.sh --apply"
  if [ -f "$tracked" ] && [ "$(decl_count "$tracked")" = 1 ]; then
    printf "redeploy — the vault's %s carries a declaration this installed copy predates: %s" "$name.sh" "$redeploy"
  elif [ -f "$tracked" ]; then
    printf "add one '# openbrain-mcp: shape=...' line to the tracked launcher %s (grammar: _mcp-decl.sh), then redeploy: %s" "$tracked" "$redeploy"
  else
    printf "%s has no tracked source in %s — add it there with one '# openbrain-mcp: shape=...' line, then redeploy: %s (a hand edit to the installed copy is overwritten by the next redeploy)" "$f" "$VAULT/.openbrain/lib" "$redeploy"
  fi
}

# ---------------------------------------------------------------------------
all_findings(){
  local f name n_l=0 n_decl=0 n_reg=0 n_other=0 key cmd args typ prog d dir sub i mode eshape
  local -a NAMES=() LAUNCHERS=()
  while IFS= read -r f; do
    [ -n "$f" ] && F "-" bad-policy "!fix $MCP_CONFIG_FILE — $f"
  done <<< "$(mcp_policy_lint "$LIB")"
  # 1. declarations
  for f in "$LIB"/*-mcp.sh; do
    [ -e "$f" ] || continue
    n_l=$((n_l+1)); name="$(basename "$f" .sh)"
    case "$(decl_count "$f")" in
      1) case "$(decl_get "$f" shape)" in
           fork|checkout|npm) n_decl=$((n_decl+1)); NAMES+=("$name"); LAUNCHERS+=("$f")
             case "$(decl_get "$f" entry)" in ""|dist/*) ;; *) F "$name" bad-declaration "!entry=$(decl_get "$f" entry) in $f — entry must be under dist/ (the engine backs up, checks and stamps dist/ only)" ;; esac ;;
           *) F "$name" bad-declaration "!unknown shape '$(decl_get "$f" shape)' in $f" ;;
         esac ;;
      0) F "$name" undeclared "!$(undeclared_remedy "$name" "$f")" ;;
      *) F "$name" bad-declaration "!more than one '# openbrain-mcp:' line in $f" ;;
    esac
  done
  V launchers "$n_l in $LIB ($n_decl declared)"
  if [ "$n_l" -eq 0 ]; then C "-" "zero *-mcp.sh launchers in $LIB — nothing to check is not a clean result"; return 0; fi

  # 2. reconcile the live registry against declarations
  local regs used=" "
  local inlib
  regs="$(registered 2>/dev/null)" || { C "-" "cannot read/parse $CLAUDE_JSON — registry reconciliation skipped"; regs=""; }
  # \x1f, not TAB: TAB is IFS-whitespace, so an EMPTY args field would collapse and shift fields.
  while IFS=$'\x1f' read -r key cmd args typ inlib; do
    [ -n "$key" ] || continue
    if [ "$typ" != "stdio" ]; then n_other=$((n_other+1)); continue; fi
    n_reg=$((n_reg+1)); prog=""
    [ "$inlib" != 1 ] || prog="$(basename "$cmd" .sh)"
    if [ -n "$prog" ]; then
      if [ ! -e "$LIB/$prog.sh" ]; then F "$key" dangling-registration "!$cmd does not exist — re-run bootstrap/lib/register-mcps.sh"; continue; fi
      used="$used$prog "; continue
    fi
    for i in "${!NAMES[@]}"; do
      d="$(mcp_eff_shape "${LAUNCHERS[$i]}")"; [ "$d" = checkout ] || [ "$d" = fork ] || continue
      dir="$(pkgdir "${LAUNCHERS[$i]}")"
      case " $cmd $args " in *" $dir/"*) prog="${NAMES[$i]}"; break ;; esac
    done
    if [ -n "$prog" ]; then
      used="$used$prog "
      F "$key" bypasses-launcher "!re-register: claude mcp add -s user $key -- $REG_LIB/$prog.sh <args>   # today: $cmd $args"
      continue
    fi
    F "$key" undeclared-server "!$(suggest_for "$cmd" "$args")   # registered as: $cmd $args"
  done <<< "$regs"
  V registered "$n_reg stdio server(s)$( [ "$n_other" -eq 0 ] || printf ', %s non-stdio skipped' "$n_other") — from $CLAUDE_JSON (user scope + this vault's project entry)"

  # 3. per-shape checks for every declared program something actually runs
  local n_checked=0 idle="" pols="" chans="" ch
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    case "$used" in *" $name "*) ;; *) idle="$idle $name"; continue ;; esac
    n_checked=$((n_checked+1))
    mode="$(mcp_update_mode "${LAUNCHERS[$i]}")"
    case "$mode" in INVALID:*) C "$name" "${mode#INVALID:} — the launcher refuses to start this server"; mode=invalid ;; esac
    [ -z "$(decl_get "${LAUNCHERS[$i]}" update)" ] \
      || F "$name" bad-declaration "!remove update= from the declaration in $(basename "${LAUNCHERS[$i]}") — policy is per machine: $name.update=auto|ask in $MCP_CONFIG_FILE"
    pols="$pols $name=$mode"
    # Dispatch on the EFFECTIVE (resolved) shape, never the raw tracked literal —
    # a tracked shape=checkout with a resolved .fork= differing from origin must
    # route to check_fork (local-build/feat/enrollment checks), not check_checkout.
    eshape="$(mcp_shape "${LAUNCHERS[$i]}")"
    case "$eshape" in
      INVALID:*) C "$name" "${eshape#INVALID:} — cannot determine effective shape"; continue ;;
    esac
    case "$eshape" in
      fork)     check_fork     "$name" "${LAUNCHERS[$i]}"; check_stale "$name" "${LAUNCHERS[$i]}" fork ;;
      checkout) check_checkout "$name" "${LAUNCHERS[$i]}"; check_stale "$name" "${LAUNCHERS[$i]}" checkout ;;
      npm)
        ch="$(mcp_channel "${LAUNCHERS[$i]}")"; chans="$chans $name=${ch%%:*}"
        case "$ch" in
          stable) check_npm "$name" "${LAUNCHERS[$i]}" "$mode"; check_other_channel "$name" "${LAUNCHERS[$i]}" stable ;;
          canary) check_checkout "$name" "${LAUNCHERS[$i]}"; check_stale "$name" "${LAUNCHERS[$i]}" checkout
                  check_other_channel "$name" "${LAUNCHERS[$i]}" canary; unreleased_info "$name" "${LAUNCHERS[$i]}" ;;
          *)      C "$name" "${ch#INVALID:} — the launcher refuses to start this server" ;;
        esac ;;
    esac
  done
  V checked "$n_checked program(s)"
  [ -z "$chans" ] || V channel "${chans# }"
  V policy "$( [ -f "$MCP_CONFIG_FILE" ] && printf '%s' "$MCP_CONFIG_FILE" || printf 'no policy file — all ask');${pols}"
  [ -z "$idle" ] || V "declared-not-registered" "${idle# }"
  if [ -n "$regs" ] && [ "$n_reg" -gt 0 ] && [ "$n_checked" -eq 0 ]; then
    C "-" "$n_reg registered server(s) but none resolved to a declared launcher — if the vault was just pulled, redeploy first: bash $VAULT/.openbrain/lib/reconcile-runtime.sh --apply"
  fi
  return 0
}

fetch_all(){
  local f dir shape
  [ "$NO_FETCH" = 1 ] && { printf 'cov\tfetch\tskipped (MCP_NO_FETCH=1) — comparing cached refs\n'; return 0; }
  for f in "$LIB"/*-mcp.sh; do
    [ -e "$f" ] && [ "$(decl_count "$f")" = 1 ] || continue
    shape="$(mcp_eff_shape "$f")"; dir="$(mcp_root "$f")"      # npm on canary = checkout
    case "$shape" in fork|checkout) ;; *) continue ;; esac
    [ -d "$dir/.git" ] || continue
    git -C "$dir" fetch -q origin 2>/dev/null || C "$(basename "$f" .sh)" "origin fetch failed — compared CACHED refs"
    if [ "$shape" = fork ] && [ "$(git -C "$dir" remote | grep -c "^${FORK_REMOTE}$" || true)" -gt 0 ]; then
      git -C "$dir" fetch -q --prune "$FORK_REMOTE" 2>/dev/null || C "$(basename "$f" .sh)" "$FORK_REMOTE fetch failed — compared CACHED refs"   # --prune: a branch deleted on the fork must stop being reported
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# apply (explicit --apply, and --full's auto pass)
# ---------------------------------------------------------------------------
applog(){ mkdir -p "$STATE"; printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" "$4" >> "$STATE/applied.log"; }

# run_engine <name> <launcher> : the engine takes the build lock itself and holds it for
# the whole build (this script never holds it around the engine).
run_engine(){
  local l="$2" dir url branch fork
  dir="$(mcp_root "$l")"
  case "$(mcp_eff_shape "$l")" in          # npm on the canary channel builds as a checkout
    fork)
      # the shared prepare step: clone if missing, add the fork remote a fresh <l>.fork= names
      url="$(mcp_get "$l" url)"; fork="$(mcp_get "$l" fork)"
      ( _mcp_prepare_checkout "$l" fork "$dir" "$url" "" "$fork" ) || { log "could not clone $dir or add its '$FORK_REMOTE' remote"; return 1; }
      bash "$APPLY_SH" "$l" ;;             # launcher PATH — the engine resolves dir= through mcp_get itself
    checkout)
      branch="$(mcp_get "$l" branch)"; case "$branch" in INVALID:*) log "${branch#INVALID:}"; return 1 ;; esac
      if [ ! -d "$dir/.git" ]; then
        url="$(mcp_get "$l" url)"; case "$url" in INVALID:*|"") log "no usable url= to clone $dir from"; return 1 ;; esac
        # the shared first-clone step (lock for the clone only; temp dir + mv): a killed
        # clone never leaves a partial checkout
        ( _mcp_prepare_checkout "$l" checkout "$dir" "$url" "$branch" "" ) || { log "clone failed"; return 1; }
      fi
      bash "$APPLY_SH" --checkout "$1" "$dir" "$(mcp_sub "$l")" "$branch" "$(mcp_get "$l" entry)" ;;
  esac
}

# apply_one <name> <launcher> <how> : the one apply path (how = explicit | auto, for the log).
# The engine's tests gate the build and keep the last-good dist on failure.
# Emits one `act` line: applied | failed.
apply_one(){
  local name="$1" l="$2" how="$3" pkg old new dir why
  pkg="$(pkgdir "$l")"
  case "$(mcp_eff_shape "$l")" in
    npm)     apply_npm "$name" "$l" "$how"; return 0 ;;
    invalid) why="$(_mcp_build_shape "$l")"; printf 'act\t%s\tfailed\t%s\n' "$name" "${why#INVALID:}"; return 0 ;;
  esac
  dir="$(mcp_root "$l")"; case "$dir" in INVALID:*) printf 'act\t%s\tfailed\t%s\n' "$name" "${dir#INVALID:}"; return 0 ;; esac
  old="$(cat "$pkg/dist/.built-from" 2>/dev/null || true)"
  if ! run_engine "$name" "$l" >&2; then
    printf 'act\t%s\tfailed\tengine refused, could not take the build lock, or build/tests failed — last-good build still in place (see output above)\n' "$name"
    applog "$name" "$how" "failed" "${old:0:7}"; return 0
  fi
  new="$(cat "$pkg/dist/.built-from" 2>/dev/null || true)"; [ -n "$old" ] || old="none"
  applog "$name" "$how" "applied" "${old:0:7} -> ${new:0:7}"
  printf 'act\t%s\tapplied\t%s -> %s — %s\n' "$name" "${old:0:7}" "${new:0:7}" "$RESTART_MSG"
}

apply_npm(){  # record the latest publish as the applied version; the launcher pins to it (no test gate)
  local name="$1" l="$2" pkg latest prev
  pkg="$(decl_get "$l" pkg)"
  latest="$("$NPM" view "$pkg" version 2>/dev/null)" || { printf 'act\t%s\tfailed\tnpm registry lookup failed for %s\n' "$name" "$pkg"; return 0; }
  mkdir -p "$STATE"
  prev="$(cat "$STATE/$name.applied" 2>/dev/null || true)"
  printf '%s\n' "$latest" > "$STATE/$name.applied"
  applog "$name" "$3" "applied" "${prev:-unpinned} -> $latest"
  printf 'act\t%s\tapplied\tpinned %s (was %s) — %s\n' "$name" "$latest" "${prev:-unpinned}" "$RESTART_MSG"
}

# auto_apply <findings-stream> : --full's policy pass — every MCP whose mode is auto
auto_apply(){
  local s="$1" name l classes
  for l in "$LIB"/*-mcp.sh; do
    [ -e "$l" ] && [ "$(decl_count "$l")" = 1 ] || continue
    name="$(basename "$l" .sh)"
    [ "$(mcp_update_mode "$l")" = auto ] && [ "$(mcp_eff_shape "$l")" != invalid ] || continue
    classes="$(printf '%s\n' "$s" | awk -F'\t' -v n="$name" '$1=="mcp" && $2==n {print $3}' | sort -u | tr '\n' ' ')"
    case " $classes " in *" dist-stale "*|*" source-behind "*|*" no-dist "*|*" unproven-build "*|*" no-local-build "*|*" missing "*|*" update-available "*|*" unpinned "*|*" stranded-build "*) ;; *) continue ;; esac
    case " $classes " in *" dirty-tree "*|*" off-branch "*|*" unpushed "*|*" shape-mismatch "*|*" bad-declaration "*|*" unenrolled "*|*" fork-mismatch "*|*" origin-mismatch "*|*" unsupported-key "*)
      printf 'act\t%s\theld\tnot auto-applied: %s— resolve by hand first\n' "$name" "$classes"; continue ;; esac
    [ "$(mcp_eff_shape "$l")" = fork ] && [ "$(printf '%s' "$classes" | grep -c 'missing' || true)" -gt 0 ] && continue
    apply_one "$name" "$l" auto
  done
  return 0
}

outcome(){  # stdin = findings stream -> exit code (here-strings: `printf | grep -q` can SIGPIPE under pipefail)
  local s; s="$(cat)"
  if grep -q '^cannot' <<< "$s"; then return 20; fi
  if grep -q '^mcp'    <<< "$s"; then return 10; fi
  return 0
}

report(){  # $1 = findings stream, $2 = auto-apply stream (optional)
  local s="$1" a="${2:-}" rc=0
  printf '%s\n' "$s" | outcome || rc=$?
  printf 'Brain update status — MCP servers\n\n'
  if [ -n "$a" ]; then
    printf 'Auto-updates (policy):\n'
    printf '%s\n' "$a" | awk -F'\t' '$1=="act"{printf "  %s %-20s %s\n", ($3=="applied"?"\342\234\223":($3=="held"?"\342\217\270":"\342\234\227")), $2, $3 ": " $4}'
    printf '\n'
  fi
  printf '%s\n' "$s" | awk -F'\t' '
    $1=="mcp"   { cmd=$4; if (substr(cmd,1,1)=="!") sub(/^!/,"",cmd); else cmd="check-updates.sh " cmd;
                  printf "  \342\232\240 %-22s %-18s -> %s\n",$2,$3,cmd }
    $1=="cannot"{ printf "  ? CANNOT-CHECK %-14s %s\n",$2,$3 }'
  if grep -q '^info' <<< "$s"; then
    printf '\nInfo (not findings):\n'
    printf '%s\n' "$s" | awk -F'\t' '$1=="info"{printf "  i %-22s %s\n",$2,$3}'
  fi
  printf '\nCoverage:\n'
  printf '%s\n' "$s" | awk -F'\t' '$1=="cov"{printf "  %-24s %s\n",$2,$3}'
  case "$rc" in
    0)  printf '\nRESULT: CLEAN\n' ;;
    10) printf '\nRESULT: FINDINGS\n' ;;
    20) printf '\nRESULT: CANNOT-CHECK — this is not a clean bill; see ? lines\n' ;;
  esac
  if [ -n "$a" ] && grep -q $'\tapplied\t' <<< "$a"; then printf '%s\n' "$RESTART_MSG"; fi
  return "$rc"
}

# sig : the snooze signature — FINDINGS only. CANNOT-CHECK never snoozes (see --check), and
# leaving it out here means snoozed findings stay snoozed when a CANNOT-CHECK clears.
sig(){ printf '%s\n' "$1" | awk '!/^(cov|info|cannot)\t/' | sort | shasum | awk '{print $1}'; }   # awk, not grep -v: an empty result must not fail under pipefail

need_launcher(){  # need_launcher <mcp> -> sets L
  L="$LIB/$1.sh"
  [ -f "$L" ] && [ "$(decl_count "$L")" = 1 ] || { log "$1: no declared launcher at $L"; exit 2; }
}

mode="${1:-}"
case "$mode" in
  --check)
    s="$(all_findings)"; rc=0; printf '%s\n' "$s" | outcome || rc=$?
    [ "$rc" -ne 0 ] || exit 0
    # Only FINDINGS are snoozable; CANNOT-CHECK (rc 20) is missing evidence and always reports.
    if [ "$rc" -eq 10 ] && [ -f "$SNOOZE_FILE" ] && [ "$(cat "$SNOOZE_FILE")" = "$(sig "$s")" ]; then exit 0; fi
    n="$(printf '%s\n' "$s" | grep -c '^mcp' || true)"; c="$(printf '%s\n' "$s" | grep -c '^cannot' || true)"
    printf 'OpenBrain: MCP updates — %s finding(s), %s cannot-check. /brain-update-check for details.\n' "$n" "$c"
    exit "$rc" ;;
  --full|--report)
    NETWORK=1; log "(fetching MCP checkouts + consulting npm ...)"
    fetched="$(fetch_all)"
    s="$( { printf '%s\n' "$fetched"; all_findings; } )"
    a=""
    if [ "$mode" = --full ]; then
      a="$(auto_apply "$s")"
      if [ -n "$a" ]; then s="$( { printf '%s\n' "$fetched"; all_findings; } )"; fi   # re-check after applying
    fi
    report "$s" "$a" ;;
  --raw)            # machine-readable stream (tests); honours MCP_NETWORK=1
    NETWORK="${MCP_NETWORK:-0}"; s="$(all_findings)"; printf '%s\n' "$s"; printf '%s\n' "$s" | outcome ;;
  --auto-raw)       # tests: policy pass without fetch; prints act lines then the re-check stream
    NETWORK="${MCP_NETWORK:-0}"; s="$(all_findings)"; a="$(auto_apply "$s")"
    printf '%s\n' "$a"; s="$(all_findings)"; printf '%s\n' "$s"; printf '%s\n' "$s" | outcome ;;
  --apply)
    target="${2:?usage: check-updates.sh --apply <mcp>}"; need_launcher "$target"
    a="$(apply_one "$target" "$L" explicit)"
    printf '%s\n' "$a" | awk -F'\t' '{print $2": "$3" — "$4}'
    grep -q $'\tapplied\t' <<< "$a" ;;
  --snooze)
    s="$(all_findings)"; mkdir -p "$(dirname "$SNOOZE_FILE")"; sig "$s" > "$SNOOZE_FILE"
    log "snoozed — --check stays quiet until the set of pending findings changes."
    c="$(printf '%s\n' "$s" | grep -c '^cannot' || true)"
    [ "$c" -eq 0 ] || log "note: $c CANNOT-CHECK line(s) are never snoozed — --check keeps reporting them until the evidence can be gathered." ;;
  *)
    printf 'usage: %s {--check | --full | --report | --apply <mcp> | --snooze}\n' "${0##*/}" >&2
    exit 2 ;;
esac
