#!/usr/bin/env bash
# One-time Google Cloud OAuth setup.
# Walks the user through GCP console steps and stores client_id/secret in .env.
#
# Supports two flows:
#   • New app  — prints the full GCP Console walkthrough, then prompts for the
#     client_id/secret the user just minted.
#   • Existing app — skips the walkthrough; user pastes credentials they
#     already have (e.g., from a team password manager / shared app).
#
# Safe to re-run: if credentials are already in .env, asks before overwriting.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ensure_env_file
load_env || true  # OK if not yet populated

if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" && -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]]; then
  ok "Google OAuth client already configured in $ENV_FILE"
  if ! yes_no "Re-enter credentials anyway?" n; then
    exit 0
  fi
fi

# Skip the GCP walkthrough for users reusing an existing OAuth client
# (e.g., a shared team app). They still get the two paste prompts below.
if yes_no "Reusing an existing OAuth client (e.g., a shared team app)?" n; then
  info "Skipping Google Cloud Console walkthrough. Paste credentials from your password manager when prompted."
else
  step "Google Cloud Console — one-time setup"
  cat <<'EOF'

Follow these steps in your browser. Keep this terminal open; you'll paste
two values back at the end.

  1. Open https://console.cloud.google.com
  2. Create a new project (e.g. "openbrain-mcp") — or pick an existing one
  3. APIs & Services → Library → enable ALL of:
       • Gmail API
       • Google Calendar API
       • Google Meet REST API
       • Google Drive API
       • Google Docs API
       • Google Sheets API
  4. APIs & Services → OAuth consent screen
       • User Type: External
       • App name: OpenBrain MCP
       • Support email: (your email)
       • Developer contact: (your email)
       • Scopes: leave default (will be requested at runtime)
       • Publishing status:
           - Testing  → quickest path; add EVERY Google address you plan to wire
             up under "Test users". BUT Google expires refresh tokens after
             ~7 days in testing mode, so you'll re-auth every week.
           - In production (verified branding)  → long-lived refresh tokens
             (no 7-day expiry). Requires app verification — fine for a personal
             Desktop client with no public users; takes a few days but is a
             one-time cost. Recommended once you're past the experimentation phase.
  5. APIs & Services → Credentials → + Create credentials → OAuth client ID
       • Application type: Desktop app
       • Name: openbrain-mcp-desktop
       • Click Create
  6. A modal appears with the client ID and secret — copy both NOW. Google
     no longer lets you re-view the secret later; if you lose it you'll need
     to mint a new one via "+ Add secret".

EOF
fi

CLIENT_ID="$(prompt 'Paste OAuth client ID')"
[[ -n "$CLIENT_ID" ]] || die "client ID cannot be empty"

CLIENT_SECRET="$(prompt_secret 'Paste OAuth client secret')"
[[ -n "$CLIENT_SECRET" ]] || die "client secret cannot be empty"

env_set_var GOOGLE_OAUTH_CLIENT_ID "$CLIENT_ID"
env_set_var GOOGLE_OAUTH_CLIENT_SECRET "$CLIENT_SECRET"
chmod 600 "$ENV_FILE"

# Also write the oauth-client.json that Gmail MCP needs
mkdir -p "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"
cat >"$TOKEN_DIR/oauth-client.json" <<EOF
{
  "installed": {
    "client_id": "${CLIENT_ID}",
    "client_secret": "${CLIENT_SECRET}",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "redirect_uris": ["http://localhost"]
  }
}
EOF
chmod 600 "$TOKEN_DIR/oauth-client.json"

ok "Google OAuth client stored in $ENV_FILE and $TOKEN_DIR/oauth-client.json"
info "Next: add individual Google accounts with ./bootstrap/lib/add-google-account.sh <email>"
