#!/usr/bin/env bash
# refresh-google-tokens.sh — refresh OAuth tokens for configured Google accounts.
#
# Three modes:
#
#   refresh-google-tokens.sh              # probe + refresh access tokens for every
#                                         # configured account (non-interactive).
#                                         # Reports OK or NEEDS-REAUTH per slug.
#                                         # Use when MCPs start failing — finds
#                                         # which account's refresh_token is dead.
#
#   refresh-google-tokens.sh <email>      # full re-auth (OAuth flow in browser)
#                                         # for one account. Delegates to
#                                         # add-google-account.sh. Use when probe
#                                         # reports NEEDS-REAUTH, or after scope
#                                         # changes / revoke / reset.
#
#   refresh-google-tokens.sh --all        # full re-auth for every configured
#                                         # account. Opens N browsers in sequence.
#
# Background:
#   Each Google account's credentials live in $TOKEN_DIR/google-<slug>-credentials.json
#   plus 3 reshaped copies for the per-service MCPs (Calendar / Meet / Drive).
#   In probe mode this script exchanges the stored refresh_token for a fresh
#   access_token via Google's OAuth2 token endpoint and rewrites all 4 files.
#   The MCPs would normally do this on demand, but doing it explicitly:
#     1. detects revoked / expired refresh tokens before runtime,
#     2. warms the cached access_token so the next MCP call is fast.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

usage() {
  cat <<EOF
usage: refresh-google-tokens.sh [<email> | --all]
  (no args)   probe + refresh access tokens for all accounts (non-interactive)
  <email>     re-run full OAuth flow for one account (interactive, browser)
  --all       re-run full OAuth flow for every configured account (interactive)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ensure_env_file
load_env

# Discover configured slugs from the credentials files. Same approach as
# register-mcps.sh — the filesystem is the source of truth.
SLUGS=()
if compgen -G "$TOKEN_DIR/google-*-credentials.json" > /dev/null; then
  for f in "$TOKEN_DIR"/google-*-credentials.json; do
    base="${f##*/}"
    slug="${base#google-}"
    slug="${slug%-credentials.json}"
    SLUGS+=("$slug")
  done
fi

if [[ ${#SLUGS[@]} -eq 0 ]]; then
  info "no Google accounts configured, skipping token refresh"
  exit 0
fi

# Resolve slug → email by reading the GOOGLE_SLUGS block in .env
# (lines look like `# you-example-com (you@example.com)`)
slug_to_email() {
  local slug="$1"
  grep -E "^# ${slug} \(.+\)\$" "$ENV_FILE" 2>/dev/null \
    | sed -E "s/^# ${slug} \((.+)\)\$/\1/" \
    | head -1 || true
}

case "${1:-}" in
  --all)
    step "Re-running OAuth flow for all ${#SLUGS[@]} Google accounts"
    for slug in "${SLUGS[@]}"; do
      email="$(slug_to_email "$slug")"
      if [[ -z "$email" ]]; then
        warn "could not resolve email for slug $slug — skipping"
        continue
      fi
      info "re-authing $email"
      "$HERE/add-google-account.sh" "$email"
    done
    ok "all done"
    ;;

  "")
    # If the OAuth client changed since these accounts were connected (the
    # .env secret no longer matches the fingerprint the tokens were minted
    # against), emit a friendly, non-technical reconnect nudge. Bracketed by
    # sentinels so a consumer's SessionStart hook can surface it verbatim,
    # regardless of whether the probe below succeeds or fails. We only nudge;
    # the actual reconnect is the user's call (per account).
    if auth_drift_detected google; then
      printf 'OPENBRAIN_AUTH_NUDGE_BEGIN\n'
      printf '🔑 Heads up — your Google connection settings changed.\n'
      printf 'The security details for your Google sign-in were updated since you last\n'
      printf 'connected, so Gmail, Calendar, and Drive may stop working until you reconnect.\n'
      printf '\n'
      printf 'Claude can reconnect these for you — just ask, and pick which ones. It opens\n'
      printf 'a browser to sign in (about a minute each):\n'
      for slug in "${SLUGS[@]}"; do
        email="$(slug_to_email "$slug")"
        printf '  • %s\n' "${email:-$slug}"
      done
      printf "(If you didn't change anything recently, reconnecting is still safe.)\n"
      printf 'OPENBRAIN_AUTH_NUDGE_END\n'
    fi

    ensure_venv
    step "Refreshing access tokens for ${#SLUGS[@]} Google accounts"
    fail_count=0
    ok_count=0
    tmp_err="$(mktemp)"
    trap 'rm -f "$tmp_err"' EXIT
    for slug in "${SLUGS[@]}"; do
      creds="$TOKEN_DIR/google-${slug}-credentials.json"
      gcal="$TOKEN_DIR/google-${slug}-gcal-token.json"
      gmeet="$TOKEN_DIR/google-${slug}-gmeet-token.json"
      gdrive_dir="$DRIVE_TOKEN_ROOT/$slug"
      gdrive="$gdrive_dir/token.json"

      if "$VENV_DIR/bin/python3" - "$creds" "$gcal" "$gmeet" "$gdrive" "$gdrive_dir" <<'PY' 2>"$tmp_err"
import json, os, sys
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

creds_path, gcal_path, gmeet_path, gdrive_path, gdrive_dir = sys.argv[1:6]

with open(creds_path) as f:
    src = json.load(f)

creds = Credentials(
    token=src.get("token"),
    refresh_token=src["refresh_token"],
    token_uri=src.get("token_uri", "https://oauth2.googleapis.com/token"),
    client_id=src["client_id"],
    client_secret=src["client_secret"],
    scopes=src.get("scopes"),
)

creds.refresh(Request())

src["token"] = creds.token
src["scopes"] = list(creds.scopes or src.get("scopes") or [])
with open(creds_path, "w") as f:
    json.dump(src, f, indent=2)
os.chmod(creds_path, 0o600)

expiry_ms = int(creds.expiry.timestamp() * 1000) if creds.expiry else 1
gcal_out = {
    "refresh_token": creds.refresh_token,
    "access_token": creds.token,
    "scope": " ".join(src["scopes"]),
    "token_type": "Bearer",
    "expiry_date": expiry_ms,
}
for p in (gcal_path, gmeet_path):
    with open(p, "w") as f:
        json.dump(gcal_out, f, indent=2)
    os.chmod(p, 0o600)

os.makedirs(gdrive_dir, mode=0o700, exist_ok=True)
gdrive_out = {
    "type": "authorized_user",
    "client_id": src["client_id"],
    "refresh_token": creds.refresh_token,
}
with open(gdrive_path, "w") as f:
    json.dump(gdrive_out, f, indent=2)
os.chmod(gdrive_path, 0o600)
PY
      then
        ok "$slug — access token refreshed"
        ok_count=$((ok_count + 1))
      else
        err_msg="$(tr '\n' ' ' < "$tmp_err" | head -c 200)"
        email="$(slug_to_email "$slug")"
        warn "$slug — refresh failed: $err_msg"
        if [[ -n "$email" ]]; then
          info "  → fix with: $(printf '%q %q' "$HERE/refresh-google-tokens.sh" "$email")"
        fi
        fail_count=$((fail_count + 1))
      fi
    done
    printf '\n'
    if (( fail_count > 0 )); then
      die "$ok_count OK · $fail_count NEEDS-REAUTH"
    fi
    ok "all $ok_count accounts refreshed cleanly"
    ;;

  --*)
    err "unknown flag: $1"
    usage
    exit 2
    ;;

  *)
    # Treat as an email — delegate to add-google-account.sh, which already
    # handles re-auth idempotently.
    "$HERE/add-google-account.sh" "$1"
    ;;
esac
