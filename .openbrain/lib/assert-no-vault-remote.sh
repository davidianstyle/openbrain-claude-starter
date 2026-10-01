#!/usr/bin/env bash
# assert-no-vault-remote.sh — refuse to operate if this clone has a vault
# configured as a git remote. The clone is the bench that
# pushes to public repos; a vault configured as a remote here is a direct
# vault -> clone -> public leak path. Call at the top of the push/pull/
# reconcile entry points (cd into the clone first).
#
# Two detectors:
#   1. heuristic (always on): a remote whose URL is a LOCAL FILESYSTEM PATH
#      (/, ~, ./, ../, file://, or a bare path with no scheme/host). A template
#      clone legitimately only ever has https/ssh GitHub remotes; a local-path
#      remote is almost certainly a vault (or another working tree).
#   2. configurable: globs in .openbrain/vault-remotes (one per line; '#'
#      comments and blank lines ignored) — for explicit vault URL/path patterns
#      a site wants to name. Mirrors the .openbrain/protected-remotes design.
#      Read from the inspected repo AND from $VAULT_REMOTES_FILE when set (the
#      skills pass the vault's copy; the clone rarely carries one).
# Either match => loud abort, exit 1. There is no --no-verify style override:
# the fix is to remove the offending remote, never to bypass the check.
# Accepted gap: a vault reached over a real transport (ssh://localhost/...,
# user@localhost:...) is indistinguishable from a forge remote by URL shape
# and is not detected. This guards against misconfiguration, not against an
# operator deliberately routing to their own vault; name such a URL in
# .openbrain/vault-remotes if your setup has one.
#
# Exit — three outcomes, never two:
#   0 = every configured remote was enumerated and none is vault-shaped
#   1 = BLOCKED: a vault-shaped remote is present
#   2 = CANNOT-CHECK: not inside a git working tree, not run from its root,
#       GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR set, `git remote -v` or its parse
#       failed, zero remotes, or a named/present pattern file is unreadable.
#   The OK line states coverage: URL rows checked, patterns and files applied. A guard that cannot determine the repo or
#       enumerate its remotes must NOT certify "no vault remote" — it refuses
#       loudly, never passes silently. This is the --show-toplevel || exit 0
#       false-clean class: a
#       bare `|| exit 0` on a resolution failure collapses can't-check into
#       clean — and so does feeding a failed `git remote -v` into a loop that
#       then sees zero lines.

set -uo pipefail

# A leaked GIT_DIR/GIT_WORK_TREE would make every git call below describe some
# OTHER repo than the working directory: refuse rather than certify the wrong one.
if [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ] || [ -n "${GIT_COMMON_DIR:-}" ]; then
  echo "assert-no-vault-remote: CANNOT CHECK — GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR is set; the repo inspected would not be the working directory's. Unset them and re-run." >&2
  exit 2
fi
PWD_AT_START="$(pwd -P)"
if [ -z "$PWD_AT_START" ]; then
  echo "assert-no-vault-remote: CANNOT CHECK — cannot determine the working directory." >&2
  exit 2
fi
TOP="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$TOP" ]; then
  echo "assert-no-vault-remote: CANNOT CHECK — not inside a git working tree" >&2
  echo "(this guard must run from the template clone root). Refusing to certify clean." >&2
  exit 2
fi
# The caller must stand in the clone ROOT (so no cd is needed here). From a subdirectory (or a non-repo dir
# nested inside some other repo) the ancestor walk would certify whichever repo
# happens to enclose it — a wrong TEMPLATE must be CANNOT-CHECK, never clean.
if ! [ "$TOP" -ef "$PWD_AT_START" ]; then   # -ef: same inode, so a case-insensitive APFS spelling or a symlinked path is not a false STOP
  echo "assert-no-vault-remote: CANNOT CHECK — run from the repo root ($TOP), not from '$PWD_AT_START'." >&2
  exit 2
fi

# Enumerate remotes ONCE, rc-checked. Piping `git remote -v` straight into the
# loop would turn a failed git call into an empty set and an exit 0.
REMOTES="$(git remote -v 2>&1)"; rrc=$?
if [ "$rrc" -ne 0 ]; then
  echo "assert-no-vault-remote: CANNOT CHECK — 'git remote -v' failed (rc $rrc): $REMOTES" >&2
  exit 2
fi
# The parse is rc-checked too (pipefail is on): a failing awk/sort, or a row
# without a URL, must be CANNOT-CHECK — an empty row set that is then looped
# over would certify clean exactly like a failed `git remote -v` would.
REMOTE_ROWS="$(printf '%s\n' "$REMOTES" | awk 'NF>0 { if (NF<2) bad=1; else print $1"\t"$2 } END { exit bad+0 }' | sort -u)"; prc=$?
if [ "$prc" -ne 0 ]; then
  echo "assert-no-vault-remote: CANNOT CHECK — could not parse 'git remote -v' output (rc $prc: a remote without a URL, or awk/sort failed)." >&2
  exit 2
fi
N_REMOTES="$(printf '%s\n' "$REMOTE_ROWS" | awk 'NF>0' | awk 'END{print NR}')"
case "$N_REMOTES" in
  ''|*[!0-9]*) echo "assert-no-vault-remote: CANNOT CHECK — remote count is not a number ('$N_REMOTES')." >&2; exit 2 ;;
  0) echo "assert-no-vault-remote: CANNOT CHECK — 0 remotes configured; a template clone always has at least 'origin'. Wrong directory?" >&2; exit 2 ;;
esac

# Pattern files: the repo's own .openbrain/vault-remotes AND, when the caller
# names one, VAULT_REMOTES_FILE (the push/share skills pass the VAULT's copy —
# the clone's main never carries a pattern list, so reading only "$TOP" left the
# glob detector permanently inert). Union, never either/or: more detection, not less.
# A file the CALLER named (VAULT_REMOTES_FILE) must exist; any pattern file that
# exists must be a readable regular file — "named but unreadable" is CANNOT-CHECK,
# never "no patterns".
GLOBS=(); N_PATFILES=0
for PATFILE in "$TOP/.openbrain/vault-remotes" "${VAULT_REMOTES_FILE:-}"; do
  [ -n "$PATFILE" ] || continue
  if [ ! -e "$PATFILE" ]; then
    if [ -n "${VAULT_REMOTES_FILE:-}" ] && [ "$PATFILE" = "$VAULT_REMOTES_FILE" ]; then
      echo "assert-no-vault-remote: CANNOT CHECK — VAULT_REMOTES_FILE names '$PATFILE' but it does not exist." >&2; exit 2
    fi
    continue
  fi
  if [ ! -f "$PATFILE" ] || [ ! -r "$PATFILE" ]; then
    echo "assert-no-vault-remote: CANNOT CHECK — pattern file '$PATFILE' is not a readable regular file." >&2; exit 2
  fi
  N_PATFILES=$((N_PATFILES+1))
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                                   # CRLF-saved file: a trailing CR would silently un-match every glob
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"   # trim, as pre-push.sh does for protected-remotes
    case "$line" in ''|'#'*) continue ;; esac
    GLOBS+=("$line")
  done < "$PATFILE" || { echo "assert-no-vault-remote: CANNOT CHECK — reading '$PATFILE' failed." >&2; exit 2; }
done

bad=0
while IFS=$'\t' read -r name url; do
  [ -n "$url" ] || continue
  reason=""
  case "$url" in
    /*|~*|./*|../*|file://*)   reason="local filesystem path" ;;
    *://*|*@*:*)               : ;;   # scheme:// or scp-like host: => real remote
    *)                         reason="bare local path (no scheme/host)" ;;
  esac
  if [ -z "$reason" ] && [ "${#GLOBS[@]}" -gt 0 ]; then
    for g in "${GLOBS[@]}"; do
      [ -n "$g" ] || continue
      # shellcheck disable=SC2254
      case "$url" in $g) reason="matches vault-remotes pattern '$g'" ;; esac
    done
  fi
  if [ -n "$reason" ]; then
    echo "assert-no-vault-remote: BLOCKED — remote '$name' -> '$url' ($reason)." >&2
    bad=1
  fi
done <<EOF_REMOTES
$REMOTE_ROWS
EOF_REMOTES

if [ "$bad" = 1 ]; then
  echo "A template clone must not have a vault configured as a remote" >&2
  echo "(this is a vault -> clone -> public-repo leak path)." >&2
  echo "Remove it:  git remote remove <name>" >&2
  exit 1
fi
echo "assert-no-vault-remote: OK — $N_REMOTES remote URL row(s) checked, none vault-shaped; ${#GLOBS[@]} pattern(s) from $N_PATFILES pattern file(s) applied"
exit 0
