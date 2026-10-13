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
for f in asana-mcp.sh google-mcp.sh slack-mcp.sh fathom-mcp.sh _common.sh _mcp-decl.sh mcp-local-build.sh; do
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

# grep -c prints its own 0 on no match (exit 1); an `|| echo 0` fallback would print a second one.
SCOUNT="$(grep -cE '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE" 2>/dev/null)"; SCOUNT="${SCOUNT:-0}"
info "Slack workspaces with tokens: $SCOUNT"

[[ -n "${ASANA_PAT_PERSONAL:-}" ]] && ok "Asana personal token set" || info "no Asana personal token (optional)"
[[ -n "${ASANA_PAT_WORK:-}" ]]     && ok "Asana work token set"     || info "no Asana work token (optional)"
[[ -n "${FATHOM_API_KEY:-}" ]]     && ok "Fathom API key set"       || info "no Fathom API key (optional)"

if [[ -n "${OPENBRAIN_MCP_REPO_OWNER:-}" ]]; then
  check_warn "OPENBRAIN_MCP_REPO_OWNER is set but no longer read — set owner= in ~/.config/openbrain/mcp-config instead"
fi

step "MCP server source repos"
if [[ ! -f "$LIB_DIR/_mcp-decl.sh" ]]; then
  check_warn "_mcp-decl.sh not installed at $LIB_DIR — run register-mcps.sh"
elif ! ( source "$LIB_DIR/_mcp-decl.sh"; declare -F mcp_get >/dev/null && declare -F mcp_root >/dev/null \
         && declare -F mcp_entry >/dev/null && declare -F mcp_get >/dev/null && declare -F _mcp_url_eq >/dev/null && declare -F fork_is_redundant >/dev/null ); then
  # Distinct CANNOT-CHECK line — never a silent return: an installed _mcp-decl.sh
  # missing the resolver functions (an older copy than this checker expects) must
  # not be treated as "nothing to check" or crash mid-check with "command not found".
  check_warn "CANNOT-CHECK: installed _mcp-decl.sh at $LIB_DIR is missing resolver functions — runtime not deployed yet — run .openbrain/lib/reconcile-runtime.sh --apply"
else
  # shellcheck source=/dev/null
  source "$LIB_DIR/_mcp-decl.sh"
  check_mcp_built() {
    # check_mcp_built <launcher-basename-no-.sh> <add-script>   — always returns 0, so a
    # caller's `cond && check_mcp_built … || info "not needed"` can never misreport.
    # Separate `local` statements: bash 3.2 expands every word of ONE `local` before
    # assigning any, so l="$LIB_DIR/${name}.sh" on the same line would see an empty name.
    local name="$1" add_script="$2"
    local l="$LIB_DIR/${name}.sh" entry dir want actual want_fork actual_fork
    if [[ ! -f "$l" ]]; then check_warn "$name.sh not installed — run register-mcps.sh"; return 0; fi
    entry="$(mcp_entry "$l")"
    case "$entry" in
      INVALID:*) check_warn "$name: ${entry#INVALID:}"; return 0 ;;
    esac
    if [[ -f "$entry" ]]; then
      ok "$name built ($entry)"
    else
      check_warn "$name not built at $entry — re-run $add_script"
    fi
    # Origin-vs-resolved-url (URL-normalized), same comparison as check-updates.sh:
    # changing owner=/.url=/.fork= in mcp-config on an EXISTING clone otherwise
    # does nothing, silently — only a fresh clone would ever pick it up. Same for
    # a resolved .fork= vs the actual 'fork' remote. Report only — never re-point.
    dir="$(mcp_root "$l")"
    case "$dir" in INVALID:*) check_warn "$name: ${dir#INVALID:}"; return 0 ;; esac
    [[ -d "$dir/.git" ]] || return 0   # no clone yet: the "not built" warning above already says so
    want="$(mcp_get "$l" url)"
    case "$want" in
      INVALID:*) check_warn "$name: ${want#INVALID:}" ;;
      "") : ;;
      *)
        if actual="$(git -C "$dir" remote get-url origin 2>&1)"; then
          _mcp_url_eq "$actual" "$want" \
            || check_warn "$name origin is $actual, resolved declaration says $want — re-point: git -C $dir remote set-url origin $want — or, if that origin is intentional, set $name.url= (or owner=) in $MCP_CONFIG_FILE"
        else
          check_warn "CANNOT-CHECK: $name origin not compared — 'git remote get-url origin' failed in $dir: $actual"
        fi ;;
    esac
    want_fork="$(mcp_get "$l" fork)"
    if fork_is_redundant "$l"; then want_fork=""; fi   # .fork= equal to origin: re-parented, no fork remote to compare
    case "$want_fork" in
      INVALID:*) check_warn "$name: ${want_fork#INVALID:}" ;;
      "") : ;;
      *)
        if actual_fork="$(git -C "$dir" remote get-url fork 2>&1)"; then
          _mcp_url_eq "$actual_fork" "$want_fork" \
            || check_warn "$name fork remote is $actual_fork, resolved .fork= says $want_fork — re-point: git -C $dir remote set-url fork $want_fork"
        else
          check_warn "CANNOT-CHECK: $name fork remote not compared — 'git remote get-url fork' failed in $dir: $actual_fork"
        fi ;;
    esac
    return 0
  }
  if [[ -n "${ASANA_PAT_PERSONAL:-}${ASANA_PAT_WORK:-}" ]]; then
    check_mcp_built asana-mcp "./bootstrap/lib/add-asana.sh personal|work"
  else info "asana-mcp not needed (no Asana tokens configured)"; fi
  if (( GCOUNT > 0 )); then
    check_mcp_built google-mcp "./bootstrap/lib/add-google-account.sh <email>"
  else info "google-mcp not needed (no Google accounts configured)"; fi
  if (( SCOUNT > 0 )); then
    check_mcp_built slack-mcp "./bootstrap/lib/add-slack-workspace.sh <subdomain>"
  else info "slack-mcp not needed (no Slack workspaces configured)"; fi
  if [[ -n "${FATHOM_API_KEY:-}" ]]; then
    check_mcp_built fathom-mcp "./bootstrap/lib/add-fathom.sh"
  else info "fathom-mcp not needed (no Fathom key configured)"; fi
fi

step "Claude MCP registration"
CLAUDE_JSON="$HOME/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  MCP_COUNT="$("${PYTHON_BIN:-python3}" -c "
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
