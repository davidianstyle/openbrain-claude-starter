#!/usr/bin/env bash
# openbrain-mcp: shape=checkout dir=fathom-mcp url=https://github.com/davidianstyle/fathom-mcp.git
# OpenBrain Fathom MCP launcher. Usage: fathom-mcp.sh
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_env FATHOM_API_KEY
export FATHOM_API_KEY
ensure_mcp_server

exec node "$(declared_entry)"
