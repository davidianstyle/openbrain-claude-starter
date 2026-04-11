#!/usr/bin/env bash
# Add a single Slack workspace to the OpenBrain MCP config.
#
# Prompts for a User OAuth Token (xoxp-*) and stores it in ~/.config/openbrain/.env
# under SLACK_TOKEN_<UPPER_SNAKE_SLUG>.
#
# Usage: add-slack-workspace.sh <subdomain-or-url>
#        add-slack-workspace.sh acme
#        add-slack-workspace.sh acme.slack.com
#        add-slack-workspace.sh https://acme.slack.com
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

SUB="${1:?usage: add-slack-workspace.sh <subdomain>}"
SLUG="$(slack_subdomain_to_slug "$SUB")"
ENV_VAR="SLACK_TOKEN_$(slug_to_envvar "$SLUG")"

info "Adding Slack workspace: $SLUG (env var: $ENV_VAR)"

step "Slack app setup"
cat <<EOF

Create a single-workspace Slack app (one-time per workspace):

  1. Open https://api.slack.com/apps
  2. Click "Create New App" → "From scratch"
       • App name: OpenBrain MCP
       • Pick workspace: the one you're adding
  3. Left sidebar → OAuth & Permissions → scroll to "User Token Scopes"
     Add ALL of these user scopes:
       channels:history   channels:read
       groups:history     groups:read
       im:history         im:read
       mpim:history       mpim:read
       users:read         search:read
       chat:write
  4. Scroll up → click "Install to Workspace" → Allow
  5. Copy the "User OAuth Token" — it starts with xoxp-

If you're not a Slack workspace admin, the install request will queue for
admin approval at https://${SUB#https://}.slack.com/apps/manage/requests.

EOF

TOKEN="$(prompt_secret "Paste User OAuth Token (xoxp-*)")"

if [[ ! "$TOKEN" =~ ^xoxp- ]]; then
  warn "token does not start with 'xoxp-' — that's suspicious but we'll store it anyway"
fi

env_set_var "$ENV_VAR" "$TOKEN"
env_append_between_markers \
  "# --- SLACK_TOKENS (managed by bootstrap) ---" \
  "# --- END SLACK_TOKENS ---" \
  "# $SLUG (env: $ENV_VAR)"

ok "stored Slack token for $SLUG in $ENV_FILE"
info "Next: run ./bootstrap/lib/register-mcps.sh to register the slack_$SLUG MCP"
