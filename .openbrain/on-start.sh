#!/usr/bin/env bash
# OpenBrain vault SessionStart hook.
# Pulls latest from origin/main (fast-forward only) so the session starts
# current. Fails soft: network errors never block Claude from starting.

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$VAULT" || exit 0

log() { printf '[on-start] %s\n' "$*" >&2; }

# Warnings go to STDOUT, not stderr. Empirically verified (2026-07-08): a
# SessionStart hook's stdout is injected into the model's context, while
# stderr with exit 0 is invisible to both the model and the operator — a
# warning on stderr is structurally silent. Routine progress notes stay on
# stderr (log); anything that must change the session's behavior uses warn.
warn() { printf '[on-start] %s\n' "$*"; }

# First error:/fatal: line of a git transcript, else its last line — the last
# line of a multi-line git error is often a fragment ("and the repository
# exists.") or progress noise ("Updating abc123..def456"). Single POSIX awk
# pass: no grep/tail extensions, no pipefail interplay.
err_line() {
  printf '%s\n' "$1" \
    | awk '/^(error|fatal):/ { print; found = 1; exit } NF { last = $0 } END { if (!found) print last }'
}

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
# mid-rebase. Fast-forward either applies cleanly or refuses and touches
# nothing; reconciling a divergence is an interactive job, never a hook's.
# Fetch and merge run separately so a network failure (quiet note) is never
# misreported as a divergence (loud warning) — e.g. offline while behind an
# already-fetched @{u}.
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  # Never prompt from a hook: git and ssh both prompt via /dev/tty, so a
  # credential/passphrase/host-key ask would hang the session start.
  # GIT_TERMINAL_PROMPT=0 fails HTTP credential asks fast; BatchMode does the
  # same for ssh — appended to the user's own ssh command (env var, then
  # core.sshCommand, then plain ssh) so a customized setup keeps working, and
  # an explicit user BatchMode option still wins (ssh: first value obtained
  # for a parameter is used).
  ssh_cmd="${GIT_SSH_COMMAND:-$(git config core.sshCommand 2>/dev/null)}"
  ssh_cmd="${ssh_cmd:-ssh}"   # unset AND explicitly-empty both fall back to ssh
  if ! fetch_out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes" git fetch 2>&1)"; then
    # Couldn't reach the remote (offline, auth, ...). Quiet non-fatal note.
    log "fetch failed (non-fatal): $(err_line "$fetch_out")"
  elif merge_out="$(git merge --ff-only '@{u}' 2>&1)"; then
    : # already up to date, or clean fast-forward
  else
    warn "!! PULL SKIPPED — cannot fast-forward from the remote."
    warn "!! $(err_line "$merge_out")"
    warn "!! Local and remote histories have diverged (or incoming changes"
    warn "!! overlap uncommitted edits). Nothing was rebased, stashed, or"
    warn "!! modified — your notes are exactly as you left them."
    warn "!! Reconcile interactively when convenient: commit or stash local"
    warn "!! edits, then run: git pull --rebase"
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
    warn "Google auth settings changed — offer to reconnect (ask first, let the operator pick which accounts):"
    printf '%s\n' "$refresh_out" \
      | sed -n '/OPENBRAIN_AUTH_NUDGE_BEGIN/,/OPENBRAIN_AUTH_NUDGE_END/p' \
      | grep -vE 'OPENBRAIN_AUTH_NUDGE_(BEGIN|END)'
  elif (( refresh_rc != 0 )); then
    log "google token refresh: $(printf '%s' "$refresh_out" | tail -3 | tr '\n' ' ')"
  fi
fi

# Re-nag on runtime drift: if a pulled change to MCP launchers or hook wiring
# hasn't been deployed to the per-machine runtime, the pull's restart-required
# notice is one-shot — this surfaces it every session until deployed. Fail-soft;
# never blocks session start, and reads nothing secret (--check is secret-blind).
# -f + explicit bash, not -x + direct exec: a lost executable bit (some
# filesystems / cross-platform checkouts) would silently skip the drift check
# — the same silent-failure class it exists to prevent.
if [[ -f "$VAULT/.openbrain/lib/reconcile-runtime.sh" ]]; then
  # Capture the exit code explicitly — an `elif (( $? == 10 ))` reads whatever
  # ran last and silently swallows unexpected codes (crash, permissions), the
  # same silent-failure class the drift check exists to prevent.
  drift_rc=0
  # 2>&1, not 2>/dev/null: --check is secret-blind by contract, so capturing
  # stderr is safe — and on the crash path below it is the only diagnostic
  # (discarding it would make CANNOT-CHECK loud but uninformative).
  drift_out="$(bash "$VAULT/.openbrain/lib/reconcile-runtime.sh" --check 2>&1)" || drift_rc=$?
  if (( drift_rc == 10 )); then
    warn "runtime drift — deployed launchers/hooks are behind the vault:"
    printf '%s\n' "$drift_out" | grep -v '^\[reconcile\]'
    warn "deploy with: bash .openbrain/lib/reconcile-runtime.sh --apply"
  elif (( drift_rc != 0 )); then
    warn "runtime drift check FAILED (exit $drift_rc) — run manually: bash .openbrain/lib/reconcile-runtime.sh --check"
    printf '%s\n' "$drift_out"
  fi
else
  # A checker's absence is itself a finding: silence here would read as
  # "runtime in sync" when the truth is "drift not checked". On a machine
  # that has never deployed the reconciler this is a standing (accurate)
  # notice that the check isn't running — not an error.
  warn "MISSING: .openbrain/lib/reconcile-runtime.sh — runtime drift NOT checked this session"
fi

exit 0
