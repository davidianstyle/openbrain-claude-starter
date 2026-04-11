#!/usr/bin/env bash
# OpenBrain Gmail MCP launcher. Usage: gmail-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: gmail-mcp.sh <slug>}"
TOKEN_DIR="$HOME/.config/openbrain/tokens"
OAUTH_CLIENT="$TOKEN_DIR/oauth-client.json"
CREDS_FILE="$TOKEN_DIR/google-${SLUG}-credentials.json"

[[ -f "$OAUTH_CLIENT" ]] || die "shared OAuth client missing: $OAUTH_CLIENT (run bootstrap/lib/add-google-account.sh $SLUG)"
[[ -f "$CREDS_FILE" ]] || die "per-account credentials missing: $CREDS_FILE (run bootstrap/lib/add-google-account.sh $SLUG)"

export GMAIL_OAUTH_PATH="$OAUTH_CLIENT"
export GMAIL_CREDENTIALS_PATH="$CREDS_FILE"

exec npx -y @gongrzhe/server-gmail-autoauth-mcp
