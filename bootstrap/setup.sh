#!/usr/bin/env bash
# OpenBrain setup wizard — run this ONCE after `git clone` to bootstrap your vault.
#
# What it does:
#   1. Checks prereqs (python3, node, git, optionally gh/claude CLI)
#   2. Asks for your name and writing-voice blurb
#   3. Substitutes those into CLAUDE.md and generates Home.md
#   4. Copies .openbrain/lib/*.sh → ~/.config/openbrain/lib/ (install-time paths)
#   5. Creates ~/.config/openbrain/.env from .openbrain/env.example
#   6. Loops through each supported service and asks "add an account? [y/N]"
#   7. Runs register-mcps.sh to wire ~/.claude.json
#   8. Runs validate.sh to sanity-check the install
#   9. Prints next steps
#
# Re-runnable: the script is defensive. Re-running won't clobber existing
# secrets — you'll get prompts only for missing or explicitly re-entered values.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

banner() {
  printf '\n%s%s════════════════════════════════════════════════════════════%s\n' "$_C_BOLD" "$_C_BLUE" "$_C_RESET"
  printf '%s%s  %s%s\n' "$_C_BOLD" "$_C_BLUE" "$*" "$_C_RESET"
  printf '%s%s════════════════════════════════════════════════════════════%s\n\n' "$_C_BOLD" "$_C_BLUE" "$_C_RESET"
}

banner "OpenBrain — personal AI Chief of Staff setup"

cat <<EOF
This wizard will:
  • Customize CLAUDE.md with your name + writing voice
  • Create ~/.config/openbrain/ and install launcher scripts
  • Walk you through OAuth for every service you want to wire up
  • Register MCP servers with Claude Code

It assumes this repo is already cloned to the directory you want to use as
your vault. Current repo path: $_C_BOLD$REPO_ROOT$_C_RESET

EOF

if ! yes_no "Continue?" y; then
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 1: prereqs (auto-installs missing dependencies)
# -----------------------------------------------------------------------------
step "1/9 · Checking & installing prerequisites"
ensure_git
ok "git: $(command -v git)"
ensure_python3
ok "python3: $PYTHON_BIN"
ensure_node
ok "node: $(command -v node) ($(node --version))"
ensure_claude_cli
ok "claude: $(command -v claude)"
ensure_gh
ok "gh: $(command -v gh)"

# If asdf is active, ensure .tool-versions exists so node/python resolve in this dir
if command -v asdf >/dev/null 2>&1 && [[ ! -f "$REPO_ROOT/.tool-versions" ]]; then
  NODE_VER="$(node --version 2>/dev/null | sed 's/^v//')"
  if [[ -n "$NODE_VER" ]]; then
    echo "nodejs $NODE_VER" > "$REPO_ROOT/.tool-versions"
    ok "created .tool-versions (nodejs $NODE_VER) for asdf compatibility"
  fi
fi

# -----------------------------------------------------------------------------
# Step 2: user profile
# -----------------------------------------------------------------------------
step "2/9 · Tell me about yourself"

USER_NAME="$(prompt 'Your full name' "${USER:-}")"
USER_VOICE="$(prompt 'Describe your writing voice in a sentence' 'direct, terse, no filler')"

# -----------------------------------------------------------------------------
# Step 3: customize CLAUDE.md
# -----------------------------------------------------------------------------
step "3/9 · Customizing CLAUDE.md"

BOOTSTRAP_DATE="$(date +%Y-%m-%d)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

"$PYTHON_BIN" - "$CLAUDE_MD" "$USER_NAME" "$USER_VOICE" "$BOOTSTRAP_DATE" <<'PY'
import sys
path, name, voice, date = sys.argv[1:]
content = open(path).read()
content = (content
    .replace("{{USER_NAME}}", name)
    .replace("{{USER_VOICE}}", voice)
    .replace("{{BOOTSTRAP_DATE}}", date)
    # Placeholder blocks get cleared to a "none configured" stub; the tables
    # get populated fully by a later pass (after accounts are added).
    .replace("{{ASANA_ROUTING_TABLE}}",  "_No Asana workspaces configured yet. Run `./bootstrap/lib/add-asana.sh personal|work` to add one._")
    .replace("{{GOOGLE_ACCOUNTS_TABLE}}", "_No Google accounts configured yet. Run `./bootstrap/lib/add-google-account.sh <email>` to add one._")
    .replace("{{SLACK_WORKSPACES_TABLE}}", "_No Slack workspaces configured yet. Run `./bootstrap/lib/add-slack-workspace.sh <subdomain>` to add one._")
    .replace("{{FATHOM_TABLE}}", "_Fathom not configured. Run `./bootstrap/lib/add-fathom.sh` to add it._")
)
open(path, "w").write(content)
PY
ok "CLAUDE.md customized"

# Generate Home.md if missing
if [[ ! -f "$REPO_ROOT/Home.md" ]]; then
  cat >"$REPO_ROOT/Home.md" <<EOF
---
title: Home
tags: [moc]
created: $BOOTSTRAP_DATE
---

# ${USER_NAME}'s OpenBrain

The front door. This file's MOC index auto-regenerates on every Claude Code
session end.

## Top MOCs

<!-- openbrain:moc-index:start -->
<!-- openbrain:moc-index:end -->

## Quick access

- [[+ Inbox]] — capture first, triage later
- [[+ Atlas/Daily]] — daily notes
- [[+ Sources]] — literature / references
- [[+ Extras/Templates]] — note templates

## How this vault works

- **Capture first, organize later.** Everything starts in \`+ Inbox/\`.
- **Atomic notes.** One idea per note.
- **Links over folders.** Structure comes from \`[[wikilinks]]\` and MOCs.
- See [[CLAUDE]] for the full operating manual.
EOF
  ok "Home.md created"
fi

# -----------------------------------------------------------------------------
# Step 4: install config dir + env
# -----------------------------------------------------------------------------
step "4/9 · Installing ~/.config/openbrain/"
ensure_env_file
mkdir -p "$TOKEN_DIR" "$LIB_DIR"
chmod 700 "$CONFIG_DIR" "$TOKEN_DIR"
chmod 755 "$LIB_DIR"
chmod 600 "$ENV_FILE"
ok "config dir: $CONFIG_DIR"

# Copy launchers
for f in "$REPO_ROOT/.openbrain/lib/"*.sh; do
  dest="$LIB_DIR/$(basename "$f")"
  cp "$f" "$dest"
  chmod 755 "$dest"
done
ok "launcher scripts installed"

# -----------------------------------------------------------------------------
# Step 5: wire up services
# -----------------------------------------------------------------------------
step "5/9 · Wiring up services"

# Google — optional but recommended
if yes_no "Wire up Google accounts (Gmail + Calendar + Meet + Drive)?" y; then
  "$HERE/lib/setup-google-oauth.sh"
  while true; do
    email="$(prompt 'Google account email to add (blank to finish)')"
    [[ -z "$email" ]] && break
    "$HERE/lib/add-google-account.sh" "$email" || warn "failed to add $email — continuing"
  done
fi

# Slack
if yes_no "Wire up Slack workspaces?" n; then
  while true; do
    sub="$(prompt 'Slack workspace subdomain (e.g. acme → acme.slack.com, blank to finish)')"
    [[ -z "$sub" ]] && break
    "$HERE/lib/add-slack-workspace.sh" "$sub" || warn "failed to add $sub — continuing"
  done
fi

# Asana
if yes_no "Wire up Asana (personal)?" n; then
  "$HERE/lib/add-asana.sh" personal || warn "failed to add personal Asana"
fi
if yes_no "Wire up Asana (work)?" n; then
  "$HERE/lib/add-asana.sh" work || warn "failed to add work Asana"
fi

# Fathom
if yes_no "Wire up Fathom?" n; then
  "$HERE/lib/add-fathom.sh" || warn "failed to add Fathom"
fi

# -----------------------------------------------------------------------------
# Step 6: register MCPs in ~/.claude.json
# -----------------------------------------------------------------------------
step "6/9 · Registering MCPs with Claude Code"
"$HERE/lib/register-mcps.sh"

# -----------------------------------------------------------------------------
# Step 7: git hook
# -----------------------------------------------------------------------------
step "7/9 · Git hook"
if [[ -d "$REPO_ROOT/.git" ]]; then
  HOOK="$REPO_ROOT/.git/hooks/pre-commit"
  if [[ ! -e "$HOOK" ]] || ! cmp -s "$REPO_ROOT/.openbrain/pre-commit.sh" "$HOOK"; then
    ln -sf "$REPO_ROOT/.openbrain/pre-commit.sh" "$HOOK"
    chmod +x "$REPO_ROOT/.openbrain/pre-commit.sh"
    ok "pre-commit hook linked"
  else
    ok "pre-commit hook already linked"
  fi
else
  warn "not a git repo — skipping pre-commit hook. Run 'git init' then re-run this script."
fi

# -----------------------------------------------------------------------------
# Step 8: wire Claude Code Stop + SessionStart hooks
# -----------------------------------------------------------------------------
step "8/9 · Wiring Claude Code Stop + SessionStart hooks"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
"$PYTHON_BIN" - "$CLAUDE_SETTINGS" "$REPO_ROOT" <<'PY'
import json, os
from pathlib import Path
settings_path = Path(os.sys.argv[1])
repo_root = os.sys.argv[2]
data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text())
    except Exception:
        pass
hooks = data.setdefault("hooks", {})
hooks["SessionStart"] = [{
    "hooks": [{
        "type": "command",
        "command": f"{repo_root}/.openbrain/on-start.sh",
        "timeout": 30,
        "statusMessage": "OpenBrain: pulling latest",
    }]
}]
hooks["Stop"] = [{
    "hooks": [{
        "type": "command",
        "command": f"{repo_root}/.openbrain/on-stop.sh",
        "timeout": 120,
        "statusMessage": "OpenBrain: syncing to git",
    }]
}]
settings_path.write_text(json.dumps(data, indent=2) + "\n")
print(f"[openbrain] wrote {settings_path}")
PY
ok "Claude Code hooks wired in .claude/settings.json"

# -----------------------------------------------------------------------------
# Step 9: validate
# -----------------------------------------------------------------------------
step "9/9 · Validating install"
"$HERE/lib/validate.sh" || true

# -----------------------------------------------------------------------------
# Final: next steps
# -----------------------------------------------------------------------------
banner "Setup complete"
cat <<EOF
Next steps:

  1. ${_C_BOLD}Restart Claude Code${_C_RESET} in this vault directory so it picks up
     the new MCP servers and Stop/SessionStart hooks.

  2. Inside a fresh Claude Code session, run:
       ${_C_CYAN}/mcp${_C_RESET}               # verify every server shows "ready"
       ${_C_CYAN}/daily-brief${_C_RESET}       # smoke-test your first skill

  3. Open the vault in Obsidian:
       ${_C_CYAN}open -a Obsidian $REPO_ROOT${_C_RESET}

     Then install these recommended community plugins:
       • Templater (set folder to + Extras/Templates/)
       • Local Images Plus
           - realTimeUpdate: true
           - processCreated: true
           - attachment pattern: .resources/\${notename}/

  4. Add more accounts any time with:
       ${_C_CYAN}./bootstrap/lib/add-google-account.sh jane@newdomain.com${_C_RESET}
       ${_C_CYAN}./bootstrap/lib/add-slack-workspace.sh newteam${_C_RESET}
       ${_C_CYAN}./bootstrap/lib/add-asana.sh personal${_C_RESET}

  5. (Optional) Push this vault to a private git remote for cross-device sync:
       ${_C_CYAN}gh repo create my-vault --private --source=. --push${_C_RESET}

See README.md and bootstrap/README.md for troubleshooting.
EOF
