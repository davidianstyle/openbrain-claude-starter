#!/usr/bin/env bash
# reconcile-runtime.sh — make the per-machine RUNTIME match the vault's tracked
# source, so "pulled == live". The deploy step the pull (and on-start) invoke.
#
# Deterministic + idempotent: same inputs → same result, re-runnable after any
# crash. Keys on RUNTIME-vs-SOURCE drift, NOT on any pull delta or marker — so
# it catches drift from ANY cause (incl. a launcher that drifted from a pull
# that predates this feature), at any time, even at the same build.
#
# SECRET-BLIND: drift DETECTION reads only tracked files + settings.json
# structure — never .env. The single step that needs secrets (the ~/.claude.json
# registry rewrite) is delegated wholesale to register-mcps.sh (already trusted)
# and only runs on --apply. This keeps the pull's read-only/safe-anytime contract
# intact everywhere except that one audited subprocess.
#
# Loci (what a PULL can change):
#   - MCP launchers: $VAULT/.openbrain/lib/{*-mcp.sh,_common.sh} → $LIB_DIR,
#     plus orphan *-mcp.sh in $LIB_DIR. Scoped to exactly that set — shims/,
#     clone-tier scripts, and .orphaned-launchers/ are never considered.
#   - Claude hook wiring: openbrain entries in .claude/settings.json.
# Account-config drift (accounts added/removed) is NOT handled here — that goes
# through add-account → register-mcps directly. This is tracked-file → runtime.
#
# Modes:
#   --check (default): report drift; exit 0 = in sync, 10 = drift present.
#   --apply          : converge, then report whether a Claude restart is needed.
#
# Test seam (NEVER point at live config in a test): OPENBRAIN_LIB_DIR,
# OPENBRAIN_CLAUDE_JSON, OPENBRAIN_ENV_FILE, OPENBRAIN_SETTINGS_FILE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="$(cd "$HERE/../.." && pwd)"          # .openbrain/lib → vault root
SRC_LIB="$VAULT/.openbrain/lib"

# Runtime targets — same override scheme as bootstrap/lib/common.sh.
CONFIG_DIR="${OPENBRAIN_CONFIG_DIR:-$HOME/.config/openbrain}"
LIB_DIR="${OPENBRAIN_LIB_DIR:-$CONFIG_DIR/lib}"
ENV_FILE="${OPENBRAIN_ENV_FILE:-$CONFIG_DIR/.env}"
CLAUDE_JSON="${OPENBRAIN_CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS_FILE="${OPENBRAIN_SETTINGS_FILE:-$VAULT/.claude/settings.json}"

MODE="${1:---check}"

log()  { printf '[reconcile] %s\n' "$*"; }
warn() { printf '[reconcile] WARNING: %s\n' "$*" >&2; }

# ---------- drift detection (secret-blind; both modes need it) ----------
findings=""
launcher_drift=0
hook_drift=0

# Launchers: changed or missing (managed set only: *-mcp.sh + _common.sh).
for f in "$SRC_LIB"/*-mcp.sh "$SRC_LIB/_common.sh"; do
  [ -e "$f" ] || continue
  dest="$LIB_DIR/$(basename "$f")"
  if ! cmp -s "$f" "$dest" 2>/dev/null; then
    findings="${findings}  launcher: $(basename "$f") (changed or missing in runtime)"$'\n'
    launcher_drift=1
  fi
done
# Launchers: orphaned (managed *-mcp.sh in runtime with no tracked source).
shopt -s nullglob
for dest in "$LIB_DIR"/*-mcp.sh; do
  if [ ! -e "$SRC_LIB/$(basename "$dest")" ]; then
    findings="${findings}  launcher: $(basename "$dest") (orphan — no tracked source)"$'\n'
    launcher_drift=1
  fi
done
shopt -u nullglob

# Hook wiring: reuse wire-claude-hooks on a COPY and see if it would change
# anything. No bespoke check logic to drift out of sync with the wirer, and
# touches no secrets.
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
if [ -f "$SETTINGS_FILE" ]; then
  cp "$SETTINGS_FILE" "$tmpdir/settings.json"
  # A wirer failure must count as drift, not be swallowed: with a bare
  # `|| true`, a crash leaves the copy untouched, cmp matches, and the check
  # falsely reports no hook drift. Flagging drift instead routes --apply to
  # run the wirer against the live file, where the real error surfaces loudly.
  if bash "$VAULT/bootstrap/lib/wire-claude-hooks.sh" "$VAULT" "$tmpdir/settings.json" >/dev/null 2>&1; then
    if ! cmp -s "$SETTINGS_FILE" "$tmpdir/settings.json" 2>/dev/null; then
      findings="${findings}  hook-wiring: openbrain SessionStart/Stop entries need (re)wiring"$'\n'
      hook_drift=1
    fi
  else
    findings="${findings}  hook-wiring: wire-claude-hooks.sh FAILED against current settings.json (drift state unknown — run --apply to surface the error)"$'\n'
    hook_drift=1
  fi
else
  findings="${findings}  hook-wiring: no settings.json (hooks not wired)"$'\n'
  hook_drift=1
fi

drift=0
{ [ "$launcher_drift" = 1 ] || [ "$hook_drift" = 1 ]; } && drift=1

# ---------- --check ----------
if [ "$MODE" = "--check" ]; then
  if [ "$drift" = 0 ]; then
    log "runtime in sync with vault — nothing to deploy"
    exit 0
  fi
  log "runtime drift vs vault (pull + deploy to make it live):"
  printf '%s' "$findings"
  log "run: bash .openbrain/lib/reconcile-runtime.sh --apply"
  exit 10
fi

# ---------- --apply ----------
if [ "$MODE" != "--apply" ]; then
  warn "unknown mode '$MODE' (use --check or --apply)"; exit 2
fi

if [ "$drift" = 0 ]; then
  log "runtime already in sync — nothing to apply"
  exit 0
fi

restart=0

if [ "$launcher_drift" = 1 ]; then
  # register-mcps does launcher copy + scoped registry rewrite + orphan reconcile.
  # It needs .env and the registry file; on a machine without them (no bootstrap
  # yet) skip with a warning rather than hard-failing the pull.
  if [ -f "$ENV_FILE" ] && [ -f "$CLAUDE_JSON" ]; then
    log "deploying launchers + registry via register-mcps.sh"
    bash "$VAULT/bootstrap/lib/register-mcps.sh"
    restart=1
  else
    warn "launcher drift present but $ENV_FILE or $CLAUDE_JSON missing —"
    warn "run bootstrap/setup.sh to initialize; skipping launcher/registry deploy"
  fi
fi

if [ "$hook_drift" = 1 ]; then
  log "wiring Claude hooks via wire-claude-hooks.sh"
  bash "$VAULT/bootstrap/lib/wire-claude-hooks.sh" "$VAULT" "$SETTINGS_FILE"
  restart=1
fi

if [ "$restart" = 1 ]; then
  printf '\n'
  log "RESTART REQUIRED — the running Claude session still has the OLD runtime"
  log "loaded; restart Claude Code so the deployed launchers/hooks take effect."
fi
exit 0
