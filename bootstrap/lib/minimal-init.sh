#!/usr/bin/env bash
# bootstrap/lib/minimal-init.sh
#
# Set up the SHARED MCP integration layer at ~/.config/openbrain/.
# No vault, no CLAUDE.md, no Home.md, no hooks — JUST the directories,
# .env, and runtime launcher scripts that any consumer of the
# davidianstyle MCPs needs.
#
# Called by:
#   - OpenBrain's own setup.sh (step 4 of the wizard, in place of the
#     inlined logic that previously lived there)
#   - External consumers (e.g., doro-events/bootstrap/setup.sh) that
#     need the MCP-installer machinery without the rest of the vault
#     experience. Those consumers shallow-clone this repo to /tmp, run
#     this script, vendor the per-service `add-*.sh` scripts they need,
#     and stop.
#
# Idempotent: re-running won't clobber an existing $ENV_FILE; launcher
# script copies are unconditional overwrites of $LIB_DIR/*.sh from the
# repo's .openbrain/lib/ (so a re-run picks up upstream changes).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ensure_env_file                  # mkdir $CONFIG_DIR + create $ENV_FILE from template

mkdir -p "$TOKEN_DIR" "$LIB_DIR"
chmod 700 "$CONFIG_DIR" "$TOKEN_DIR"
chmod 755 "$LIB_DIR"
chmod 600 "$ENV_FILE"

for f in "$REPO_ROOT/.openbrain/lib/"*.sh; do
  dest="$LIB_DIR/$(basename "$f")"
  cp "$f" "$dest"
  chmod 755 "$dest"
done

ok "minimal init complete: $CONFIG_DIR"
