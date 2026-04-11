#!/usr/bin/env bash
# OpenBrain Google Calendar MCP launcher. Usage: gcal-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: gcal-mcp.sh <slug>}"
TOKEN_DIR="$HOME/.config/openbrain/tokens"
OAUTH_CLIENT="$TOKEN_DIR/oauth-client.json"
TOKEN_PATH="$TOKEN_DIR/google-${SLUG}-gcal-token.json"

[[ -f "$OAUTH_CLIENT" ]] || die "shared OAuth client missing: $OAUTH_CLIENT (run bootstrap/lib/add-google-account.sh $SLUG)"

export GOOGLE_OAUTH_CREDENTIALS="$OAUTH_CLIENT"
export GOOGLE_CALENDAR_MCP_TOKEN_PATH="$TOKEN_PATH"

exec npx -y @cocal/google-calendar-mcp
