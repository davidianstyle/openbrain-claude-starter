#!/usr/bin/env bash
# _mcp-decl.sh — the ONE parser for a launcher's declaration line, the ONE
# resolver for its per-machine overrides + update policy, and the ONE install
# path (ensure_mcp_server). One sourcing rule, no fallback chains, by LOCATION
# of the sourcing script — never by which task it's doing:
#   - Every .openbrain/lib/*.sh script (check-updates.sh, reconcile-runtime.sh,
#     mcp-local-build.sh, and _common.sh itself) sources the copy BESIDE ITSELF
#     ($(dirname "${BASH_SOURCE[0]}")/_mcp-decl.sh). In the vault that's the
#     vault's own copy; in an installed runtime (a launcher's lazy build, or
#     the installed mcp-local-build.sh a launcher execs) that's the installed
#     copy — each context loads its own, consistent copy, never the other
#     tree's. (mcp-local-build.sh takes a LAUNCHER PATH as an argument but
#     must still load the parser beside ITSELF, not beside that launcher —
#     otherwise a vault run asked to build an installed launcher would load a
#     stale installed parser and die with a bare `mcp_get: command not found`.)
#   - bootstrap/lib/* (common.sh's source_mcp_decl, validate.sh, add-*.sh)
#     always use the INSTALLED copy ($LIB_DIR/_mcp-decl.sh) — they configure
#     the runtime, so they source what the runtime will actually run.
#
# Every *-mcp.sh launcher carries exactly one line of the form
#   # openbrain-mcp: shape=<fork|checkout|npm> key=value ...
# Keys:
#   shape  fork     — always hand-managed; runs <dir>/dist from local-build
#          checkout — a git checkout that runs <dir>/<sub>/dist built from its own HEAD.
#                     Tracked declarations use checkout even for hand-managed MCPs —
#                     the per-machine .fork= override upgrades the EFFECTIVE shape to
#                     fork (mcp_shape below), so the tracked file carries the upstream
#                     default and the fork lives in mcp-config.
#          npm      — a published package launched via npx
#   dir    checkout root (fork|checkout), RELATIVE to root= (mcp-config) unless it
#          starts with / or ~ (an absolute escape hatch)        sub  package subdir (default .)
#   branch branch the build tracks (default main); <l>.branch= overrides per machine
#   entry  built entrypoint relative to dir/sub (default dist/index.js)
#   pkg    npm package name (npm)
#   src    npm: the package's source checkout (same relative-to-root rule as dir=).
#          stable channel: OPTIONAL publisher checkout (enables publish-lag; absent =
#          consume-only). canary channel: REQUIRED — the checkout the server runs
#          from (<src>/<sub>/<entry>), lazily cloned from url=.
#   url    clone URL (fork|checkout|npm-canary) — used by the lazy first-launch
#          clone AND (unless owner=/.url= override it) as the origin every checker
#          compares against. https://…, git@host:path, or file:///abs/path to a
#          local repo. Whatever it names must be a git repo with the code
#          committed: the dist/.built-from provenance stamp is the source's HEAD
#          sha, and staleness, update and revert are all keyed on commits — a
#          plain folder would build once and could never be checked again.
# A leading ~ in any value expands to $HOME. (Update policy is NOT on this line: it is
# per machine, below. A leftover update= here is a bad-declaration, never silently used.)
#
# Per-machine config file ~/.config/openbrain/mcp-config (outside every repo; the only
# file read for these keys) — one grammar, `key=value` lines, `#` comments.
# Leading/trailing whitespace on a line is trimmed; whitespace INSIDE a value is kept
# (a path or URL may legitimately contain none today, but the parser doesn't assume
# that); whitespace followed by # starts an inline comment, stripped with the
# whitespace before it. A line for a key written any other way than `key=value`
# (`root = /x`, `root /x`, `root= /x`, `root: /x`) is invalid, never skipped.
# A leading ~ in a value expands to $HOME.
#
# Machine-wide keys:
#   root=<path>                    MCP source root (default ~/Code). Must be absolute
#                                  when present — an empty root= is invalid, not "unset".
#   owner=<github-user>            re-parent every declared github.com/<owner>/<repo>
#                                  URL to this owner. No env-var fallback — a bare
#                                  OPENBRAIN_MCP_REPO_OWNER is never read.
#   channel=stable|canary          machine default for every npm MCP (absent -> stable)
# Per-MCP keys (<launcher-basename-without-.sh>.<key>=):
#   <l>.url=<url>                  re-parented origin for this one MCP (overrides owner=)
#   <l>.fork=<url>                 contributing fork remote; effective shape becomes
#                                  fork UNLESS this equals the resolved origin
#                                  (URL-normalized) — that's re-parented, not a fork,
#                                  and is reported as a redundant line, never an error.
#   <l>.dir=<path>                 one-off location (covers src= for npm shapes too).
#                                  Must be an absolute path — machine overrides are
#                                  one-off locations, never relative to anything.
#   <l>.branch=<branch>            override the branch the build tracks (default main;
#                                  offered as the fix for an intentional off-branch checkout)
#   <l>.update=auto|ask            absent -> ask
#     ask  — the checker reports; /brain-update-check offers --apply on the user's go
#     auto — check-updates.sh --full applies it when the engine's test gate passes (last-good
#            dist kept on failure, "restart Claude Code to apply").
#            Plain npm (stable channel) has no test gate: auto records the latest publish.
#   <l>.channel=stable|canary      per-MCP channel override
#     stable — the published package via npx, pinned to the last-applied version
#     canary — run from the source checkout on <branch>: <src>/<sub>/<entry>,
#              built by ensure_mcp_server / mcp-local-build.sh --checkout (tests gate,
#              last-good dist, provenance)
# A duplicate key is always invalid. An EMPTY value for root=, owner=, <l>.dir=,
# <l>.url=, <l>.fork=, channel=, <l>.channel= or <l>.update= is invalid too — "the key is present but blank" is a
# typo/mistake, not "the key is absent" (which legitimately means "use the
# default"). Neither case is ever passed through as a path — the launcher stops
# (or the checker reports CANNOT-CHECK), never silently defaulted.
# Switching = edit the file + restart Claude Code (launchers read it at launch).
MCP_CONFIG_FILE="${MCP_CONFIG_FILE:-${OPENBRAIN_CONFIG_DIR:-$HOME/.config/openbrain}/mcp-config}"
MCP_UPDATE_STATE="${MCP_UPDATE_STATE:-$HOME/.config/openbrain/mcp-updates}"

# die(): defined here ONLY if the caller hasn't already (bootstrap/lib/common.sh and
# the launcher-side _common.sh both define a compatible one). _mcp-decl.sh must work
# when sourced standalone too (check-updates.sh has no die of its own).
if ! declare -F die >/dev/null 2>&1; then
  die(){ printf 'openbrain mcp: %s\n' "$*" >&2; exit 1; }
fi

# decl_count <launcher>  -> number of declaration lines (must be exactly 1)
decl_count(){ grep -c '^# openbrain-mcp:' "$1" 2>/dev/null || true; }

# decl_get <launcher> <key> [default]  — the LITERAL declared value (never resolved
# against root=/owner=; callers that need the resolved answer use mcp_get).
decl_get(){
  local line kv v
  local -a kvs
  line="$(grep -m1 '^# openbrain-mcp:' "$1" 2>/dev/null || true)"
  read -r -a kvs <<< "${line#*openbrain-mcp:}"
  for kv in "${kvs[@]+"${kvs[@]}"}"; do
    case "$kv" in
      "$2="*) v="${kv#*=}"; printf '%s' "${v/#\~/$HOME}"; return 0 ;;
    esac
  done
  printf '%s' "${3:-}"
}

# --- mcp-config parsing --------------------------------------------------------
# _kv_get <file> <key> -> prints the value (leading ~ expanded; may be an empty
# string when the key is present but blank) and returns:
#   0  found exactly once
#   1  key not present at all (nothing printed)
#   2  invalid — a duplicate, or a line for <key> not written as `key=value` (spaces
#      around =, no =); the reason is printed, callers wrap it as INVALID:<reason>
# Only leading/trailing whitespace on the LINE is trimmed; whitespace inside the
# value survives. `#`-prefixed (after trim) lines are comments, and a value's
# inline comment (whitespace, then #) is stripped. Distinguishing
# "absent" (1, -> apply the built-in default) from "present but empty" (0 with an
# empty value, -> invalid, never a silent default) is the whole point of the rc.
_kv_get(){
  local file="$1" key="$2" raw line v n=0 out="" bad=""
  [ -f "$file" ] || return 1
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    [ "${line%%[[:space:]=:]*}" = "$key" ] || continue
    case "$line" in
      "$key="[[:space:]]*) bad="$line" ;;
      "$key="*) v="${line#*=}"; v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}"; n=$((n+1)); out="$v" ;;
      *) bad="$line" ;;
    esac
  done < "$file"
  if [ -n "$bad" ]; then printf "malformed line '%s' in %s — write it as %s=<value>, no spaces around =" "$bad" "$file" "$key"; return 2; fi
  if [ "$n" -gt 1 ]; then printf '%s set more than once in %s' "$key" "$file"; return 2; fi
  [ "$n" -eq 1 ] || return 1
  printf '%s' "${out/#\~/$HOME}"
  return 0
}

mcp_policy_kv(){ _kv_get "$MCP_CONFIG_FILE" "$1"; }   # the channel/update callers' name for _kv_get (same rc contract)

# --- URL helpers ---------------------------------------------------------------
# _mcp_looks_like_url <v> -> true for https://..., git@host:path, ssh://... ; used
# to validate .url=/.fork= (a bare filesystem-looking value there is invalid).
_mcp_looks_like_url(){ case "$1" in *://*|git@*:*) return 0 ;; *) return 1 ;; esac; }

# _mcp_url_norm <url> -> lowercase, no trailing .git or /, ssh forms rewritten to
# https://host/path — so origin-mismatch / fork==origin comparisons ignore the
# cosmetic differences gh's git_protocol can introduce.
_mcp_url_norm(){
  local u="$1"
  u="${u%/}"; u="${u%.git}"; u="${u%/}"   # slash first: "…/r.git/" must equal "…/r.git"
  case "$u" in
    git@*:*)      u="https://$(printf '%s' "${u#git@}" | sed 's/:/\//')" ;;
    ssh://git@*)  u="https://${u#ssh://git@}" ;;
  esac
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}
_mcp_url_eq(){ [ "$(_mcp_url_norm "$1")" = "$(_mcp_url_norm "$2")" ]; }

# --- machine-wide resolution -----------------------------------------------
# _mcp_root_dir -> the configured source root (default ~/Code when root= is
# ABSENT), or INVALID:<why> when it's present-but-empty, a duplicate, or relative.
_mcp_root_dir(){
  local v rc=0
  v="$(_kv_get "$MCP_CONFIG_FILE" root)" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$v"; return 0 ;;
    1) printf '%s/Code' "$HOME"; return 0 ;;
  esac
  v="${v%/}"   # a trailing slash must never change the resolved path (e.g. the lock dir)
  case "$v" in
    "") printf 'INVALID:root= is set but empty in %s' "$MCP_CONFIG_FILE" ;;
    /*) printf '%s' "$v" ;;
    *)  printf "INVALID:root= must be an absolute path (got '%s' in %s)" "$v" "$MCP_CONFIG_FILE" ;;
  esac
}

# _mcp_owner -> the configured owner= ("" if genuinely absent), or INVALID:<why>
# on a dup or a present-but-empty value.
_mcp_owner(){
  local v rc=0
  v="$(_kv_get "$MCP_CONFIG_FILE" owner)" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$v"; return 0 ;;
    1) printf ''; return 0 ;;
  esac
  [ -n "$v" ] || { printf 'INVALID:owner= is set but empty in %s' "$MCP_CONFIG_FILE"; return 0; }
  printf '%s' "$v"
}

# --- per-launcher resolution (mcp_get is the ONE entrypoint every consumer uses) --
# _mcp_resolve_pathkey <launcher> <dir|src> -> resolved absolute path, or INVALID:<why>.
# Per-MCP override key is always .dir= (covers src= for npm shapes too — a single
# override, since a launcher only ever has one source location regardless of which
# declaration key names it).
_mcp_resolve_pathkey(){
  local l="$1" dkey="$2" name ov dv root rc=0
  name="$(basename "$l" .sh)"
  ov="$(_kv_get "$MCP_CONFIG_FILE" "$name.dir")" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$ov"; return 0 ;;
    0)
      ov="${ov%/}"   # a trailing slash must never change the resolved path (e.g. the lock dir)
      case "$ov" in
        "") printf 'INVALID:%s.dir is set but empty in %s' "$name" "$MCP_CONFIG_FILE"; return 0 ;;
        /*) printf '%s' "$ov"; return 0 ;;
        *)  printf "INVALID:%s.dir must be an absolute path (got '%s') — machine overrides are one-off locations, never relative" "$name" "$ov"; return 0 ;;
      esac ;;
  esac
  # rc=1: no per-MCP override — fall through to the declaration.
  dv="$(decl_get "$l" "$dkey")"; dv="${dv%/}"
  [ -n "$dv" ] || { printf 'INVALID:%s: no %s= on the declaration in %s' "$name" "$dkey" "$(basename "$l")"; return 0; }
  case "$dv" in
    /*) printf '%s' "$dv" ;;
    *)  root="$(_mcp_root_dir)"
        case "$root" in INVALID:*) printf '%s' "$root" ;; *) printf '%s/%s' "$root" "$dv" ;; esac ;;
  esac
}

# _mcp_url <launcher> -> resolved clone/origin URL, or INVALID:<why>. Per-MCP
# .url= wins outright; otherwise the declared url= is rewritten to owner= when
# it's a github.com URL (any other host is used as declared, unrewritten).
_mcp_url(){
  local l="$1" name ov dv owner rc=0
  name="$(basename "$l" .sh)"
  ov="$(_kv_get "$MCP_CONFIG_FILE" "$name.url")" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$ov"; return 0 ;;
    0)
      case "$ov" in
        "") printf 'INVALID:%s.url is set but empty in %s' "$name" "$MCP_CONFIG_FILE"; return 0 ;;
        *) if _mcp_looks_like_url "$ov"; then printf '%s' "$ov"; return 0
           else printf "INVALID:%s.url must be a URL (got '%s')" "$name" "$ov"; return 0; fi ;;
      esac ;;
  esac
  # rc=1: no per-MCP override.
  dv="$(decl_get "$l" url)"
  [ -n "$dv" ] || { printf '%s' "$dv"; return 0; }
  owner="$(_mcp_owner)"
  case "$owner" in INVALID:*) printf '%s' "$owner"; return 0 ;; esac
  if [ -n "$owner" ]; then
    case "$dv" in
      *github.com/*|*github.com:*) printf '%s' "$(printf '%s' "$dv" | sed -E "s#(github\\.com[:/])[^/]+/#\\1${owner}/#")" ;;
      *) printf '%s' "$dv" ;;   # not a github.com URL: owner= doesn't apply
    esac
  else
    printf '%s' "$dv"
  fi
}

# _mcp_fork <launcher> -> resolved .fork= URL, "" if genuinely absent, or
# INVALID:<why> on a dup or a present-but-empty value.
_mcp_fork(){
  local l="$1" name v rc=0
  name="$(basename "$l" .sh)"
  v="$(_kv_get "$MCP_CONFIG_FILE" "$name.fork")" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$v"; return 0 ;;
    1) printf ''; return 0 ;;
  esac
  case "$v" in
    "") printf 'INVALID:%s.fork is set but empty in %s' "$name" "$MCP_CONFIG_FILE" ;;
    *)  if _mcp_looks_like_url "$v"; then printf '%s' "$v"; else printf "INVALID:%s.fork must be a URL (got '%s')" "$name" "$v"; fi ;;
  esac
}

# _mcp_branch <launcher> -> effective branch (per-MCP .branch= else declared branch=,
# default main), or INVALID:<why> on a dup or malformed override. An empty .branch= override
# is treated the same as absent (falls back to the declared default) — branch
# isn't in the "empty is invalid" set (root/owner/url/fork/dir).
_mcp_branch(){
  local l="$1" name v rc=0
  name="$(basename "$l" .sh)"
  v="$(_kv_get "$MCP_CONFIG_FILE" "$name.branch")" || rc=$?
  case "$rc" in
    2) printf 'INVALID:%s' "$v"; return 0 ;;
  esac
  [ -n "$v" ] || v="$(decl_get "$l" branch main)"
  printf '%s' "$v"
}

# mcp_get <launcher> <key> -> the ONE resolution entrypoint. key in: dir|src (path,
# rooted unless absolute) url fork branch root owner, or any other declaration key
# (passed through to decl_get unresolved — e.g. sub, entry, pkg, shape — and shape
# itself is a literal, never routed here: use mcp_shape for the EFFECTIVE shape).
# Never resolves a value outside this function: "nothing builds a path, url or
# shape outside mcp_get/mcp_shape" is the acceptance bar; a bare decl_get/_kv_get
# call elsewhere for one of these keys is a bug.
mcp_get(){
  local l="$1" key="$2"
  case "$key" in
    dir|src) _mcp_resolve_pathkey "$l" "$key" ;;
    url)     _mcp_url "$l" ;;
    fork)    _mcp_fork "$l" ;;
    branch)  _mcp_branch "$l" ;;
    root)    _mcp_root_dir ;;
    owner)   _mcp_owner ;;
    *)       decl_get "$l" "$key" ;;
  esac
}

# mcp_root <launcher> -> where the declared program's source lives: dir= (fork|
# checkout) or src= (npm) — resolved through mcp_get, so root=/owner=/.dir= all apply.
mcp_root(){
  local l="$1" shape pathkey
  shape="$(decl_get "$l" shape)"
  pathkey=dir; [ "$shape" = npm ] && pathkey=src
  mcp_get "$l" "$pathkey"
}
# mcp_sub <launcher> : the declared package subdir, normalized — trailing slashes and a
# leading ./ stripped, empty -> "." — so "packages/p/" and "packages/p" build the same paths.
mcp_sub(){
  local s; s="$(decl_get "$1" sub .)"
  while [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  while [ "${s#./}" != "$s" ]; do s="${s#./}"; done
  [ -n "$s" ] || s=.
  printf '%s' "$s"
}
mcp_pkgdir(){
  local r s; r="$(mcp_root "$1")"; case "$r" in INVALID:*) printf '%s' "$r"; return 0 ;; esac
  s="$(mcp_sub "$1")"; if [ "$s" = . ]; then printf '%s' "$r"; else printf '%s/%s' "$r" "$s"; fi
}
mcp_entry(){
  local p; p="$(mcp_pkgdir "$1")"; case "$p" in INVALID:*) printf '%s' "$p"; return 0 ;; esac
  printf '%s/%s' "$p" "$(decl_get "$1" entry dist/index.js)"
}

# mcp_shape <launcher> -> fork | checkout | npm | INVALID:<why>. THE effective-shape
# resolver — every consumer that needs to know what a launcher actually is (not
# just what's tracked) calls this, never a raw `decl_get ... shape`. A tracked
# shape=checkout is upgraded to fork only when a resolved .fork= exists and
# differs (URL-normalized) from the resolved origin — fork==origin is never an
# error, it's re-parented (checkers report the leftover .fork= line as redundant).
# An explicit tracked shape=fork is never downgraded (it means "always a fork,
# no per-machine override needed"). An invalid .fork= or origin url= PROPAGATES
# as INVALID — it must never silently resolve to "checkout" just because the
# upgrade condition couldn't be evaluated.
mcp_shape(){
  local l="$1" decl fork url
  decl="$(decl_get "$l" shape)"
  case "$decl" in
    npm|fork) printf '%s' "$decl"; return 0 ;;
    checkout) : ;;
    *) printf "INVALID:unknown shape '%s'" "$decl"; return 0 ;;
  esac
  fork="$(_mcp_fork "$l")"
  case "$fork" in INVALID:*) printf '%s' "$fork"; return 0 ;; esac
  [ -n "$fork" ] || { printf 'checkout'; return 0; }
  url="$(mcp_get "$l" url)"
  case "$url" in INVALID:*) printf '%s' "$url"; return 0 ;; esac
  if _mcp_url_eq "$fork" "$url"; then printf 'checkout'; else printf 'fork'; fi
}

# fork_is_redundant <launcher> -> true (0) when .fork= is set but resolves equal to
# origin (checkers report this as a leftover line, never an error).
fork_is_redundant(){
  local l="$1" fork url
  fork="$(_mcp_fork "$l")"; case "$fork" in INVALID:*|"") return 1 ;; esac
  url="$(mcp_get "$l" url)"; case "$url" in INVALID:*) return 1 ;; esac
  _mcp_url_eq "$fork" "$url"
}

# --- channels (npm shape) -----------------------------------------------------
# mcp_update_mode <launcher> -> ask (no line) | auto | INVALID:<why> (empty counts as invalid)
mcp_update_mode(){
  local name v rc=0; name="$(basename "$1" .sh)"; v="$(mcp_policy_kv "$name.update")" || rc=$?
  case "$rc" in 1) printf 'ask'; return 0 ;; 2) printf 'INVALID:%s' "$v"; return 0 ;; esac
  case "$v" in
    ask|auto) printf '%s' "$v" ;;
    *)   printf "INVALID:update='%s' for %s in %s — use auto or ask" "$v" "$name" "$MCP_CONFIG_FILE" ;;
  esac
}

# mcp_npm_spec <launcher> -> <pkg>@<applied> (exact pin; moves only when an apply records a
# new version), or bare <pkg> when nothing has been applied yet (the checker flags it `unpinned`).
mcp_npm_spec(){
  local pkg ver; pkg="$(decl_get "$1" pkg)"
  ver="$(cat "$MCP_UPDATE_STATE/$(basename "$1" .sh).applied" 2>/dev/null || true)"
  if [ -n "$ver" ]; then printf '%s@%s' "$pkg" "$ver"; else printf '%s' "$pkg"; fi
}

# mcp_channel <launcher> -> stable | canary | INVALID:<why>   (meaningful for shape=npm)
# <l>.channel= wins, else the machine default channel=, else stable; empty is invalid.
mcp_channel(){
  local l="$1" name v rc=0
  name="$(basename "$l" .sh)"
  v="$(mcp_policy_kv "$name.channel")" || rc=$?
  if [ "$rc" = 1 ]; then rc=0; v="$(mcp_policy_kv channel)" || rc=$?; fi
  case "$rc" in 1) v=stable ;; 2) printf 'INVALID:%s' "$v"; return 0 ;; esac
  case "$v" in
    stable) printf 'stable' ;;
    canary)
      if [ -z "$(decl_get "$l" src)" ] || [ -z "$(decl_get "$l" url)" ] || [ -z "$(decl_get "$l" sub)" ]; then
        printf 'INVALID:channel=canary needs src= url= sub= on the declaration in %s' "$(basename "$l")"
      else printf 'canary'; fi ;;
    *)   printf "INVALID:channel='%s' for %s in %s — use stable or canary" "$v" "$name" "$MCP_CONFIG_FILE" ;;
  esac
}

# mcp_policy_lint <launcher-dir> -> one line per setting that is invalid: an
# unrecognized key, a per-MCP key for a launcher that doesn't exist, or a
# value that the matching resolver itself rejects (duplicate, empty, relative,
# not-a-URL, ...) — checked by actually calling that resolver, so lint can never
# drift from what the resolvers enforce at run time.
mcp_policy_lint(){
  local dir="$1" raw line key l v rc
  [ -f "$MCP_CONFIG_FILE" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) printf "'%s': not a key=value setting (known: channel=, root=, owner=, <launcher>.channel=, <launcher>.update=, <launcher>.url=, <launcher>.fork=, <launcher>.dir=, <launcher>.branch=)\n" "$line"; continue ;;
    esac
    key="${line%%[[:space:]=]*}"; l="$dir/${key%.*}.sh"
    case "$key" in
      channel) rc=0; v="$(mcp_policy_kv channel)" || rc=$?
        if [ "$rc" = 2 ]; then printf '%s: %s\n' "$key" "$v"
        else case "$v" in stable|canary) ;; *) printf '%s: "%s" is not stable|canary\n' "$key" "$v" ;; esac; fi ;;
      root)  v="$(_mcp_root_dir)";  case "$v" in INVALID:*) printf '%s: %s\n' "$key" "${v#INVALID:}" ;; esac ;;
      owner) v="$(_mcp_owner)";     case "$v" in INVALID:*) printf '%s: %s\n' "$key" "${v#INVALID:}" ;; esac ;;
      *.channel|*.update)
        if [ ! -f "$l" ]; then printf '%s: no launcher %s.sh\n' "$key" "${key%.*}"
        elif [ "${key##*.}" = channel ] && [ "$(decl_get "$l" shape)" != npm ]; then printf '%s: channels apply to shape=npm only\n' "$key"
        else
          if [ "${key##*.}" = channel ]; then v="$(mcp_channel "$l")"; else v="$(mcp_update_mode "$l")"; fi
          case "$v" in INVALID:*) printf '%s: %s\n' "$key" "${v#INVALID:}" ;; esac
        fi ;;
      *.url|*.fork|*.dir|*.branch)
        if [ ! -f "$l" ]; then printf '%s: no launcher %s.sh\n' "$key" "${key%.*}"; continue; fi
        case "${key##*.}" in
          url)    v="$(_mcp_url "$l")" ;;
          fork)   v="$(_mcp_fork "$l")" ;;
          dir)    if [ "$(decl_get "$l" shape)" = npm ]; then v="$(_mcp_resolve_pathkey "$l" src)"; else v="$(_mcp_resolve_pathkey "$l" dir)"; fi ;;
          branch) v="$(_mcp_branch "$l")" ;;
        esac
        case "$v" in INVALID:*) printf '%s: %s\n' "$key" "${v#INVALID:}" ;; esac ;;
      *) printf '%s: unknown setting (known: channel, root, owner, <launcher>.channel, <launcher>.update, <launcher>.url, <launcher>.fork, <launcher>.dir, <launcher>.branch)\n' "$key" ;;
    esac
  done < "$MCP_CONFIG_FILE"
}

# mcp_eff_shape <launcher> -> fork | checkout | npm | invalid
# An npm MCP on the canary channel runs from a checkout, so it is checked + applied as one.
mcp_eff_shape(){
  local s; s="$(mcp_shape "$1")"
  case "$s" in INVALID:*) printf 'invalid'; return 0 ;; esac
  if [ "$s" = npm ]; then
    case "$(mcp_channel "$1")" in stable) ;; canary) s=checkout ;; *) s=invalid ;; esac
  fi
  printf '%s' "$s"
}

# --- locking (every source build; fork, checkout, npm-canary alike) -----------
# Age-only staleness, never PID-liveness: a dead holder can still have a live
# npm child writing into the checkout, so treating the parent's death as
# "stale" would let a second build start concurrently and corrupt
# node_modules — the exact race this lock exists to prevent.
# A cold npm ci + build typically takes seconds, a fork merge + clone well
# under a minute; 5 min leaves a wide margin — raise it for a slower MCP.
MCP_LOCK_STALE_MIN=5

# _mcp_lock_stale <lockdir> -> 0 (stale) once it's older than $MCP_LOCK_STALE_MIN.
_mcp_lock_stale(){
  local lk="$1"
  [ -n "$(find "$lk" -maxdepth 0 -mmin +"$MCP_LOCK_STALE_MIN" 2>/dev/null)" ]
}

# _mcp_lock_acquire <checkout-dir> [max-wait-seconds] : take <checkout-dir>.openbrain-build.lock
# (atomic mkdir; a lock older than $MCP_LOCK_STALE_MIN is broken), waiting up to
# max-wait (default $MCP_LOCK_WAIT, else 900s). 0 = held (released on EXIT or by
# _mcp_lock_release); 1 = timed out, message on stderr. One holder per process.
# The holder writes an owner token into the lock dir; release removes the lock only
# while that token is still there, so a holder whose lock was taken over (stale
# window) never deletes the new holder's lock on its way out.
# Holders: the build engine (mcp-local-build.sh) for its WHOLE run — the only
# holder while a build runs — plus the one short non-build step that writes the
# checkout: the first clone (_mcp_prepare_checkout). Never take it around a call
# to the engine: a holder that dies releases it while the engine (its child) is
# still building.
_MCP_LOCK=""
# _mcp_lock_break <lockdir> : remove a stale lock under a short break mutex
# (<lockdir>.break), re-checking staleness while holding it. Waiters that all saw the
# same stale lock never each remove a lock and then each take one: the second to get
# the mutex finds the first's fresh lock (or none) on re-check and leaves it alone.
_mcp_lock_break(){
  local lk="$1" b="$1.break"
  if mkdir "$b" 2>/dev/null; then
    if _mcp_lock_stale "$lk"; then rm -rf "$lk"; fi
    rmdir "$b"
  elif _mcp_lock_stale "$b"; then rmdir "$b"   # a breaker killed between its mkdir and rmdir
  else sleep 1; fi
}
_mcp_lock_acquire(){
  local lk="$1.openbrain-build.lock" max="${2:-${MCP_LOCK_WAIT:-900}}" n=0
  mkdir -p "$(dirname "$1")" || return 1
  until mkdir "$lk" 2>/dev/null; do
    if _mcp_lock_stale "$lk"; then _mcp_lock_break "$lk"; continue; fi
    n=$((n+1))
    if [ "$n" -ge "$max" ]; then
      printf 'openbrain mcp: timed out after %ss waiting for %s — another build holds it (remove it only if no build is running)\n' "$max" "$lk" >&2
      return 1
    fi
    sleep 1
  done
  _MCP_LOCK="$lk"; _MCP_LOCK_TOKEN="$$.$(date +%s).$RANDOM"
  printf '%s\n' "$_MCP_LOCK_TOKEN" > "$lk/owner" || { rm -rf "$lk"; _MCP_LOCK=""; return 1; }
  trap '_mcp_lock_release' EXIT
}
_mcp_lock_release(){
  if [ -n "${_MCP_LOCK:-}" ] && [ "$(cat "$_MCP_LOCK/owner" 2>/dev/null)" = "${_MCP_LOCK_TOKEN:-}" ]; then
    rm -rf "$_MCP_LOCK"
  fi
  _MCP_LOCK=""
  trap - EXIT
}

# mcp_fork_unsupported <launcher> -> "" when the fork engine honours every key that
# applies, else one line naming the first key it would silently ignore. The fork
# engine always builds local-build from <origin>/main at the checkout root and
# runs dist/index.js, so a non-default sub=, entry= or branch (declared branch= or
# <l>.branch=) on an effective fork is a STOP, never a silent build of something else.
mcp_fork_unsupported(){
  local l="$1" name v rc=0
  name="$(basename "$l" .sh)"
  v="$(mcp_sub "$l")"
  [ "$v" = . ] || { printf "sub=%s on %s: the fork engine builds the checkout root only — remove sub=, or drop %s.fork= to build it as a checkout" "$v" "$(basename "$l")" "$name"; return 0; }
  v="$(decl_get "$l" entry)"
  [ -z "$v" ] || [ "$v" = dist/index.js ] || { printf "entry=%s on %s: the fork engine runs dist/index.js only — remove entry=, or drop %s.fork= to build it as a checkout" "$v" "$(basename "$l")" "$name"; return 0; }
  v="$(mcp_get "$l" branch)"
  case "$v" in INVALID:*) printf '%s' "${v#INVALID:}"; return 0 ;; esac
  [ "$v" = main ] && return 0
  # Name the line that actually supplied the value: an EMPTY <l>.branch= falls back
  # to the declaration (_mcp_branch), so only a non-empty config value is "the config's".
  local cv; cv="$(_kv_get "$MCP_CONFIG_FILE" "$name.branch")" || rc=$?
  if [ "$rc" = 0 ] && [ -n "$cv" ]; then
    printf "%s.branch=%s in %s: a fork always runs local-build on <origin>/main — remove the line, or drop %s.fork= to track %s as a checkout" "$name" "$v" "$MCP_CONFIG_FILE" "$name" "$v"
  else
    printf "branch=%s on %s: a fork always runs local-build on <origin>/main — remove branch=, or drop %s.fork= to track %s as a checkout" "$v" "$(basename "$l")" "$name" "$v"
  fi
}

# mcp_stamped <pkgdir> : dist/.built-from holds a commit sha — the engine stamps it only
# after a complete, unmixed, tested build. Checker-only: the launcher runs any dist/ whose
# entry exists; an unstamped one (interrupted, mixed, hand- or pre-stamp-built) is the
# checker's unproven-build, fixed by --apply.
mcp_stamped(){ [ -f "$1/dist/.built-from" ] && head -1 "$1/dist/.built-from" | grep -Eq '^[0-9a-f]{40}$'; }

# --- apply pins: a go lands exactly what was approved -----------------------------
# The offer's pin IS the build composition, so the apply builds exactly it — nothing that
# arrived after the offer (that is the next offer), nothing re-derived.
#   fork:     main=<sha>[,feat/<name>=<sha>]...  (origin/main + each fork/feat/* tip, 40-hex
#             shas, feats in byte order). One shell-safe token: names are [A-Za-z0-9._/-] only.
#   checkout: the origin/<branch> sha (40 hex).   npm: the version.
# Every pin ends in `,built=<id>`: the build the offer was made against — dist/.built-from
# (mcp_built_id) for fork/checkout, the recorded .applied version for npm, `none` when there
# is none. A go whose built= is not the current build is refused (stale offer), so applying an
# older offer can never move the build backward over an apply that landed after it.
# mcp_fork_pin_listing <dir> <base-ref> <fork-remote> : "<ref> <sha>" lines — the base ref
#   first, then every <fork-remote>/feat/* tip in byte order. rc 1 (nothing on stdout) when a
#   ref cannot be read: a pin is never built from a partial listing.
# mcp_fork_pin <fork-remote> : stdin listing -> the fork composition (no built= yet; the caller
#   appends it with mcp_pin_with_built). rc 1 when a feat name cannot be carried in the token
#   (the caller reports CANNOT-CHECK; never a shortened pin).
# mcp_pin_valid <fork|checkout|npm> <pin> : rc 0 when <pin> has that kind's form, built= included
#   — the ONE validator (check-updates.sh --apply and the engine both call it). mcp_pin_form names it.
# mcp_pin_unbuilt <kind> <pin> : rc 0 when <pin> is a composition with no built= entry — it names
#   no build, so it cannot be checked and is refused as stale, never applied.
# mcp_pin_target <pin> / mcp_pin_built <pin> : the composition / the built= id of a valid pin.
# mcp_built_id <pkgdir> : the build dist/ holds — the .built-from sha, or `none` (no stamp, or not
#   a sha). A stranded .dist.bak is what the engine's next run restores before it builds, so it is
#   read first. rc 1 when the stamp exists but cannot be read: callers offer no pin / build nothing.
mcp_fork_pin_listing(){
  local dir="$1" base="$2" remote="$3" bsha feats
  bsha="$(git -C "$dir" rev-parse -q --verify "$base^{commit}")" || return 1
  feats="$(git -C "$dir" for-each-ref --format='%(refname:short) %(objectname)' "refs/remotes/$remote/feat")" || return 1
  feats="$(printf '%s\n' "$feats" | LC_ALL=C sort)"   # explicit byte order: one canonical form, whoever lists
  printf '%s %s\n' "$base" "$bsha"
  [ -z "$feats" ] || printf '%s\n' "$feats"
}
mcp_fork_pin(){
  local remote="$1" r s pin="" n
  while read -r r s; do
    [ -n "$r" ] || continue
    if [ -z "$pin" ]; then pin="main=$s"; continue; fi
    n="${r#"$remote"/}"
    case "$n" in feat/*) ;; *) return 1 ;; esac
    case "$n" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
    pin="$pin,$n=$s"
  done
  [ -n "$pin" ] || return 1
  _mcp_pin_match fork target "$pin" || return 1
  printf '%s\n' "$pin"
}
# _mcp_pin_match <kind> <target|built> <value> : one part of a pin against its kind's form.
_mcp_pin_match(){
  local re
  case "$1:$2" in
    fork:target)     re='^main=[0-9a-f]{40}(,feat/[A-Za-z0-9._/-]+=[0-9a-f]{40})*$' ;;
    checkout:target) re='^[0-9a-f]{40}$' ;;
    npm:target)      re='^[0-9A-Za-z][0-9A-Za-z.+-]*$' ;;
    fork:built|checkout:built) re='^([0-9a-f]{40}|none)$' ;;
    npm:built)       re='^[0-9A-Za-z][0-9A-Za-z.+-]*$' ;;   # a version, or none
    *)               return 1 ;;
  esac
  case "$3" in *"
"*) return 1 ;; esac   # one line only: grep would accept a multi-line value on its first line
  printf '%s\n' "$3" | grep -Eq "$re"
}
mcp_pin_valid(){
  case "$2" in *,built=*) ;; *) return 1 ;; esac
  _mcp_pin_match "$1" target "${2%,built=*}" && _mcp_pin_match "$1" built "${2##*,built=}"
}
mcp_pin_unbuilt(){
  case "$2" in *,built=*) return 1 ;; esac
  _mcp_pin_match "$1" target "$2"
}
# mcp_npm_applied <name> : the version recorded in <name>.applied (empty when none is recorded).
#   rc 1 when the file exists but cannot be read: callers offer no pin and record nothing.
mcp_npm_applied(){
  local f="$MCP_UPDATE_STATE/$1.applied"
  [ -e "$f" ] || return 0
  cat "$f" || return 1
}
mcp_pin_target(){ printf '%s' "${1%,built=*}"; }
mcp_pin_built(){ printf '%s' "${1##*,built=}"; }
mcp_pin_with_built(){ printf '%s,built=%s' "$1" "$2"; }
mcp_built_id(){
  local f="$1/dist/.built-from" v
  [ -e "$1/.dist.bak" ] && f="$1/.dist.bak/.built-from"
  [ -e "$f" ] || { printf 'none'; return 0; }
  v="$(head -1 "$f")" || return 1
  if printf '%s\n' "$v" | grep -Eq '^[0-9a-f]{40}$'; then printf '%s' "$v"; else printf 'none'; fi
}
mcp_pin_form(){
  case "$1" in
    fork)     printf 'main=<sha>[,feat/<name>=<sha>]...,built=<sha|none> (40-hex shas), as the report printed it' ;;
    checkout) printf '<origin/<branch> commit>,built=<sha|none> (40 hex), as the report printed it' ;;
    npm)      printf '<published version>,built=<version|none>, as the report printed it' ;;
    *)        printf 'nothing (the shape is invalid)' ;;
  esac
}

# --- one install path ---------------------------------------------------------
# ensure_mcp_server [name] : the ONE way a fork/checkout/npm-canary source gets
# cloned + built, for both a launcher's own lazy first-launch self-heal AND a
# setup-time `add-*.sh` install.
#   no arg  — self-install: the launcher is BASH_SOURCE[last] (the bottom of the
#             source stack Claude Code exec'd) — a launcher can only install
#             itself this way; covers fork, checkout and npm canary alike.
#   <name>  — setup-time install of the INSTALLED launcher $LIB_DIR/<name>.sh
#             (accepts a trailing -mcp, stripped; must match ^[a-z0-9-]+$ after
#             stripping). NEVER deploys — a missing installed launcher or
#             declaration is a loud stop naming the exact path. There is no
#             fallback to $HOME/<name> or $HOME/Code/<name>.
# Every build runs under the checkout's lock (_mcp_lock_acquire: mkdir
# <checkout>.openbrain-build.lock, stale after $MCP_LOCK_STALE_MIN minutes —
# age-only), taken by the build engine itself for its whole run — fork,
# checkout AND npm-canary alike, whoever started it — so concurrent builds
# (every MCP starting together, two sessions, reconcile or an apply
# overlapping a lazy launch) serialize instead of corrupting one node_modules.
ensure_mcp_server(){
  local l m
  if [ $# -eq 0 ]; then
    # Self-install at launch: the validity gate runs first
    # (exactly one declaration line, a valid update= mode) — an invalid value
    # stops the launcher here, never a silent default.
    l="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}"
    [ "$(decl_count "$l")" = 1 ] || die "$(basename "$l"): needs exactly one '# openbrain-mcp:' line"
    m="$(mcp_update_mode "$l")"; [ "${m#INVALID:}" = "$m" ] || die "$(basename "$l"): ${m#INVALID:}"
  else
    local raw="$1" name lib_dir
    raw="${raw%-mcp}"
    case "$raw" in *[!a-z0-9-]*|"") die "ensure_mcp_server: invalid name '$1' (expected ^[a-z0-9-]+\$)" ;; esac
    name="$raw-mcp"
    lib_dir="${MCP_LIB_DIR:-${LIB_DIR:-$HOME/.config/openbrain/lib}}"
    l="$lib_dir/$name.sh"
    [ -f "$l" ] || die "ensure_mcp_server $1: no installed launcher at $l (run register-mcps.sh / minimal-init.sh first)"
    [ "$(decl_count "$l")" = 1 ] || die "ensure_mcp_server $1: $l needs exactly one '# openbrain-mcp:' line"
  fi
  _mcp_build_from_source "$l"
}

# _mcp_clone <url> <dir> [branch] : clone into a sibling temp dir and mv into place
# only on success — a killed clone must never leave a partial checkout at <dir>
# that looks present to the next launch. The temp dir is per process, so a clone
# orphaned by a killed caller never collides with the next caller's. [branch]
# checks that branch out (the branch a checkout build tracks); empty = the
# remote's default branch.
_mcp_clone(){
  local url="$1" dir="$2" branch="${3:-}" tmp="$2.openbrain-clone-tmp.$$"
  local -a bopt=()
  [ -z "$branch" ] || bopt=(-b "$branch")
  rm -rf "$tmp"
  if ! { command -v gh >/dev/null 2>&1 && gh repo clone "$url" "$tmp" -- ${bopt[@]+"${bopt[@]}"} >&2; }; then
    rm -rf "$tmp"
    git clone ${bopt[@]+"${bopt[@]}"} "$url" "$tmp" >&2 || { rm -rf "$tmp"; die "failed to clone $url${branch:+ (branch $branch)}"; }
  fi
  if [ -e "$dir" ]; then
    # Something else already created the target (e.g. a slow legitimate build
    # that finished right as an age-stale lock let a second caller in) — discard
    # this temp clone rather than `mv` INTO it, which would nest the clone one
    # level deep instead of replacing it.
    rm -rf "$tmp"
    return 0
  fi
  mv "$tmp" "$dir" || die "cloned $url but failed to move it into place at $dir"
}

# _mcp_build_shape <launcher> -> fork | checkout, or INVALID:<why> — mcp_shape
# folded with the npm channel (an npm MCP on the canary channel is built exactly
# like a checkout; stable is never source-built and must not reach this function).
# Kept separate from mcp_eff_shape so the specific reason (a bad .fork=/url=, or
# a bad channel) survives instead of collapsing to the bare string "invalid".
_mcp_build_shape(){
  local l="$1" s ch
  s="$(mcp_shape "$l")"
  case "$s" in INVALID:*) printf '%s' "$s"; return 0 ;; esac
  if [ "$s" = npm ]; then
    ch="$(mcp_channel "$l")"
    case "$ch" in
      stable) printf 'INVALID:shape npm (stable channel) runs via npx — not source-built, ensure_mcp_server should not be called for it' ;;
      canary) printf 'checkout' ;;
      *)      printf '%s' "$ch" ;;   # INVALID:<channel message>
    esac
    return 0
  fi
  printf '%s' "$s"   # fork or checkout
}

# _mcp_clean_clone_tmps <dir> : remove <dir>.openbrain-clone-tmp.<pid> dirs a killed
# caller left behind — when that pid is gone, or the dir is over an hour old. Run under
# the build lock, before cloning. Cleanup timing never affects correctness (every clone
# uses its own temp dir), so the hour is deliberately generous.
_mcp_clean_clone_tmps(){
  local dir="${1:?}" t pid
  for t in "$dir".openbrain-clone-tmp.*; do
    [ -d "$t" ] || continue
    case "$t" in "$dir".openbrain-clone-tmp.*) ;; *) continue ;; esac
    pid="${t##*.openbrain-clone-tmp.}"
    case "$pid" in ""|*[!0-9]*) continue ;; esac
    if ! ps -p "$pid" >/dev/null 2>&1 || [ -n "$(find "$t" -maxdepth 0 -mmin +60)" ]; then
      echo "openbrain mcp: removing an orphaned clone temp dir $t" >&2
      rm -rf "${t:?}"
    fi
  done
}

# _mcp_prepare_checkout <launcher> <shape> <dir> <url> <branch> <fork> : make <dir>
# something the engine can build — clone it if missing (a checkout clones the
# branch its build tracks, or the engine refuses it; a fork clones the default
# branch, from which the engine builds local-build) and, for a fork, add the fork
# remote. Holds the build lock for THIS STEP ONLY; the engine takes it itself
# for the build. Dies on failure (callers that must survive run it in a subshell).
_mcp_prepare_checkout(){
  local l="$1" shape="$2" dir="$3" url="$4" branch="$5" fork="$6" remote_name="${MCP_FORK_REMOTE:-fork}"
  _mcp_lock_acquire "$dir" || die "$(basename "$l"): could not take the build lock for $dir"
  _mcp_clean_clone_tmps "$dir"
  if [ ! -d "$dir" ]; then
    [ -n "$url" ] || die "$(basename "$l"): no url= to clone $dir from"
    echo "openbrain mcp: cloning $url -> $dir ..." >&2
    if [ "$shape" = fork ]; then _mcp_clone "$url" "$dir"; else _mcp_clone "$url" "$dir" "$branch"; fi
  fi
  # Hand-managed: the fork engine needs BOTH origin and the fork remote. A fresh
  # clone only has origin; add fork here (never fetch manually — the engine's own
  # fetch of both remotes covers freshness).
  if [ "$shape" = fork ] && [ -n "$fork" ] && [ "$(git -C "$dir" remote 2>/dev/null | grep -c "^${remote_name}\$" || true)" -eq 0 ]; then
    echo "openbrain mcp: adding $remote_name remote $fork ..." >&2
    git -C "$dir" remote add "$remote_name" "$fork" >&2 || die "failed to add $remote_name remote $fork"
  fi
  _mcp_lock_release
}

_mcp_build_from_source(){
  local l="$1" shape dir sub entry url fork branch unsup engine
  shape="$(_mcp_build_shape "$l")"
  case "$shape" in INVALID:*) die "$(basename "$l"): ${shape#INVALID:}" ;; esac
  dir="$(mcp_root "$l")"; case "$dir" in INVALID:*) die "$(basename "$l"): ${dir#INVALID:}" ;; esac
  sub="$(mcp_sub "$l")"
  entry="$(mcp_entry "$l")"
  url="$(mcp_get "$l" url)"; case "$url" in INVALID:*) die "$(basename "$l"): ${url#INVALID:}" ;; esac
  branch="$(mcp_get "$l" branch)"; case "$branch" in INVALID:*) die "$(basename "$l"): ${branch#INVALID:}" ;; esac
  fork=""
  if [ "$shape" = fork ]; then
    fork="$(mcp_get "$l" fork)"; case "$fork" in INVALID:*) die "$(basename "$l"): ${fork#INVALID:}" ;; esac
    unsup="$(mcp_fork_unsupported "$l")"; [ -z "$unsup" ] || die "$(basename "$l"): STOP — $unsup"
  fi
  # Every validity check above runs BEFORE the "already built" shortcut: an
  # invalid config must stop the launcher even when dist/ happens to exist
  # already, never pass silently because "it's built so who cares."
  # "Built" = the entry exists and no build is running or was cut short (no build lock,
  # no .dist.bak): then dist/ is a finished build, and the launcher never rebuilds or
  # refuses it — whether it is stamped (proven) is the checker's question (unproven-build).
  # Otherwise dist/ may be a build's untested output: go through the engine, which waits
  # for the lock, restores a stranded last-good dist/, and exits 0 (MCP_BUILD_ONLY_IF_MISSING)
  # before any dirty/off-branch refusal once the entry exists.
  [ -f "$entry" ] && [ ! -e "$(mcp_pkgdir "$l")/.dist.bak" ] && [ ! -d "$dir.openbrain-build.lock" ] && return 0
  engine="${MCP_LOCAL_BUILD_SH:-$(dirname "$l")/mcp-local-build.sh}"
  [ -f "$engine" ] || die "$(basename "$l"): build engine missing at $engine (deploy mcp-local-build.sh next to the launchers)"
  if [ -f "$entry" ]; then
    echo "openbrain mcp: a build of $(basename "$l" .sh) is running or was interrupted — waiting for it / restoring its last-good dist ..." >&2
  else
    echo "openbrain mcp: $entry missing — auto-installing from declaration..." >&2
  fi
  _mcp_prepare_checkout "$l" "$shape" "$dir" "$url" "$branch" "$fork"
  # The engine takes the build lock itself and holds it for the whole build; with
  # MCP_BUILD_ONLY_IF_MISSING it does nothing when a concurrent launch built first.
  if [ "$shape" = fork ]; then
    MCP_BUILD_ONLY_IF_MISSING="$entry" bash "$engine" "$l" >&2 \
      || die "$(basename "$l" .sh): fork build failed (see above) — fix the cause, then relaunch the server (the next launch retries the build)"
  else
    MCP_SKIP_FETCH=1 MCP_BUILD_ONLY_IF_MISSING="$entry" bash "$engine" --checkout "$(basename "$l" .sh)" "$dir" "$sub" "$branch" "$(mcp_get "$l" entry)" >&2 \
      || die "$(basename "$l" .sh): build failed (see above) — fix the cause, then relaunch the server (the next launch retries the build)"
  fi
  [ -f "$entry" ] || die "the build finished but $entry is missing"
  echo "openbrain mcp: installed at $entry" >&2
}
