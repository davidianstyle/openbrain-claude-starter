#!/usr/bin/env bash
# OpenBrain Fathom MCP launcher. Usage: fathom-mcp.sh
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SERVER="$HOME/Code/fathom-mcp/dist/index.js"

require_env FATHOM_API_KEY
export FATHOM_API_KEY
[[ -f "$SERVER" ]] || die "fathom-mcp not built: $SERVER (run npm run build in ~/Code/fathom-mcp)"

exec node "$SERVER"
