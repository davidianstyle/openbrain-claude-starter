#!/usr/bin/env bash
# Shared helpers sourced by every OpenBrain bootstrap script.
#
# Responsibilities:
#   - Compute REPO_ROOT, CONFIG_DIR, ENV_FILE, TOKEN_DIR paths
#   - Provide logging helpers (log, info, warn, die)
#   - Provide ensure_python3(), ensure_node(), ensure_venv() bootstrap helpers
#   - Provide slug derivation + env-file mutation helpers
#
# Do NOT `set -e` globally here — caller scripts do that themselves.

# Resolve paths relative to THIS file (bootstrap/lib/common.sh)
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"
CONFIG_DIR="$HOME/.config/openbrain"
LIB_DIR="$CONFIG_DIR/lib"
ENV_FILE="$CONFIG_DIR/.env"
TOKEN_DIR="$CONFIG_DIR/tokens"
VENV_DIR="$CONFIG_DIR/venv"
DRIVE_TOKEN_ROOT="$HOME/.config/google-docs-mcp"

# ---------- colors + logging ----------
if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'
  _C_BOLD=$'\033[1m'
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'
  _C_CYAN=$'\033[36m'
else
  _C_RESET='' _C_BOLD='' _C_RED='' _C_GREEN='' _C_YELLOW='' _C_BLUE='' _C_CYAN=''
fi

info() { printf '%s›%s %s\n' "$_C_CYAN" "$_C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn() { printf '%s⚠%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
die()  { err "$@"; exit 1; }

step() { printf '\n%s%s%s\n' "$_C_BOLD$_C_BLUE" "$*" "$_C_RESET"; }

prompt() {
  # prompt "label" [default]
  local label="$1" default="${2:-}" answer=''
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$label: " answer
    printf '%s' "$answer"
  fi
}

prompt_secret() {
  # prompt_secret "label" — no echo
  local label="$1" answer=''
  read -r -s -p "$label: " answer
  printf '\n' >&2
  printf '%s' "$answer"
}

yes_no() {
  # yes_no "question" [default=y|n]   (returns 0 for yes, 1 for no)
  local q="$1" default="${2:-n}" answer=''
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  read -r -p "$q $hint " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

# ---------- prereqs ----------
ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  info "Homebrew not found — installing (this is the macOS package manager)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add Homebrew to PATH for this session
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  command -v brew >/dev/null 2>&1 || die "Homebrew installation failed"
  ok "Homebrew installed"
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi
  info "git not found — installing via Xcode command-line tools..."
  xcode-select --install 2>/dev/null || true
  # Wait for installation to complete
  until command -v git >/dev/null 2>&1; do
    sleep 5
  done
  ok "git installed"
}

ensure_python3() {
  # Prefer Homebrew, then system. Every candidate must pass --version to
  # catch asdf/nvm shims that exist as executables but error at runtime.
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  # Try whatever is on PATH, but verify it actually runs
  PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" --version >/dev/null 2>&1; then
    return 0
  fi
  # Auto-install via Homebrew
  info "python3 not found (or asdf shim has no version set) — installing via Homebrew..."
  ensure_homebrew
  brew install python
  # Use Homebrew's python directly to avoid asdf shim interference
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$candidate" ]]; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
  [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] \
    || die "python3 installation failed"
  ok "python3 installed"
}

ensure_node() {
  # Check if node actually works (not just that a shim exists)
  if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
    return 0
  fi
  # Try real binaries, skipping broken asdf/nvm shims
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$dir/node" ]] && "$dir/node" --version >/dev/null 2>&1; then
      export PATH="$dir:$PATH"
      return 0
    fi
  done
  # Try nvm versions
  for dir in "$HOME/.nvm/versions/node"/*/bin; do
    if [[ -x "$dir/node" ]] && "$dir/node" --version >/dev/null 2>&1; then
      export PATH="$dir:$PATH"
      return 0
    fi
  done
  # Auto-install via Homebrew (bypasses asdf/nvm entirely)
  info "node not found (or version manager shim has no version set) — installing via Homebrew..."
  ensure_homebrew
  brew install node
  # Use Homebrew's node directly
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$dir/node" ]] && "$dir/node" --version >/dev/null 2>&1; then
      export PATH="$dir:$PATH"
      return 0
    fi
  done
  command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1 || die "node installation failed"
  ok "node installed"
}

ensure_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    return 0
  fi
  info "Claude Code CLI not found — installing via npm..."
  ensure_node
  npm install -g @anthropic-ai/claude-code
  command -v claude >/dev/null 2>&1 || die "Claude Code CLI installation failed"
  ok "Claude Code CLI installed"
}

ensure_gh() {
  if command -v gh >/dev/null 2>&1; then
    return 0
  fi
  info "gh CLI not found — installing via Homebrew (optional, for git remote setup)..."
  ensure_homebrew
  brew install gh || warn "gh installation failed — you can still set up git remotes manually"
}

ensure_venv() {
  ensure_python3
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
    info "creating Python venv at $VENV_DIR (one-time)"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  if ! "$VENV_DIR/bin/python3" -c "import google_auth_oauthlib" 2>/dev/null; then
    info "installing google-auth-oauthlib into venv"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet google-auth-oauthlib
  fi
}

# ---------- slug + env helpers ----------
email_to_slug() {
  # jane@acme.example.com → jane-acme-example-com
  local email="$1"
  printf '%s' "$email" | tr '[:upper:]' '[:lower:]' | tr '@.' '--'
}

slack_subdomain_to_slug() {
  # acme.slack.com → acme-slack-com
  # acme            → acme-slack-com (assumes .slack.com)
  local sub="$1"
  sub="${sub#https://}"
  sub="${sub%.slack.com}"
  printf '%s-slack-com' "$sub" | tr '[:upper:]' '[:lower:]'
}

slug_to_envvar() {
  # my-slug-here → MY_SLUG_HERE
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

ensure_env_file() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$REPO_ROOT/.openbrain/env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "created $ENV_FILE from template"
  else
    # Backfill any missing marker blocks from env.example into the existing .env
    local marker
    for marker in "GOOGLE_SLUGS" "SLACK_TOKENS"; do
      local start="# --- ${marker} (managed by bootstrap) ---"
      local end="# --- END ${marker} ---"
      if ! grep -qF "$start" "$ENV_FILE"; then
        printf '\n%s\n%s\n' "$start" "$end" >> "$ENV_FILE"
        info "backfilled missing $marker markers into $ENV_FILE"
      fi
    done
  fi
}

env_set_var() {
  # env_set_var KEY VALUE — replace the line KEY=... or append if missing
  local key="$1" value="$2"
  ensure_env_file
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # macOS sed: use -i '' for in-place
    sed -i '' -E "s|^${key}=.*|${key}=${value//|/\\|}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

env_append_between_markers() {
  # env_append_between_markers START_MARKER END_MARKER LINE
  # Inserts LINE just before END_MARKER, if not already present between markers.
  local start="$1" end="$2" line="$3"
  ensure_env_file
  [[ -n "${PYTHON_BIN:-}" ]] || ensure_python3
  if awk -v s="$start" -v e="$end" -v l="$line" '
    $0==s {in_block=1; next}
    $0==e {in_block=0; next}
    in_block && $0==l {found=1}
    END {exit(found?0:1)}
  ' "$ENV_FILE"; then
    return 0  # already present
  fi
  # Insert before end marker
  "$PYTHON_BIN" - "$ENV_FILE" "$start" "$end" "$line" <<'PY'
import sys
path, start, end, line = sys.argv[1:]
with open(path) as f:
    content = f.read()
if start not in content or end not in content:
    sys.stderr.write(f"env_append_between_markers: markers missing in {path}\n")
    sys.exit(1)
before, rest = content.split(end, 1)
new = before.rstrip() + "\n" + line + "\n" + end + rest
with open(path, "w") as f:
    f.write(new)
PY
}

env_list_between_markers() {
  # env_list_between_markers START END — print lines between markers (excluding markers)
  local start="$1" end="$2"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -v s="$start" -v e="$end" '
    $0==s {in_block=1; next}
    $0==e {in_block=0; next}
    in_block && $0 !~ /^#/ && NF {print}
  ' "$ENV_FILE"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run bootstrap/setup.sh first"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}
