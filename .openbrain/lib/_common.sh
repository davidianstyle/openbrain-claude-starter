#!/usr/bin/env bash
# Shared helpers sourced by every OpenBrain MCP launcher.
#
# Responsibilities:
#   - Locate ~/.config/openbrain/.env and source it
#   - Ensure `npx` is on PATH, trying several install methods
#   - Suppress accidental OAuth browser launches from MCP packages
#   - Provide die() / require_env() helpers

set -euo pipefail

ENV_FILE="${ENV_FILE:-$HOME/.config/openbrain/.env}"

die() { printf 'openbrain mcp: %s\n' "$*" >&2; exit 1; }

# Add a directory to PATH front if it exists and has node
_try_node_bin() {
  local candidate="$1"
  [[ -d "$candidate" && -x "$candidate/node" ]] || return 1
  case ":$PATH:" in
    *":$candidate:"*) ;;
    *) export PATH="$candidate:$PATH" ;;
  esac
  return 0
}

_npx_works() {
  command -v npx >/dev/null 2>&1 || return 1
  # Guard against shims (asdf/rtx/mise) that resolve but fail at runtime
  # because no version is selected in the current directory.
  npx --version >/dev/null 2>&1
}

ensure_node_on_path() {
  # Already resolvable AND actually executable?
  _npx_works && return 0

  # asdf (currently active node version)
  if command -v asdf >/dev/null 2>&1; then
    local asdf_shim
    asdf_shim="$(asdf which node 2>/dev/null || true)"
    [[ -n "$asdf_shim" ]] && _try_node_bin "$(dirname "$asdf_shim")" && return 0
  fi

  # asdf (any installed node version, newest wins)
  if [[ -d "$HOME/.asdf/installs/nodejs" ]]; then
    local latest
    latest="$(ls -1 "$HOME/.asdf/installs/nodejs" 2>/dev/null | sort -V | tail -n 1 || true)"
    [[ -n "$latest" ]] && _try_node_bin "$HOME/.asdf/installs/nodejs/$latest/bin" && return 0
  fi

  # nvm (default alias)
  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    local latest
    latest="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -n 1 || true)"
    [[ -n "$latest" ]] && _try_node_bin "$HOME/.nvm/versions/node/$latest/bin" && return 0
  fi

  # Homebrew
  _try_node_bin /opt/homebrew/bin && return 0
  _try_node_bin /usr/local/bin && return 0

  # Last resort
  _try_node_bin /usr/bin && return 0

  die "npx not found on PATH — install Node.js (brew install node, asdf, or nvm) and retry"
}

# Install a shim that intercepts `open` (and sets $BROWSER) so MCP packages
# cannot silently launch OAuth browser tabs every time Claude Code starts.
#
# Defensive: some third-party MCPs attempt an OAuth flow on startup when
# their token cache is missing or stale, popping browser windows for every
# configured account on every session. Tokens are managed out-of-band via
# bootstrap/lib/add-google-account.sh and bootstrap/lib/refresh-google-tokens.sh
# — re-run those when a refresh actually fails.
install_browser_suppressor() {
  local shim_dir="$HOME/.config/openbrain/lib/shims"
  local shim="$shim_dir/open"
  if [[ ! -x "$shim" ]]; then
    mkdir -p "$shim_dir"
    cat > "$shim" <<'SHIM'
#!/usr/bin/env bash
# OpenBrain browser-launch suppressor. Any MCP package that tries to
# launch a browser via `open <url>` (macOS) or $BROWSER hits this shim
# and fails non-interactively instead of popping windows on every
# Claude Code startup. Re-run bootstrap/lib/refresh-google-tokens.sh
# to re-auth when a real token refresh failure happens.
echo "openbrain: suppressed browser launch ($*)" >&2
exit 1
SHIM
    chmod 755 "$shim"
  fi
  case ":$PATH:" in
    *":$shim_dir:"*) ;;
    *) export PATH="$shim_dir:$PATH" ;;
  esac
  export BROWSER="$shim"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found (run bootstrap/setup.sh)"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}

require_env() {
  local var="$1"
  [[ -n "${!var:-}" ]] || die "$var not set in $ENV_FILE"
}

# --- declared launchers ------------------------------------------------------
# A launcher that carries a `# openbrain-mcp:` line resolves its source location,
# URL and shape through _mcp-decl.sh (mcp_get / mcp_shape), and installs itself
# via that file's ensure_mcp_server -- the ONE install path, shared with setup-time
# `add-*.sh` calls (bootstrap/lib/common.sh sources the installed copy).
# shellcheck source=_mcp-decl.sh
source "$(dirname "${BASH_SOURCE[0]}")/_mcp-decl.sh"

# The launcher is the bottom of the source stack (the script Claude Code exec'd),
# however deeply these helpers are nested.
_declaring_launcher(){ printf '%s' "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}"; }

declared_entry(){ mcp_entry "$(_declaring_launcher)"; }

# _check_declared <launcher> : exactly one declaration line and a valid update mode in the
# policy file, or die — an invalid value stops the launcher, never a silent default.
_check_declared(){
  local m
  [[ "$(decl_count "$1")" == 1 ]] || die "$(basename "$1"): needs exactly one '# openbrain-mcp:' line"
  m="$(mcp_update_mode "$1")"; [[ "$m" != INVALID:* ]] || die "$(basename "$1"): ${m#INVALID:}"
}

# npm-shaped launchers: exec the server on this machine's channel (_mcp-decl.sh):
#   stable -> npx --yes <pkg>@<last-applied version> [args...]
#   canary -> node <src>/<sub>/<entry> [args...], lazily cloned from url= + built by
#             ensure_mcp_server (_mcp-decl.sh: tests gate, last-good dist,
#             dist/.built-from, build lock). Existence-only at launch; freshness
#             is the checker's job. An invalid channel dies here — never a
#             silent default.
# Arguments are passed to the server unchanged on either channel, e.g.
# `exec_declared_npm --slug "$SLUG"` for a server that takes its account as a flag.
exec_declared_npm(){
  local l ch; l="$(_declaring_launcher)"; _check_declared "$l"
  ch="$(mcp_channel "$l")"
  case "$ch" in
    stable) exec npx --yes "$(mcp_npm_spec "$l")" "$@" ;;
    canary) ensure_mcp_server; exec node "$(mcp_entry "$l")" "$@" ;;
    *)      die "$(basename "$l"): ${ch#INVALID:}" ;;
  esac
}

ensure_node_on_path
install_browser_suppressor
load_env
