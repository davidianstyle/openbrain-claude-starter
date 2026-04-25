#!/usr/bin/env bash
# OpenBrain vault SessionStart hook.
# Pulls latest from origin/main (rebase) so the session starts current.
# Fails soft: network errors never block Claude from starting.

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$VAULT" || exit 0

log() { printf '[on-start] %s\n' "$*" >&2; }

# Only pull if the repo has a remote tracking branch
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  git pull --rebase 2>&1 || log "pull failed (non-fatal)"
else
  log "no upstream configured, skipping pull"
fi

exit 0
