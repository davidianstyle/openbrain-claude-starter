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
#   - External consumers (e.g. a separate project's bootstrap) that
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

src_lib="$REPO_ROOT/.openbrain/lib"
[[ -d "$src_lib" ]] || die "launcher source dir not found: $src_lib (broken checkout?)"
copied=0
for f in "$src_lib/"*.sh; do
  [[ -e "$f" ]] || continue  # glob stayed literal → no .sh present; fail loudly below
  dest="$LIB_DIR/$(basename "$f")"
  rm -f "$dest"          # replace a stale file or dev symlink, don't write through it
  cp "$f" "$dest"
  chmod 755 "$dest"
  copied=$((copied + 1))
done
(( copied > 0 )) || die "no launcher scripts in $src_lib — refusing a partial install"

ok "minimal init complete: $CONFIG_DIR"
