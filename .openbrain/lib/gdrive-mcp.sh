#!/usr/bin/env bash
# OpenBrain Google Drive/Docs/Sheets MCP launcher. Usage: gdrive-mcp.sh <slug>
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: gdrive-mcp.sh <slug>}"

require_env GOOGLE_OAUTH_CLIENT_ID
require_env GOOGLE_OAUTH_CLIENT_SECRET

export GOOGLE_CLIENT_ID="$GOOGLE_OAUTH_CLIENT_ID"
export GOOGLE_CLIENT_SECRET="$GOOGLE_OAUTH_CLIENT_SECRET"
export GOOGLE_MCP_PROFILE="$SLUG"

exec npx -y @a-bonus/google-docs-mcp
