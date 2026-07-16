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
# Runtime locations default to the real per-machine config, but each is
# overridable via env so the deploy path (register-mcps.sh et al.) can be
# exercised against a throwaway runtime in tests — NEVER against live config.
# CLAUDE_JSON is overridable for the same reason (register-mcps mutates it).
CONFIG_DIR="${OPENBRAIN_CONFIG_DIR:-$HOME/.config/openbrain}"
LIB_DIR="${OPENBRAIN_LIB_DIR:-$CONFIG_DIR/lib}"
ENV_FILE="${OPENBRAIN_ENV_FILE:-$CONFIG_DIR/.env}"
TOKEN_DIR="${OPENBRAIN_TOKEN_DIR:-$CONFIG_DIR/tokens}"
VENV_DIR="${OPENBRAIN_VENV_DIR:-$CONFIG_DIR/venv}"
CLAUDE_JSON="${OPENBRAIN_CLAUDE_JSON:-$HOME/.claude.json}"
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

# ---------- managed launcher set ----------
# The SINGLE definition of which .openbrain/lib files are runtime launchers
# (deployed to $LIB_DIR): the *-mcp.sh launchers plus the _common.sh they
# source. Everything else in .openbrain/lib (clone-pii-gate.sh, scan-secrets.sh,
# reconcile-runtime.sh, ...) is vault/clone-tier tooling that runs from the
# repo, not the per-machine runtime. minimal-init.sh, register-mcps.sh, and
# reconcile-runtime.sh all iterate this helper — keep them on it so the set
# cannot drift apart between deploy, drift-check, and init.
managed_launchers() {
  # usage: managed_launchers <src-dir>  — one existing path per line (may be none)
  # Empty/missing dir returns nothing rather than letting the glob degrade to
  # a root-directory scan ("/*-mcp.sh").
  local d="${1:-}" f
  [[ -n "$d" && -d "$d" ]] || return 0
  for f in "$d"/*-mcp.sh "$d/_common.sh"; do
    [[ -e "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

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
  # Prefer Homebrew, then system. Every candidate must be able to load
  # pyexpat — not just pass --version. This catches both asdf/nvm shims that
  # exist as executables but error at runtime, AND interpreters whose
  # `python3 -m venv` would silently create a venv with a crashing
  # `ensurepip` (seen on macOS 26.1 with Homebrew python@3.14 bottles built
  # against a newer libexpat).
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c "import pyexpat" >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  # Try whatever is on PATH, but verify it actually works
  PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c "import pyexpat" >/dev/null 2>&1; then
    return 0
  fi
  # Auto-install via Homebrew
  info "no working python3 found (missing, broken shim, or pyexpat/libexpat mismatch) — installing via Homebrew..."
  ensure_homebrew
  brew install python
  # Use Homebrew's python directly to avoid asdf shim interference
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$candidate" ]] && "$candidate" -c "import pyexpat" >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
  [[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c "import pyexpat" >/dev/null 2>&1 \
    || die "python3 installation failed — every candidate failed to load pyexpat (likely a Homebrew/libexpat mismatch; try 'brew reinstall --build-from-source python')"
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

# Canonical install-time prerequisite set. The single source of truth for
# "what must be present before any MCP can build or run." setup.sh calls this
# instead of listing the ensures inline, and external consumers (e.g. a
# separate project bootstrap that vendors this file) call the same function — so a
# new prerequisite added here propagates to every consumer without each one
# re-implementing the list. Emits the same ok-lines setup.sh used to print.
# Note: repo-specific steps (e.g. writing .tool-versions into $REPO_ROOT) stay
# in the calling script — this function installs tools, it does not touch the
# consumer's working tree.
ensure_prereqs() {
  ensure_git
  ok "git: $(command -v git)"
  ensure_python3
  ok "python3: $PYTHON_BIN"
  ensure_node
  ok "node: $(command -v node) ($(node --version))"
  ensure_claude_cli
  ok "claude: $(command -v claude)"
  ensure_gh
  # gh is optional (ensure_gh warns rather than dies); show "not installed"
  # instead of a blank path when it's absent.
  if command -v gh >/dev/null 2>&1; then
    ok "gh: $(command -v gh)"
  else
    ok "gh: not installed"
  fi
}

# ---------- MCP server source repos ----------
# Each MCP server is a TypeScript project in its own GitHub repo, cloned to
# $HOME/Code/<name>-mcp and built to dist/index.js. The launcher scripts in
# .openbrain/lib/*.sh exec that built artifact. Override the GitHub owner with
# OPENBRAIN_MCP_REPO_OWNER (e.g. if you've forked the servers).
MCP_REPO_OWNER="${OPENBRAIN_MCP_REPO_OWNER:-davidianstyle}"
MCP_SRC_ROOT="$HOME/Code"

ensure_mcp_server() {
  # ensure_mcp_server <name>   (e.g. "asana", "google", "slack", "fathom")
  # Clones $MCP_REPO_OWNER/<name>-mcp into $MCP_SRC_ROOT if missing, then runs
  # npm install + npm run build. Idempotent — re-runs the build only when
  # dist/index.js is missing.
  local name="$1"
  local repo="${MCP_REPO_OWNER}/${name}-mcp"
  local src_dir="$MCP_SRC_ROOT/${name}-mcp"
  local dist="$src_dir/dist/index.js"

  if [[ -f "$dist" ]]; then
    ok "${name}-mcp already built ($src_dir)"
    return 0
  fi

  ensure_node

  if [[ ! -d "$src_dir" ]]; then
    mkdir -p "$MCP_SRC_ROOT"
    info "cloning $repo → $src_dir"
    if command -v gh >/dev/null 2>&1; then
      gh repo clone "$repo" "$src_dir" >/dev/null \
        || die "failed to clone $repo via gh — confirm access (gh auth status) or set OPENBRAIN_MCP_REPO_OWNER"
    else
      git clone "https://github.com/${repo}.git" "$src_dir" \
        || die "failed to clone https://github.com/${repo}.git — install gh (brew install gh) for private-repo auth"
    fi
  fi

  info "installing ${name}-mcp dependencies (npm install in $src_dir)"
  ( cd "$src_dir" && npm install ) || die "npm install failed in $src_dir"

  info "building ${name}-mcp (npm run build)"
  ( cd "$src_dir" && npm run build ) || die "npm run build failed in $src_dir"

  [[ -f "$dist" ]] || die "build completed but $dist still missing — investigate $src_dir"
  ok "${name}-mcp built ($dist)"
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

# ---------- OAuth client config: .env as single source of truth, per provider ----------
# OAuth client_id/secret live canonically in .env, namespaced per provider
# (GOOGLE_OAUTH_CLIENT_ID/SECRET today; MICROSOFT_OAUTH_CLIENT_ID/SECRET if/when
# we add it). Two artifacts are DERIVED from .env, per provider:
#   tokens/<provider>-oauth-client.json   — client config the mint flow reads
#   tokens/.<provider>-oauth-fingerprint  — which client the connected tokens belong to
# Regenerating the json from .env at mint time means editing the secret in .env
# propagates on the next (re-)auth. The fingerprint lets the SessionStart probe
# notice when the client itself changed and a reconnect is warranted.
#
# The generic helpers take a REQUIRED <provider> key — no default, because an
# explicit provider is the whole point of namespacing (a default would silently
# act on google). The client-config WRITER is provider-specific (the json shape
# differs per provider), so it's an explicit per-provider function.
#
# To add a provider (e.g. microsoft), see "Adding another OAuth provider" in
# bootstrap/README.md — the step-by-step convention.

# Resolve a per-provider .env var: _oauth_env google CLIENT_ID -> $GOOGLE_OAUTH_CLIENT_ID
_oauth_env() {
  local up; up="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
  local var="${up}_OAUTH_$2"
  printf '%s' "${!var:-}"
}

_oauth_fingerprint_file() { printf '%s/.%s-oauth-fingerprint' "$TOKEN_DIR" "$1"; }

# Google's installed-app client config. Atomic + idempotent; no-op if .env lacks
# the creds, so we never clobber a good file with an empty one.
sync_google_oauth_client_json() {
  local id="${GOOGLE_OAUTH_CLIENT_ID:-}" secret="${GOOGLE_OAUTH_CLIENT_SECRET:-}"
  [[ -n "$id" && -n "$secret" ]] || return 0
  mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR" 2>/dev/null || true
  local out="$TOKEN_DIR/google-oauth-client.json"
  local tmp; tmp="$(mktemp "${TOKEN_DIR}/.google-oauth-client.XXXXXX")"
  cat >"$tmp" <<JSON
{
  "installed": {
    "client_id": "${id}",
    "client_secret": "${secret}",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "redirect_uris": ["http://localhost"]
  }
}
JSON
  chmod 600 "$tmp"
  mv -f "$tmp" "$out"
}

oauth_fingerprint() {
  # Stable fingerprint of <provider>'s current .env client identity.
  # Usage: oauth_fingerprint <provider>. Fails (1) if that provider's creds aren't set.
  local provider="${1:?oauth_fingerprint: provider required}"
  local id secret
  id="$(_oauth_env "$provider" CLIENT_ID)"; secret="$(_oauth_env "$provider" CLIENT_SECRET)"
  [[ -n "$id" && -n "$secret" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s:%s' "$id" "$secret" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s:%s' "$id" "$secret" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

write_oauth_fingerprint() {
  # Record the client fingerprint <provider>'s tokens were minted against.
  # Usage: write_oauth_fingerprint <provider>. Clears any prior drift.
  local provider="${1:?write_oauth_fingerprint: provider required}"
  local fp; fp="$(oauth_fingerprint "$provider")" || return 0
  mkdir -p "$TOKEN_DIR"; chmod 700 "$TOKEN_DIR" 2>/dev/null || true
  local file; file="$(_oauth_fingerprint_file "$provider")"
  printf '%s\n' "$fp" > "$file"
  chmod 600 "$file"
}

auth_drift_detected() {
  # True (0) when <provider>'s baseline fingerprint exists AND differs from the
  # current .env identity — the client changed since accounts were connected, so
  # existing logins may need refreshing. False on first run or when they match.
  # Usage: auth_drift_detected <provider>.
  local provider="${1:?auth_drift_detected: provider required}"
  local file; file="$(_oauth_fingerprint_file "$provider")"
  [[ -f "$file" ]] || return 1
  local current stored
  current="$(oauth_fingerprint "$provider")" || return 1
  stored="$(cat "$file" 2>/dev/null || true)"
  [[ -n "$stored" && "$current" != "$stored" ]]
}
