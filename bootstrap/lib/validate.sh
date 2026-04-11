#!/usr/bin/env bash
# Post-setup sanity check for an OpenBrain install.
# Exits 0 even on warnings — this is informational, not a gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ERRORS=0
WARNINGS=0

check_fail() { err "$*"; ERRORS=$((ERRORS+1)); }
check_warn() { warn "$*"; WARNINGS=$((WARNINGS+1)); }

step "Vault layout"
for d in "+ Inbox" "+ Spaces" "+ Atlas" "+ Sources" "+ Extras/Templates" "+ Archive" ".claude/skills" ".openbrain/lib"; do
  if [[ -d "$REPO_ROOT/$d" ]]; then
    ok "$d"
  else
    check_fail "missing directory: $d"
  fi
done

step "Skills inventory"
SKILL_COUNT="$(find "$REPO_ROOT/.claude/skills" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
if (( SKILL_COUNT == 21 )); then
  ok "21 skills present"
elif (( SKILL_COUNT > 0 )); then
  check_warn "expected 21 skills, found $SKILL_COUNT"
else
  check_fail "no skills found at .claude/skills/*/SKILL.md"
fi

# Cross-check skills table in CLAUDE.md references the same names
if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
  MISSING_IN_CLAUDE_MD=0
  while IFS= read -r slug; do
    name="/$slug"
    if ! grep -q "\`$name\`" "$REPO_ROOT/CLAUDE.md"; then
      check_warn "skill $name has no row in CLAUDE.md §13 table"
      MISSING_IN_CLAUDE_MD=$((MISSING_IN_CLAUDE_MD+1))
    fi
  done < <(find "$REPO_ROOT/.claude/skills" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;)
  (( MISSING_IN_CLAUDE_MD == 0 )) && ok "all skills referenced in CLAUDE.md"
fi

step "Config files"
if [[ -f "$ENV_FILE" ]]; then
  perms="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
  if [[ "$perms" == "600" ]]; then
    ok "$ENV_FILE (mode 600)"
  else
    check_warn "$ENV_FILE mode is $perms, expected 600 — run: chmod 600 $ENV_FILE"
  fi
else
  check_fail "$ENV_FILE not found — run setup.sh"
fi

step "Installed launchers at $LIB_DIR"
for f in asana-mcp.sh gmail-mcp.sh gcal-mcp.sh gmeet-mcp.sh gdrive-mcp.sh slack-mcp.sh fathom-mcp.sh _common.sh; do
  if [[ -x "$LIB_DIR/$f" ]]; then
    ok "$f"
  else
    check_warn "$f not installed — run register-mcps.sh"
  fi
done

step "Configured accounts"
load_env || true

if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]]; then
  ok "GOOGLE_OAUTH_CLIENT_ID set"
else
  check_warn "GOOGLE_OAUTH_CLIENT_ID missing — run setup-google-oauth.sh"
fi

GCOUNT=0
if compgen -G "$TOKEN_DIR/google-*-credentials.json" > /dev/null; then
  GCOUNT="$(ls "$TOKEN_DIR"/google-*-credentials.json 2>/dev/null | wc -l | tr -d ' ')"
fi
info "Google accounts with credentials: $GCOUNT"

SCOUNT="$(grep -cE '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE" 2>/dev/null || echo 0)"
info "Slack workspaces with tokens: $SCOUNT"

[[ -n "${ASANA_PAT_PERSONAL:-}" ]] && ok "Asana personal token set" || info "no Asana personal token (optional)"
[[ -n "${ASANA_PAT_WORK:-}" ]]     && ok "Asana work token set"     || info "no Asana work token (optional)"
[[ -n "${FATHOM_API_KEY:-}" ]]     && ok "Fathom API key set"       || info "no Fathom API key (optional)"

step "Claude MCP registration"
CLAUDE_JSON="$HOME/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  MCP_COUNT="$("$PYTHON_BIN" -c "
import json
d = json.load(open('$CLAUDE_JSON'))
servers = d.get('mcpServers', {})
ob = [k for k, v in servers.items() if isinstance(v, dict) and 'openbrain' in v.get('command','')]
print(len(ob))
" 2>/dev/null || echo 0)"
  if (( MCP_COUNT > 0 )); then
    ok "$MCP_COUNT openbrain MCP servers registered in ~/.claude.json"
  else
    check_warn "no openbrain MCP servers registered — run register-mcps.sh"
  fi
else
  check_warn "$CLAUDE_JSON not found — start Claude Code at least once"
fi

step "Summary"
if (( ERRORS == 0 && WARNINGS == 0 )); then
  ok "All checks passed. Restart Claude Code and run /mcp to verify."
elif (( ERRORS == 0 )); then
  warn "$WARNINGS warning(s) — review above. Setup is usable."
else
  err "$ERRORS error(s), $WARNINGS warning(s) — fix errors before proceeding."
  exit 1
fi
