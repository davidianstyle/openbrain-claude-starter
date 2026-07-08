#!/usr/bin/env bash
# Register every configured MCP server with Claude Code.
#
# Reads ~/.config/openbrain/.env and ~/.config/openbrain/tokens/ to discover
# which Google slugs, Slack workspaces, Asana workspaces, and Fathom keys are
# configured, then ensures ~/.claude.json has matching mcpServers entries.
#
# Writes launcher scripts to ~/.config/openbrain/lib/ as a side effect so the
# MCP entries point at stable per-machine paths (not the vault repo path).
#
# Idempotent: re-running updates existing entries in place and removes stale
# openbrain-managed entries no longer in the current config.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ensure_python3
load_env

# CLAUDE_JSON comes from common.sh (overridable via OPENBRAIN_CLAUDE_JSON for
# sandboxed testing — never point it at live config in a test).
[[ -f "$CLAUDE_JSON" ]] || die "$CLAUDE_JSON not found — start Claude Code at least once to initialize it"

# -----------------------------------------------------------------------------
# 1. Install launcher scripts to ~/.config/openbrain/lib/
# -----------------------------------------------------------------------------
mkdir -p "$LIB_DIR"
chmod 755 "$LIB_DIR"
# Deploy ONLY the runtime launcher set (managed_launchers in common.sh is the
# single definition — *-mcp.sh + _common.sh). Other .openbrain/lib/*.sh
# (clone-pii-gate.sh, rebuild-next.sh) are clone-tier tooling that runs from
# the repo, not the per-machine runtime — don't pollute LIB_DIR with them.
while IFS= read -r f; do
  dest="$LIB_DIR/$(basename "$f")"
  if ! cmp -s "$f" "$dest" 2>/dev/null; then
    cp "$f" "$dest"
    chmod 755 "$dest"
  fi
done < <(managed_launchers "$REPO_ROOT/.openbrain/lib")
ok "launcher scripts installed at $LIB_DIR"

# -----------------------------------------------------------------------------
# 2. Discover configured accounts and write to a JSON plan file
# -----------------------------------------------------------------------------
PLAN="$(mktemp)"
trap 'rm -f "$PLAN"' EXIT

GOOGLE_SLUGS_JSON='[]'
if compgen -G "$TOKEN_DIR/google-*-credentials.json" > /dev/null; then
  GOOGLE_SLUGS_JSON="$(
    for f in "$TOKEN_DIR"/google-*-credentials.json; do
      base="${f##*/}"; slug="${base#google-}"; slug="${slug%-credentials.json}"
      printf '%s\n' "$slug"
    done | "$PYTHON_BIN" -c 'import sys, json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
  )"
fi

SLACK_SLUGS_JSON='[]'
if grep -qE '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE"; then
  SLACK_SLUGS_JSON="$(
    grep -E '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE" \
      | sed -E 's/^SLACK_TOKEN_([A-Z0-9_]+)=.*/\1/' \
      | "$PYTHON_BIN" -c '
import sys, json
slugs = []
for line in sys.stdin:
    upper = line.strip()
    if not upper:
        continue
    slugs.append(upper.lower().replace("_", "-"))
print(json.dumps(slugs))
'
  )"
fi

HAS_ASANA_PERSONAL=false; [[ -n "${ASANA_PAT_PERSONAL:-}" ]] && HAS_ASANA_PERSONAL=true
HAS_ASANA_WORK=false;     [[ -n "${ASANA_PAT_WORK:-}" ]]     && HAS_ASANA_WORK=true
HAS_FATHOM=false;         [[ -n "${FATHOM_API_KEY:-}" ]]     && HAS_FATHOM=true

cat >"$PLAN" <<EOF
{
  "lib_dir": "$LIB_DIR",
  "google_slugs": $GOOGLE_SLUGS_JSON,
  "slack_slugs": $SLACK_SLUGS_JSON,
  "has_asana_personal": $HAS_ASANA_PERSONAL,
  "has_asana_work": $HAS_ASANA_WORK,
  "has_fathom": $HAS_FATHOM
}
EOF

step "Discovered MCP config"
"$PYTHON_BIN" - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
print(f"  Google accounts: {len(plan['google_slugs'])}")
for s in plan['google_slugs']: print(f"    • {s}")
print(f"  Slack workspaces: {len(plan['slack_slugs'])}")
for s in plan['slack_slugs']: print(f"    • {s}")
print(f"  Asana personal: {plan['has_asana_personal']}")
print(f"  Asana work:     {plan['has_asana_work']}")
print(f"  Fathom:         {plan['has_fathom']}")
PY

# -----------------------------------------------------------------------------
# 3. Merge plan into ~/.claude.json
# -----------------------------------------------------------------------------
"$PYTHON_BIN" - "$CLAUDE_JSON" "$PLAN" <<'PY'
import json, os, sys, time
from pathlib import Path

# resolve() so a symlinked ~/.claude.json (dotfiles managers) keeps its link:
# the temp-sibling + os.replace lands on the TARGET, not over the symlink.
claude_path = Path(sys.argv[1]).resolve()
plan = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
lib_dir = plan["lib_dir"].rstrip("/")

# Parse the live file FIRST. If it doesn't parse, abort before touching any
# backup — never let a corrupt registry overwrite the last good backup.
try:
    data = json.loads(claude_path.read_text(encoding="utf-8"))
except Exception as e:
    sys.stderr.write(f"[register-mcps] ABORT: {claude_path} is not valid JSON ({e}); "
                     f"not modifying it and not overwriting backups\n")
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write(f"[register-mcps] ABORT: {claude_path} parses to {type(data).__name__}, "
                     f"not an object; not modifying it\n")
    sys.exit(1)

# Keep-last-good, timestamped backup (never clobber the single prior backup;
# a re-run over a freshly-corrupted file would otherwise destroy the only copy).
stamp = time.strftime("%Y%m%d-%H%M%S")
backup = claude_path.with_name(claude_path.name + f".openbrain-backup-{stamp}")
backup.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
# Prune to the most recent 5 backups.
backups = sorted(claude_path.parent.glob(claude_path.name + ".openbrain-backup-*"))
for old in backups[:-5]:
    try: old.unlink()
    except OSError: pass

servers = data.setdefault("mcpServers", {})

def stdio(name, script, *args):
    servers[name] = {
        "type": "stdio",
        "command": f"{lib_dir}/{script}",
        "args": list(args),
        "env": {},
    }

# Remove openbrain-managed entries before re-writing. PRECISE guard: an entry is
# ours iff its command launcher lives in OUR lib_dir — not the old fragile
# 'openbrain' substring, which would falsely delete a user's server named
# google_*/slack_* whose command path merely contained "openbrain"
# (e.g. ~/openbrain-tools/...). The prefix list only narrows which keys we even
# consider, so a foreign server outside lib_dir is always safe.
managed_prefixes = ("asana_", "gmail_", "gcal_", "gmeet_", "gdrive_", "gslides_", "google_", "slack_")
for k in list(servers.keys()):
    v = servers[k]
    cmd = v.get("command") if isinstance(v, dict) else ""
    if not isinstance(cmd, str):
        cmd = ""  # explicit null / non-string command is never ours
    if k == "fathom" or k.startswith(managed_prefixes):
        # normpath both sides: lexical differences (double slashes, ./ or ..
        # segments) must not let a managed entry dodge the guard or vice versa.
        if os.path.normpath(os.path.dirname(cmd)) == os.path.normpath(lib_dir):
            del servers[k]

if plan["has_asana_personal"]:
    stdio("asana_personal", "asana-mcp.sh", "personal")
if plan["has_asana_work"]:
    stdio("asana_work", "asana-mcp.sh", "work")

for slug in plan["google_slugs"]:
    key = slug.replace("-", "_")
    stdio(f"google_{key}", "google-mcp.sh", slug)

for slug in plan["slack_slugs"]:
    key = slug.replace("-", "_")
    stdio(f"slack_{key}", "slack-mcp.sh", slug)

if plan["has_fathom"]:
    stdio("fathom", "fathom-mcp.sh")

# Atomic write: serialize, write to a temp sibling, parse-verify, then
# os.replace (atomic on the same filesystem). A crash mid-write can't leave a
# truncated/unparseable ~/.claude.json that would brick Claude Code.
payload = json.dumps(data, indent=2, ensure_ascii=False)
json.loads(payload)  # paranoia: the bytes we're about to commit must parse
tmp = claude_path.with_name(claude_path.name + ".openbrain-tmp")
tmp.write_text(payload, encoding="utf-8")
os.replace(tmp, claude_path)

print(f"[register-mcps] backup: {backup}")
print(f"[register-mcps] wrote {len(servers)} total MCP servers to {claude_path}")
for name in sorted(servers.keys()):
    print(f"  • {name}")
PY

# -----------------------------------------------------------------------------
# 4. Reconcile launcher FILES: remove managed *-mcp.sh launchers in LIB_DIR
#    whose source no longer exists in the repo (e.g. legacy split launchers
#    gcal/gmail/gmeet/gdrive-mcp.sh from before the google-mcp consolidation).
#    Runs AFTER the registry rewrite above, so no live mcpServers entry can
#    still point at a launcher we remove. Strictly scoped to *-mcp.sh — never
#    touches _common.sh, shims/, or non-launcher files. Backs up rather than rm
#    (files under ~/.config are not git-recoverable).
# -----------------------------------------------------------------------------
shopt -s nullglob
orphan_backup="$LIB_DIR/.orphaned-launchers"
for dest in "$LIB_DIR"/*-mcp.sh; do
  src="$REPO_ROOT/.openbrain/lib/$(basename "$dest")"
  if [[ ! -e "$src" ]]; then
    mkdir -p "$orphan_backup"
    mv -f "$dest" "$orphan_backup/$(basename "$dest").$(date +%Y%m%d-%H%M%S)"
    warn "orphaned launcher removed (backed up to $orphan_backup): $(basename "$dest")"
  fi
done
shopt -u nullglob

step "Done registering MCPs"
info "Restart Claude Code so it picks up the new mcpServers entries"
info "Verify with: claude mcp list (or run /mcp inside a session)"
