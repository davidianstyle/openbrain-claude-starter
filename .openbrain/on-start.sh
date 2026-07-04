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

# Only pull if the repo has a remote tracking branch — and only ever
# fast-forward. A SessionStart hook must never rebase or stash: with the old
# `git pull --rebase --autostash`, a rebase conflict silently sequestered
# uncommitted vault notes into an autostash reachable only via `git fsck`,
# while the hook reported a non-fatal pull failure and left the repo
# mid-rebase. `--ff-only` either applies cleanly or refuses and touches
# nothing; reconciling a divergence is an interactive job, never a hook's.
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  if pull_out="$(git pull --ff-only 2>&1)"; then
    : # already up to date, or clean fast-forward
  elif git merge-base --is-ancestor '@{u}' HEAD 2>/dev/null; then
    # Remote isn't ahead of us, so there was nothing to fast-forward and the
    # failure is environmental (offline, auth, ...). Quiet non-fatal note.
    log "pull failed (non-fatal): $(printf '%s' "$pull_out" | tail -1)"
  else
    log "!! PULL SKIPPED — cannot fast-forward from the remote."
    log "!! $(printf '%s' "$pull_out" | tail -1)"
    log "!! Local and remote histories have diverged (or incoming changes"
    log "!! overlap uncommitted edits). Nothing was rebased, stashed, or"
    log "!! modified — your notes are exactly as you left them."
    log "!! Reconcile interactively when convenient: commit or stash local"
    log "!! edits, then run: git pull --rebase"
  fi
else
  log "no upstream configured, skipping pull"
fi

# Warm Google OAuth access tokens so MCP calls don't pay refresh latency mid-session,
# and surface any revoked refresh tokens up front. Silent on success; logs the tail
# of stderr on failure. Guarded on the venv so this is a no-op on machines that
# haven't run bootstrap/setup.sh yet.
if [[ -x "$VAULT/bootstrap/lib/refresh-google-tokens.sh" && -d "$HOME/.config/openbrain/venv" ]]; then
  refresh_out="$("$VAULT/bootstrap/lib/refresh-google-tokens.sh" 2>&1)" && refresh_rc=0 || refresh_rc=$?
  if printf '%s' "$refresh_out" | grep -q 'OPENBRAIN_AUTH_NUDGE_BEGIN'; then
    # Google auth settings changed — surface the friendly reconnect nudge
    # verbatim (regardless of probe exit code) so the operator is offered a
    # reconnect rather than hitting silent failures mid-session.
    log "Google auth settings changed — offer to reconnect (ask first, let the operator pick which accounts):"
    printf '%s\n' "$refresh_out" \
      | sed -n '/OPENBRAIN_AUTH_NUDGE_BEGIN/,/OPENBRAIN_AUTH_NUDGE_END/p' \
      | grep -vE 'OPENBRAIN_AUTH_NUDGE_(BEGIN|END)' >&2
  elif (( refresh_rc != 0 )); then
    log "google token refresh: $(printf '%s' "$refresh_out" | tail -3 | tr '\n' ' ')"
  fi
fi

exit 0
