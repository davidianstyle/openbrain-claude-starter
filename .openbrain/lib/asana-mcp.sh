#!/usr/bin/env bash
# openbrain-mcp: shape=checkout dir=asana-mcp url=https://github.com/davidianstyle/asana-mcp.git
# OpenBrain Asana MCP launcher. Usage: asana-mcp.sh personal|work
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SLUG="${1:?usage: asana-mcp.sh personal|work}"

require_env "ASANA_PAT_$(echo "$SLUG" | tr '[:lower:]' '[:upper:]')"
ensure_mcp_server

exec node "$(declared_entry)" --slug "$SLUG"
