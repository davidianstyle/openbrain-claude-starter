#!/usr/bin/env bash
# Add a single Google account to the OpenBrain MCP config.
#
# Performs ONE OAuth dance requesting all scopes (Gmail + Calendar + Meet + Drive)
# and reshapes the resulting refresh token into the four formats each MCP expects:
#
#   ~/.config/openbrain/tokens/google-<slug>-credentials.json   (Gmail MCP)
#   ~/.config/openbrain/tokens/google-<slug>-gcal-token.json    (Calendar MCP)
#   ~/.config/openbrain/tokens/google-<slug>-gmeet-token.json   (Meet MCP)
#   ~/.config/google-docs-mcp/<slug>/token.json                 (Drive/Docs/Sheets MCP)
#
# The slug is appended to the GOOGLE_SLUGS block in ~/.config/openbrain/.env
# so register-mcps.sh knows which servers to register.
#
# Usage: add-google-account.sh <email>
#        add-google-account.sh jane@acme.com
#
# Idempotent: re-running for the same email re-runs the OAuth flow (useful if
# scopes changed or the refresh token was revoked).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

EMAIL="${1:?usage: add-google-account.sh <email>}"
SLUG="$(email_to_slug "$EMAIL")"

info "Adding Google account: $EMAIL (slug: $SLUG)"

ensure_env_file
load_env

if [[ -z "${GOOGLE_OAUTH_CLIENT_ID:-}" || -z "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]]; then
  warn "Google OAuth client not yet configured"
  info "Running setup-google-oauth.sh first..."
  "$HERE/setup-google-oauth.sh"
  load_env
fi

ensure_venv
mkdir -p "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"

OAUTH_CLIENT="$TOKEN_DIR/oauth-client.json"
CREDS_FILE="$TOKEN_DIR/google-${SLUG}-credentials.json"
GCAL_TOKEN="$TOKEN_DIR/google-${SLUG}-gcal-token.json"
GMEET_TOKEN="$TOKEN_DIR/google-${SLUG}-gmeet-token.json"
GDRIVE_TOKEN_DIR="$DRIVE_TOKEN_ROOT/$SLUG"
GDRIVE_TOKEN="$GDRIVE_TOKEN_DIR/token.json"

# Ensure the shared oauth-client.json exists (setup-google-oauth.sh should have created it)
if [[ ! -f "$OAUTH_CLIENT" ]]; then
  cat >"$OAUTH_CLIENT" <<EOF
{
  "installed": {
    "client_id": "${GOOGLE_OAUTH_CLIENT_ID}",
    "client_secret": "${GOOGLE_OAUTH_CLIENT_SECRET}",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "redirect_uris": ["http://localhost"]
  }
}
EOF
  chmod 600 "$OAUTH_CLIENT"
fi

step "Opening browser to authorize $EMAIL"
cat <<EOF

You'll see a Google consent screen. Sign in as:

  $_C_BOLD$EMAIL$_C_RESET

and approve all requested scopes. If the screen shows a different account,
use the "Switch account" link.

If you see "Google hasn't verified this app", click Advanced → Go to
OpenBrain MCP (unsafe) — that's expected because the OAuth consent screen
is in Testing mode.

EOF

"$VENV_DIR/bin/python3" - "$OAUTH_CLIENT" "$CREDS_FILE" "$SLUG" "$EMAIL" <<'PY'
import json, os, sys

try:
    from google_auth_oauthlib.flow import InstalledAppFlow
except ImportError:
    sys.stderr.write("add-google-account: venv missing google-auth-oauthlib — delete ~/.config/openbrain/venv and re-run\n")
    sys.exit(1)

client_file, creds_file, slug, email = sys.argv[1:5]

SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/meetings.space.readonly",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/spreadsheets",
]

flow = InstalledAppFlow.from_client_secrets_file(client_file, SCOPES)
creds = flow.run_local_server(
    port=0,
    access_type="offline",
    prompt="consent",
    authorization_prompt_message=f"[openbrain] Authorize {email} here: {{url}}",
    success_message=f"[openbrain] Authorized — you can close this tab. ({email})",
    open_browser=True,
)

out = {
    "client_id": creds.client_id,
    "client_secret": creds.client_secret,
    "refresh_token": creds.refresh_token,
    "token": creds.token,
    "token_uri": creds.token_uri,
    "scopes": list(creds.scopes or SCOPES),
}
with open(creds_file, "w") as f:
    json.dump(out, f, indent=2)
os.chmod(creds_file, 0o600)
print(f"[openbrain] wrote {creds_file}")
PY

ok "minted credentials for $EMAIL"

# -----------------------------------------------------------------------------
# Reshape the credentials into the 3 other token files needed by the other MCPs
# -----------------------------------------------------------------------------
"$VENV_DIR/bin/python3" - "$CREDS_FILE" "$GCAL_TOKEN" "$GMEET_TOKEN" "$GDRIVE_TOKEN" "$GDRIVE_TOKEN_DIR" "$SLUG" <<'PY'
import json, os, sys

src_path, gcal_path, gmeet_path, gdrive_path, gdrive_dir, slug = sys.argv[1:7]
with open(src_path) as f:
    src = json.load(f)

refresh_token = src["refresh_token"]
scopes = src.get("scopes") or []
access_token = src.get("token") or ""
client_id = src["client_id"]

# 1. Calendar MCP token shape (@cocal/google-calendar-mcp)
gcal_out = {
    "refresh_token": refresh_token,
    "access_token": access_token,
    "scope": " ".join(scopes),
    "token_type": "Bearer",
    "expiry_date": 1,  # forces refresh on first API call
}
with open(gcal_path, "w") as f:
    json.dump(gcal_out, f, indent=2)
os.chmod(gcal_path, 0o600)
print(f"[openbrain] wrote {gcal_path}")

# 2. Meet MCP token shape (@dtannen/google-meet-mcp — same shape as Calendar)
with open(gmeet_path, "w") as f:
    json.dump(gcal_out, f, indent=2)
os.chmod(gmeet_path, 0o600)
print(f"[openbrain] wrote {gmeet_path}")

# 3. Drive/Docs/Sheets MCP token shape (@a-bonus/google-docs-mcp)
os.makedirs(gdrive_dir, mode=0o700, exist_ok=True)
gdrive_out = {
    "type": "authorized_user",
    "client_id": client_id,
    "refresh_token": refresh_token,
}
with open(gdrive_path, "w") as f:
    json.dump(gdrive_out, f, indent=2)
os.chmod(gdrive_path, 0o600)
print(f"[openbrain] wrote {gdrive_path}")
PY

ok "reshaped tokens for all 4 Google MCPs"

# -----------------------------------------------------------------------------
# Record the slug in .env so register-mcps.sh picks it up
# -----------------------------------------------------------------------------
env_append_between_markers \
  "# --- GOOGLE_SLUGS (managed by bootstrap) ---" \
  "# --- END GOOGLE_SLUGS ---" \
  "# $SLUG ($EMAIL)"

ok "recorded slug $SLUG in $ENV_FILE"

step "Done adding $EMAIL"
info "Next: run ./bootstrap/lib/register-mcps.sh to register the MCP servers"
info "      or add more accounts with add-google-account.sh <other-email>"
