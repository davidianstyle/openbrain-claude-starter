#!/usr/bin/env bash
# OpenBrain Google Meet MCP launcher. Usage: gmeet-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: gmeet-mcp.sh <slug>}"
TOKEN_DIR="$HOME/.config/openbrain/tokens"
OAUTH_CLIENT="$TOKEN_DIR/oauth-client.json"
TOKEN_PATH="$TOKEN_DIR/google-${SLUG}-gmeet-token.json"

[[ -f "$OAUTH_CLIENT" ]] || die "shared OAuth client missing: $OAUTH_CLIENT (run bootstrap/lib/add-google-account.sh $SLUG)"

export GOOGLE_OAUTH_CREDENTIALS="$OAUTH_CLIENT"
export GOOGLE_MEET_MCP_TOKEN_PATH="$TOKEN_PATH"

exec npx -y @dtannen/google-meet-mcp
