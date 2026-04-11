#!/usr/bin/env bash
# Add a Fathom API key to the OpenBrain MCP config.
# Usage: add-fathom.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

step "Fathom API key"
cat <<'EOF'

Generate a Fathom API key:

  1. Open https://fathom.video/settings
  2. Go to Integrations → API
  3. Click "Generate API key"
  4. Copy the key

EOF

KEY="$(prompt_secret "Paste Fathom API key")"
[[ -n "$KEY" ]] || die "API key cannot be empty"

env_set_var FATHOM_API_KEY "$KEY"
chmod 600 "$ENV_FILE"

ok "stored FATHOM_API_KEY in $ENV_FILE"
info "Next: run ./bootstrap/lib/register-mcps.sh to register the fathom MCP"
