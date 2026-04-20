#!/usr/bin/env bash
# OpenBrain Asana MCP launcher. Usage: asana-mcp.sh personal|work
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: asana-mcp.sh personal|work}"
SERVER="$HOME/Code/asana-mcp/dist/index.js"

require_env "ASANA_PAT_$(echo "$SLUG" | tr '[:lower:]' '[:upper:]')"
[[ -f "$SERVER" ]] || die "asana-mcp not built: $SERVER (run npm run build in ~/Code/asana-mcp)"

exec node "$SERVER" --slug "$SLUG"
