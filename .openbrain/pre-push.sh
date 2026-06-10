#!/usr/bin/env bash
# OpenBrain guardrail: the vault never pushes to a protected remote.
#
# Every ref in a vault repo carries personal history, so pushes to public
# template/starter repos are blocked wholesale — no ref parsing, no topic-
# branch exceptions. Legitimate template contributions go through
# /push-openbrain-template, which genericizes and pushes from a separate
# template clone, never from the vault.
#
# Protected URL patterns come from .openbrain/protected-remotes (one shell
# glob per line; blank lines and # comments ignored). If that file does not
# exist, the default pattern below applies. If your own private vault remote
# legitimately matches the default (e.g. a private fork whose URL contains
# "openbrain-claude-starter"), create protected-remotes with the patterns
# that fit your setup. Deliberate one-off override: git push --no-verify.
#
# Linked into .git/hooks/pre-push by setup.sh and re-linked (self-healing)
# by on-start.sh.

# Hooks run from the top of the working tree, but resolve it explicitly —
# BASH_SOURCE points into .git/hooks/ when invoked via the symlink.
VAULT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
url="$2"

patterns=()
if [[ -f "$VAULT/.openbrain/protected-remotes" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    patterns+=("$line")
  done < "$VAULT/.openbrain/protected-remotes"
else
  patterns=("*openbrain-claude-starter*")
fi

for pat in "${patterns[@]}"; do
  # shellcheck disable=SC2254  # $pat is deliberately an unquoted glob
  case "$url" in
    $pat)
      echo "pre-push BLOCKED: '$url' matches protected pattern '$pat'." >&2
      echo "Vault refs carry personal history; this remote must not receive them." >&2
      echo "Template contributions: use /push-openbrain-template (pushes from the" >&2
      echo "template clone, not the vault). Adjust patterns in" >&2
      echo ".openbrain/protected-remotes. Deliberate override: git push --no-verify." >&2
      exit 1
      ;;
  esac
done
exit 0
