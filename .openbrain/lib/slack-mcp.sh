#!/usr/bin/env bash
# openbrain-mcp: shape=checkout dir=slack-mcp url=https://github.com/davidianstyle/slack-mcp.git
# OpenBrain Slack MCP launcher. Usage: slack-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: slack-mcp.sh <slug>}"

# Slug → env var name: uppercased, - → _
TOKEN_VAR="SLACK_TOKEN_$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')"
TOKEN_VALUE="${!TOKEN_VAR:-}"

[[ -n "$TOKEN_VALUE" ]] || die "$TOKEN_VAR not set in $ENV_FILE (run bootstrap/lib/add-slack-workspace.sh $SLUG)"
ensure_mcp_server

export "SLACK_TOKEN_$(echo "$SLUG" | tr '[:lower:]-' '[:upper:]_')=$TOKEN_VALUE"

exec node "$(declared_entry)" --slug "$SLUG"
