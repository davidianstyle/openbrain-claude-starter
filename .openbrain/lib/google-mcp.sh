#!/usr/bin/env bash
# openbrain-mcp: shape=checkout dir=google-mcp url=https://github.com/davidianstyle/google-mcp.git
# OpenBrain consolidated Google MCP launcher. Usage: google-mcp.sh <slug>
# Replaces: gmail-mcp.sh, gcal-mcp.sh, gmeet-mcp.sh, gdrive-mcp.sh, gslides-mcp.sh
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: google-mcp.sh <slug>}"
TOKEN_DIR="$HOME/.config/openbrain/tokens"
CREDS_FILE="$TOKEN_DIR/google-${SLUG}-credentials.json"

# The node server reads its OAuth client from the per-account credentials file
# (see google-mcp src/auth.ts) — NOT from oauth-client.json — so we neither check
# for nor regenerate that file here. The client config is a mint-time artifact,
# written from .env by setup-google-oauth.sh / add-google-account.sh.
[[ -f "$CREDS_FILE" ]] || die "per-account credentials missing: $CREDS_FILE (run bootstrap/lib/add-google-account.sh <email>)"
ensure_mcp_server      # lazy first-launch clone + build, from the declaration above

exec node "$(declared_entry)" --slug "$SLUG"
