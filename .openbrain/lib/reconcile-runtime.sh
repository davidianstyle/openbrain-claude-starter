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
#   - MCP launchers: $VAULT/.openbrain/lib/{*-mcp.sh,_common.sh,_mcp-decl.sh,mcp-local-build.sh} → $LIB_DIR,
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

# Sourced ONLY for managed_launchers() — the single definition of the deployed
# launcher set, shared with register-mcps.sh and minimal-init.sh. Side-effect
# free: it computes paths and defines helpers, never reads .env (secret-blind
# contract intact). Our own log/warn below override its versions.
# shellcheck source=../../bootstrap/lib/common.sh
source "$VAULT/bootstrap/lib/common.sh"

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

# Launchers: changed or missing (managed_launchers in common.sh is the single
# definition of the set: *-mcp.sh + _common.sh + _mcp-decl.sh + mcp-local-build.sh).
while IFS= read -r f; do
  dest="$LIB_DIR/$(basename "$f")"
  if ! cmp -s "$f" "$dest" 2>/dev/null; then
    findings="${findings}  launcher: $(basename "$f") (changed or missing in runtime)"$'\n'
    launcher_drift=1
  fi
done < <(managed_launchers "$SRC_LIB")
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
# touches no secrets. The wirer writes only on a semantic change, so a pure
# formatting difference (another tool's serialization, legacy \uXXXX escapes)
# never reads as drift here.
#
# DELIBERATE EXCLUSION: canonical timeout/statusMessage bumps never flag as
# drift and never propagate to existing installs. The wirer applies CANON
# values only when CREATING a missing entry — on an existing entry a
# user-tuned value is indistinguishable from a stale canonical one, so
# "pulled == live" covers the script path, entry presence, and dedup, NOT
# those two fields. Changing them for existing installs is a hands-on
# migration, not a reconcile.
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
if [ -f "$SETTINGS_FILE" ]; then
  cp "$SETTINGS_FILE" "$tmpdir/settings.json"
  # A wirer failure must count as drift, not be swallowed: with a bare
  # `|| true`, a crash leaves the copy untouched, cmp matches, and the check
  # falsely reports no hook drift. Flagging drift instead routes --apply to
  # run the wirer against the live file, where the real error surfaces loudly.
  # rc=4 is the wirer's REFUSAL contract (an owned entry it cannot safely
  # repair) — a determinate state needing a manual fix, not an unknown one;
  # report it as such rather than as a crash.
  wirer_rc=0
  bash "$VAULT/bootstrap/lib/wire-claude-hooks.sh" "$VAULT" "$tmpdir/settings.json" >/dev/null 2>&1 || wirer_rc=$?
  if [ "$wirer_rc" = 0 ]; then
    if ! cmp -s "$SETTINGS_FILE" "$tmpdir/settings.json" 2>/dev/null; then
      findings="${findings}  hook-wiring: openbrain SessionStart/Stop entries need (re)wiring"$'\n'
      hook_drift=1
    fi
  elif [ "$wirer_rc" = 4 ]; then
    findings="${findings}  hook-wiring: an openbrain hook entry needs a MANUAL fix — the wirer refused to auto-repair it (run --apply to see the exact instructions)"$'\n'
    hook_drift=1
  else
    findings="${findings}  hook-wiring: wire-claude-hooks.sh FAILED (rc=$wirer_rc) against current settings.json (drift state unknown — run --apply to surface the error)"$'\n'
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
restart_announced=0
announce_restart(){
  [ "$restart_announced" = 1 ] && return 0
  restart_announced=1
  printf '\n'
  log "RESTART REQUIRED — the running Claude session still has the OLD runtime"
  log "loaded; restart Claude Code so the deployed launchers/hooks take effect."
}

# registered_launcher_names : basenames (no .sh) of *-mcp.sh launchers under
# LIB_DIR that a stdio entry in ~/.claude.json (user scope + this vault's project
# entry) actually points at, with the directory compared by REALPATH. The SAME scope and filter as check-updates.sh's
# registered(), so reconcile builds only what a machine actually runs (otherwise
# every machine would clone and build every MCP, not just the ones it registers).
# An unreadable registry builds nothing and says so (never a silent skip).
registered_launcher_names(){
  [ -f "$CLAUDE_JSON" ] || return 0
  python3 - "$CLAUDE_JSON" "$VAULT" "$LIB_DIR" <<'PY'
import json, os, sys
claude_json, vault, lib_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(claude_json))
    servers = dict(d.get("mcpServers") or {})
except Exception as e:
    print(f"[reconcile] WARNING: cannot read the MCP registry ({e}) — no source builds this run", file=sys.stderr)
    sys.exit(0)
servers.update(((d.get("projects") or {}).get(vault) or {}).get("mcpServers") or {})
lib_real = os.path.realpath(lib_dir)
for v in servers.values():
    if not isinstance(v, dict) or v.get("type", "stdio") != "stdio":
        continue
    cmd = v.get("command", "")
    if not cmd:
        continue
    d1, base = os.path.split(cmd)
    if base.endswith("-mcp.sh") and os.path.realpath(d1) == lib_real:
        print(base[:-3])
PY
}

# build_registered_sources : for each registered launcher whose EFFECTIVE shape
# is fork/checkout, or npm on the canary channel, run ensure_mcp_server in a
# subshell (never let one bad build abort the rest — or the whole reconcile,
# since it runs under set -euo pipefail) — then the origin-mismatch check.
# npm stable is skipped: npx fetches it, nothing to build here.
build_registered_sources(){
  local name l shape
  # Source the VAULT'S OWN _mcp-decl.sh (next to this script, HERE) — never the
  # installed $LIB_DIR copy, which on a pulled-but-not-deployed machine may be
  # stale or (right now, mid-deploy) briefly absent. Same rule as check-updates.sh.
  [ -f "$HERE/_mcp-decl.sh" ] || { warn "_mcp-decl.sh not found at $HERE — skipping source builds"; return 0; }
  # shellcheck source=/dev/null
  source "$HERE/_mcp-decl.sh"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    l="$LIB_DIR/$name.sh"; [ -f "$l" ] || continue
    shape="$(mcp_eff_shape "$l")"
    case "$shape" in
      fork|checkout) ( ensure_mcp_server "$name" ) || warn "$name: ensure_mcp_server failed — see output above" ;;
    esac
  done < <(registered_launcher_names)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    l="$LIB_DIR/$name.sh"; [ -f "$l" ] || continue
    case "$(mcp_eff_shape "$l")" in fork|checkout) : ;; *) continue ;; esac
    local dir url actual
    dir="$(mcp_root "$l")"; case "$dir" in INVALID:*) continue ;; esac
    [ -d "$dir/.git" ] || continue
    url="$(mcp_get "$l" url)"; case "$url" in INVALID:*) continue ;; esac
    if ! actual="$(git -C "$dir" remote get-url origin 2>&1)"; then
      warn "$name: CANNOT-CHECK origin — 'git remote get-url origin' failed in $dir: $actual"; continue
    fi
    _mcp_url_eq "$actual" "$url" \
      || warn "$name: origin is $actual, resolved declaration says $url — re-point: git -C $dir remote set-url origin $url — or, if that origin is intentional, set $name.url= (or owner=) in $MCP_CONFIG_FILE"
  done < <(registered_launcher_names)
}

if [ "$launcher_drift" = 1 ]; then
  # DP3: reconcile is otherwise secret-blind. This is the one content check, and
  # it gates the copy register-mcps is about to perform — a launcher carrying an
  # inline secret must never reach the runtime locus. Scan the managed SOURCES.
  SCAN="$SRC_LIB/scan-secrets.sh"
  # managed_launchers, not a raw glob: an unmatched glob would hand the scanner
  # a literal '*-mcp.sh' path. The ${arr[@]+...} expansion guards the empty set
  # under bash 3.2 + set -u (an empty array reads as unbound there); with zero
  # managed files there is nothing to scan or deploy-copy, so the scan is
  # skipped rather than fed nothing.
  scan_files=()
  while IFS= read -r f; do scan_files+=("$f"); done < <(managed_launchers "$SRC_LIB")
  if [ ! -f "$SCAN" ]; then
    warn "scan-secrets.sh not present — deploy-path secret scan SKIPPED."
  elif [ "${#scan_files[@]}" -gt 0 ]; then
    if ! bash "$SCAN" ${scan_files[@]+"${scan_files[@]}"}; then
      warn "deploy ABORTED: a launcher source contains a secret literal (above)."
      warn "Move it to $ENV_FILE and reference it via an env var, then re-run."
      exit 1
    fi
  fi
  # register-mcps does launcher copy + scoped registry rewrite + orphan reconcile.
  # It needs .env and the registry file; on a machine without them (no bootstrap
  # yet) skip with a warning rather than hard-failing the pull.
  if [ -f "$ENV_FILE" ] && [ -f "$CLAUDE_JSON" ]; then
    log "deploying launchers + registry via register-mcps.sh"
    bash "$VAULT/bootstrap/lib/register-mcps.sh"
    restart=1
    # RESTART REQUIRED before the builds start: the launchers are already
    # deployed, and a Bash-tool timeout that kills this call mid-build must
    # not lose the notice.
    announce_restart
    build_registered_sources
  else
    warn "launcher drift present but $ENV_FILE or $CLAUDE_JSON missing —"
    warn "run bootstrap/setup.sh to initialize; skipping launcher/registry deploy"
  fi
fi

wirer_apply_rc=0
if [ "$hook_drift" = 1 ]; then
  log "wiring Claude hooks via wire-claude-hooks.sh"
  # No bare call: under set -e a wirer refusal (rc=4) or crash would abort the
  # script HERE — after launchers were already deployed above — and the
  # RESTART REQUIRED notice below would never print, leaving the user running
  # the old runtime with no signal. Capture the rc, finish the run, exit with
  # it at the end (a refusal must stay loud, not be swallowed into exit 0).
  bash "$VAULT/bootstrap/lib/wire-claude-hooks.sh" "$VAULT" "$SETTINGS_FILE" || wirer_apply_rc=$?
  restart=1
  if [ "$wirer_apply_rc" != 0 ]; then
    warn "wire-claude-hooks.sh exited $wirer_apply_rc — hook wiring is NOT fully converged."
    if [ "$wirer_apply_rc" = 4 ]; then
      warn "It REFUSED one or more entries (exact manual fix printed above); other"
      warn "entries and the launcher deploy above still applied."
    fi
  fi
fi

[ "$restart" = 1 ] && announce_restart
exit "$wirer_apply_rc"
