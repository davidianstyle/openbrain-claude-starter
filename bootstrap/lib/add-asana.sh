#!/usr/bin/env bash
# Add an Asana workspace (personal or work) to the OpenBrain MCP config.
# Usage: add-asana.sh personal|work
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

KIND="${1:?usage: add-asana.sh personal|work}"
case "$KIND" in
  personal) VAR="ASANA_PAT_PERSONAL" ;;
  work)     VAR="ASANA_PAT_WORK" ;;
  *) die "expected personal|work, got: $KIND" ;;
esac

step "Asana personal access token ($KIND)"
cat <<'EOF'

Generate a Personal Access Token:

  1. Open https://app.asana.com/0/my-apps
  2. Click "+ Create new token"
     • Name: OpenBrain MCP
     • Click Create
  3. Copy the token (you won't see it again)

EOF

TOKEN="$(prompt_secret "Paste Asana PAT")"
[[ -n "$TOKEN" ]] || die "PAT cannot be empty"

env_set_var "$VAR" "$TOKEN"
chmod 600 "$ENV_FILE"

ok "stored $VAR in $ENV_FILE"
info "Next: run ./bootstrap/lib/register-mcps.sh to register the asana_$KIND MCP"
