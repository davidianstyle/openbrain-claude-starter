#!/usr/bin/env bash
# OpenBrain Slack MCP launcher. Usage: slack-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: slack-mcp.sh <slug>}"

# Slug → env var name: uppercased, - → _
TOKEN_VAR="SLACK_TOKEN_$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')"
TOKEN_VALUE="${!TOKEN_VAR:-}"

[[ -n "$TOKEN_VALUE" ]] || die "$TOKEN_VAR not set in $ENV_FILE (run bootstrap/lib/add-slack-workspace.sh $SLUG)"

export SLACK_MCP_XOXP_TOKEN="$TOKEN_VALUE"
export SLACK_MCP_ADD_MESSAGE_TOOL=true

exec npx -y slack-mcp-server --transport stdio
