#!/usr/bin/env bash
# OpenBrain Asana MCP launcher. Usage: asana-mcp.sh personal|work
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

case "${1:?usage: asana-mcp.sh personal|work}" in
  personal)
    require_env ASANA_PAT_PERSONAL
    export ASANA_ACCESS_TOKEN="$ASANA_PAT_PERSONAL"
    ;;
  work)
    require_env ASANA_PAT_WORK
    export ASANA_ACCESS_TOKEN="$ASANA_PAT_WORK"
    ;;
  *)
    die "unknown account '$1' (expected personal|work)"
    ;;
esac

exec npx -y @roychri/mcp-server-asana
