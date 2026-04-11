#!/usr/bin/env bash
# OpenBrain Fathom MCP launcher. Usage: fathom-mcp.sh
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_env FATHOM_API_KEY
export FATHOM_API_KEY

exec npx -y @lengelhard/fathom-mcp
