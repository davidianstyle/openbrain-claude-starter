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
# Several Google MCPs (@cocal/google-calendar-mcp, @gongrzhe/server-gmail-autoauth-mcp,
# etc.) attempt an OAuth flow on startup when their token cache is missing or
# stale. Without this shim, that flow pops up real browser windows for every
# configured account on every session start. Tokens are managed out-of-band
# via bootstrap-google.sh / add-google-account.sh — re-run those scripts when
# a refresh actually fails.
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
# Claude Code startup. Re-run bootstrap-google.sh to re-auth when a
# real token refresh failure happens.
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

# Auto-clone and build an MCP server repo if the built artifact is missing.
# Usage: ensure_mcp_server <repo-name>
# E.g.:  ensure_mcp_server asana-mcp
#   → clones github.com/davidianstyle/asana-mcp to ~/Code/asana-mcp
#   → runs npm install && npm run build
#   → expects dist/index.js to exist after build
ensure_mcp_server() {
  local name="$1"
  local repo_dir="$HOME/Code/$name"
  local server="$repo_dir/dist/index.js"

  if [[ -f "$server" ]]; then
    return 0
  fi

  echo "openbrain mcp: $name not found — auto-installing..." >&2

  if [[ ! -d "$repo_dir" ]]; then
    echo "openbrain mcp: cloning github.com/davidianstyle/$name..." >&2
    git clone "https://github.com/davidianstyle/$name.git" "$repo_dir" >&2 \
      || die "failed to clone $name"
  fi

  echo "openbrain mcp: building $name..." >&2
  (cd "$repo_dir" && npm install --ignore-scripts 2>&1 && npm run build 2>&1) >&2 \
    || die "failed to build $name — run 'cd $repo_dir && npm install && npm run build' manually"

  [[ -f "$server" ]] || die "$name built but dist/index.js not found"
  echo "openbrain mcp: $name installed at $server" >&2
}

ensure_node_on_path
install_browser_suppressor
load_env
