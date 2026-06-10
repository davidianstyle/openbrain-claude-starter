#!/usr/bin/env bash
# OpenBrain vault SessionStart hook.
# Pulls latest from origin/main (rebase) so the session starts current.
# Fails soft: network errors never block Claude from starting.

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$VAULT" || exit 0

log() { printf '[on-start] %s\n' "$*" >&2; }

# Self-heal the pre-push guardrail (mirrors setup.sh's pre-commit linking):
# the vault never pushes to a protected remote (see pre-push.sh), and the
# hook has to survive fresh clones and propagate via template pulls with no
# human steps.
HOOKS_DIR="$(git rev-parse --git-path hooks 2>/dev/null)"
if [[ -n "$HOOKS_DIR" && -f "$VAULT/.openbrain/pre-push.sh" ]]; then
  [[ "$HOOKS_DIR" != /* ]] && HOOKS_DIR="$VAULT/$HOOKS_DIR"
  HOOK="$HOOKS_DIR/pre-push"
  if [[ ! -e "$HOOK" ]] || ! cmp -s "$VAULT/.openbrain/pre-push.sh" "$HOOK"; then
    mkdir -p "$HOOKS_DIR"
    ln -sf "$VAULT/.openbrain/pre-push.sh" "$HOOK"
    chmod +x "$VAULT/.openbrain/pre-push.sh"
    log "pre-push guardrail (re)linked"
  fi
fi

# Only pull if the repo has a remote tracking branch
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  git pull --rebase --autostash 2>&1 || log "pull failed (non-fatal)"
else
  log "no upstream configured, skipping pull"
fi

# Warm Google OAuth access tokens so MCP calls don't pay refresh latency mid-session,
# and surface any revoked refresh tokens up front. Silent on success; logs the tail
# of stderr on failure. Guarded on the venv so this is a no-op on machines that
# haven't run bootstrap/setup.sh yet.
if [[ -x "$VAULT/bootstrap/lib/refresh-google-tokens.sh" && -d "$HOME/.config/openbrain/venv" ]]; then
  if ! refresh_out="$("$VAULT/bootstrap/lib/refresh-google-tokens.sh" 2>&1)"; then
    log "google token refresh: $(printf '%s' "$refresh_out" | tail -3 | tr '\n' ' ')"
  fi
fi

exit 0
