#!/usr/bin/env bash
# OpenBrain Slack MCP launcher. Usage: slack-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: slack-mcp.sh <slug>}"
SERVER="$HOME/Code/slack-mcp/dist/index.js"

# Slug → env var name: uppercased, - → _
TOKEN_VAR="SLACK_TOKEN_$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')"
TOKEN_VALUE="${!TOKEN_VAR:-}"

[[ -n "$TOKEN_VALUE" ]] || die "$TOKEN_VAR not set in $ENV_FILE (run bootstrap/lib/add-slack-workspace.sh $SLUG)"
ensure_mcp_server "slack-mcp"

export "SLACK_TOKEN_$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')=$TOKEN_VALUE"

exec node "$SERVER" --slug "$SLUG"
