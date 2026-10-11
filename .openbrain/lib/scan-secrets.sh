#!/usr/bin/env bash
# scan-secrets.sh — scan files for hardcoded secret literals before they are
# copied to a runtime locus (sync model DP3: deploy-path secret scan).
#
# reconcile-runtime.sh is SECRET-BLIND by design: it detects launcher drift and
# delegates the copy to register-mcps.sh without ever inspecting content. This
# script is the gate that runs in the --apply path BEFORE the copy, over the
# managed launcher sources (.openbrain/lib/*-mcp.sh, _common.sh). Launchers must
# reference secrets via env vars ($SLACK_USER_TOKEN, ...) and never embed
# literals — this catches the embed.
#
# Usage: scan-secrets.sh <file> [<file> ...]
#        (an existing non-regular path, e.g. a directory, is skipped and counted;
#         a path that does not exist is CANNOT-CHECK)
# Exit:  0 = clean (at least one file scanned, no match, no read error),
#        1 = a secret pattern matched (wins over 3 when both occur),
#        2 = usage error,
#        3 = CANNOT-CHECK (a path is missing or unreadable, or zero files were scanned).
# Output is MASKED: a hit prints file:line and the rule name, never the matched
# text. A coverage line always prints. Everything goes to stderr.
#
# 40-hex rule: a 40-hex string is blocked unless it resolves as a git object
# (`git cat-file -e`) in one of a fixed, declared repo list, printed every run:
# this script's own repo, the template clone (OPENBRAIN_TEMPLATE_DIR, default
# ~/openbrain-claude-starter), and the source checkout of each scanned launcher
# that carries an `# openbrain-mcp:` declaration, resolved by _mcp-decl.sh beside
# this script (root=/<l>.dir= from mcp-config apply). A listed repo that is
# missing or not a git repo is printed as such. Git's all-zero null id is
# always excluded.

set -uo pipefail
{ set +x; } 2>/dev/null   # an inherited xtrace would echo matched text to stderr

# bash semantics throughout (the resolver sourced below is bash): re-exec if run by another shell.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

[ "$#" -ge 1 ] || { echo "scan-secrets: usage: scan-secrets.sh <file>..." >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Rules: "<name><TAB><ERE>", one per line, matched with grep -iE. A rule is
# removed by deleting its one line. CRED is a credential-named identifier: its LAST
# _/- separated component is a keyword ("pat" only as a suffix, X_PAT), and it
# starts at a word boundary, so TOKEN_DIR, TOKEN_VAR, pat= and "compat" are not
# credential names. Declared limit: a keyword followed by a suffix
# (FOO_TOKEN_<SLUG>) is not a credential name; such secrets are caught by shape.
# Value rules exempt '$' expansions ($X, ${X}, ${!X}, $(...)), placeholders
# starting with '<', paths starting with / ~ or ., and values containing ':'
# (URLs, host:port) -- the Asana PAT, which has a ':', has its own rule.
CRED='(([A-Za-z0-9]+[_-])*(secret|token|passwd|password|api[_-]?key|(secret|access|private|service|signing)[_-]?key|credentials?|auth)|([A-Za-z0-9]+[_-])+pat)'
B='(^|[^A-Za-z0-9_])'
END='([[:space:]]*([,;)}#&|\\]|$))'
QV="[^\"'\$<[:space:]/~.:][^\"'\$[:space:]:]{7,}"          # quoted value body
UV='[A-Za-z0-9_+@%!^,-][A-Za-z0-9_./+@=%!^~,-]{7,}'      # unquoted value
T="$(printf '\t')"
RULES="
slack-token${T}xox[abcdeoprs]-[A-Za-z0-9-]{8,}
slack-app-token${T}xapp-[A-Za-z0-9-]{10,}
google-access-token${T}ya29\\.[0-9A-Za-z_-]{10,}
google-api-key${T}AIza[0-9A-Za-z_-]{35}
google-client-secret${T}GOCSPX-[0-9A-Za-z_-]{10,}
google-refresh-token${T}1//0[0-9A-Za-z_-]{20,}
github-token${T}gh[pousr]_[A-Za-z0-9]{30,}
github-pat${T}github_pat_[A-Za-z0-9_]{20,}
anthropic-key${T}sk-ant-[A-Za-z0-9_-]{20,}
openai-key${T}(^|[^A-Za-z0-9])sk-(proj-|svcacct-|admin-)?[A-Za-z0-9]{20,}
bearer-token${T}bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,}
private-key${T}-----BEGIN [A-Z ]*PRIVATE KEY-----
asana-token${T}(^|[^0-9])[0-9]/[0-9]{10,}(/[0-9]{10,})?:[0-9A-Za-z]{20,}
asana-pat-assignment${T}ASANA_PAT[A-Z_]*=[[:space:]]*[\"']?[^[:space:]\"'\$<][^[:space:]\"']*
cred-quoted-literal${T}${B}${CRED}[\"']?[[:space:]]*[:=][[:space:]]*[\"']${QV}[\"']${END}
cred-quoted-assignment${T}${B}${CRED}=[\"']${QV}[\"']
cred-unquoted-literal${T}${B}${CRED}=${UV}([[:space:];&|)#]|\$)
cred-flag-literal${T}(^|[[:space:]])--([A-Za-z0-9]+-)*(secret|token|passwd|password|api-?key|(secret|access|private|service|signing)-?key|credentials?|auth)([[:space:]]+|=)[\"']?${UV}[\"']?([[:space:];&|)#]|\$)
cred-default-literal${T}\\\$\\{(([A-Za-z0-9]+_)*(secret|token|passwd|password|api_?key|(secret|access|private|service|signing)_?key|credentials?|auth)|([A-Za-z0-9]+_)+pat)(:?[-=])[\"']?[^\$}\"'<[:space:]]
hex40${T}\\b[0-9a-f]{40}\\b
"

# ---- sha-exclusion repo list (printed every run) --------------------------------
REPOS=(); repo_desc=""
add_repo() {  # add_repo <label> <path-or-INVALID:...>
  local label="$1" p="$2" r
  case "$p" in
    INVALID:*) repo_desc="${repo_desc}  ${label}: unresolvable (${p#INVALID:})"$'\n'; return ;;
  esac
  for r in ${REPOS[@]+"${REPOS[@]}"}; do [ "$r" = "$p" ] && return; done
  if [ ! -d "$p" ]; then repo_desc="${repo_desc}  ${label}: ${p} (missing)"$'\n'; return; fi
  if ! env -u GIT_DIR -u GIT_WORK_TREE git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
    repo_desc="${repo_desc}  ${label}: ${p} (not a readable git repo)"$'\n'; return
  fi
  REPOS+=("$p"); repo_desc="${repo_desc}  ${label}: ${p} (ok)"$'\n'
}
self_repo="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" \
  || self_repo="INVALID:$HERE is not inside a git repo"
add_repo "own repo" "$self_repo"
add_repo "template clone" "${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
if [ -f "$HERE/_mcp-decl.sh" ]; then
  # side-effect free: sets two path variables and defines functions
  # shellcheck source=_mcp-decl.sh
  . "$HERE/_mcp-decl.sh"
  if [ -f "$MCP_CONFIG_FILE" ]; then repo_desc="${repo_desc}  mcp-config: ${MCP_CONFIG_FILE}"$'\n'
  else repo_desc="${repo_desc}  mcp-config: ${MCP_CONFIG_FILE} absent (resolver defaults apply)"$'\n'; fi
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    [ "$(decl_count "$f")" = 1 ] || continue
    add_repo "mcp $(basename "$f" .sh)" "$(mcp_root "$f")"
  done
else
  repo_desc="${repo_desc}  mcp checkouts: none listed (no _mcp-decl.sh beside this script)"$'\n'
fi

is_git_object() {  # is_git_object <hex> — resolves in any listed repo? (or is git's null id)
  local r
  case "$1" in 0000000000000000000000000000000000000000) return 0 ;; esac
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    env -u GIT_DIR -u GIT_WORK_TREE GIT_NO_LAZY_FETCH=1 git -C "$r" cat-file -e "$1" 2>/dev/null && return 0
  done
  return 1
}

# ---- scan ----------------------------------------------------------------------
fail=0; cannot=0; scanned=0; skipped=0; unreadable=0; missing=0; hex_hits=0; hex_excl=0; hex_blocked=0
for f in "$@"; do
  if [ ! -e "$f" ]; then
    echo "scan-secrets: CANNOT-CHECK: no such file (or a dangling link): $f" >&2
    missing=$((missing+1)); cannot=1; continue
  fi
  if [ ! -f "$f" ]; then skipped=$((skipped+1)); continue; fi
  read_ok=1
  while IFS="$T" read -r name pat; do
    [ -n "$name" ] || continue
    # grep's own stderr passes through (it names the file, never content): an
    # unreadable file must be loud. -o output stays internal and is never printed.
    out="$(grep -noiE -e "$pat" "$f")"; rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$name" = hex40 ]; then
        while IFS= read -r hit; do
          hex_hits=$((hex_hits+1))
          if is_git_object "${hit#*:}"; then hex_excl=$((hex_excl+1)); continue; fi
          hex_blocked=$((hex_blocked+1)); fail=1
          echo "scan-secrets: SECRET-shaped match: $f:${hit%%:*} [hex40] 40-hex not found as a git object in ${#REPOS[@]} listed repo(s)" >&2
        done <<< "$out"
      else
        fail=1
        printf '%s\n' "$out" | cut -d: -f1 | sort -un | while IFS= read -r ln; do
          echo "scan-secrets: SECRET-shaped match: $f:$ln [$name]" >&2
        done
      fi
    elif [ "$rc" -ne 1 ]; then
      echo "scan-secrets: CANNOT-CHECK: grep failed (rc=$rc) on $f" >&2
      read_ok=0; break
    fi
  done <<EOF
$RULES
EOF
  if [ "$read_ok" = 1 ]; then scanned=$((scanned+1)); else unreadable=$((unreadable+1)); cannot=1; fi
done

printf 'scan-secrets: sha-exclusion repos (%s usable):\n%s' "${#REPOS[@]}" "$repo_desc" >&2
echo "scan-secrets: $scanned file(s) scanned, $skipped skipped (not regular files), $unreadable unreadable, $missing missing; 40-hex: $hex_hits hit(s), $hex_excl sha-excluded, $hex_blocked blocked" >&2
if [ "$scanned" -eq 0 ]; then
  echo "scan-secrets: CANNOT-CHECK: zero files scanned" >&2
  cannot=1
fi

if [ "$fail" = 1 ]; then
  echo "scan-secrets: refusing to deploy. Move the secret to ${OPENBRAIN_ENV_FILE:-~/.config/openbrain/.env}" >&2
  echo "and reference it via an env var in the launcher. (False positive? adjust the rule.)" >&2
  exit 1
fi
if [ "$cannot" = 1 ]; then
  echo "scan-secrets: CANNOT-CHECK — refusing to report clean; see the lines above." >&2
  exit 3
fi
exit 0
