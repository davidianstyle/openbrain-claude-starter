#!/usr/bin/env bash
# Wire OpenBrain's SessionStart/Stop hooks into .claude/settings.json — the
# single source of truth for that wiring (setup.sh calls this at bootstrap; the
# pull's runtime-reconcile calls it when a hook-invocation change lands).
#
# MERGE-SAFE by design. settings.json is gitignored and may carry user edits:
# extra hooks (PreToolUse, …), an env prepend on the command
# (OPENBRAIN_AUTOPUSH=0 …), a customized timeout or statusMessage. This script:
#   - adds an openbrain hook entry only if that event has none;
#   - if one exists, fixes ONLY a stale script-path prefix (e.g. the vault
#     moved), preserving any env prepend, timeout, and statusMessage the user set;
#   - collapses duplicate openbrain entries for an event down to one;
#   - never touches foreign hooks or other events.
# An openbrain entry is identified by its command containing the script-path
# suffix `/.openbrain/<script>` — robust to env prepends and absolute-path moves.
#
# Atomic + validated write: a crash or malformed merge can never leave an
# unparseable settings.json that bricks Claude Code.
#
# Usage: wire-claude-hooks.sh [REPO_ROOT] [SETTINGS_FILE]
#   defaults: REPO_ROOT from common.sh; SETTINGS_FILE=$REPO_ROOT/.claude/settings.json
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
ensure_python3

WCH_REPO_ROOT="${1:-$REPO_ROOT}"
SETTINGS_FILE="${2:-$WCH_REPO_ROOT/.claude/settings.json}"
mkdir -p "$(dirname "$SETTINGS_FILE")"

"$PYTHON_BIN" - "$SETTINGS_FILE" "$WCH_REPO_ROOT" <<'PY'
import json, os, sys
from pathlib import Path

settings_path = Path(sys.argv[1])
repo_root = sys.argv[2].rstrip("/")

# Canonical openbrain hooks. timeout/statusMessage are used ONLY when CREATING a
# missing entry — never forced onto an existing one (that would clobber user
# customizations). Keep these equal to what setup.sh historically generated so
# factoring this out is behavior-neutral at first bootstrap.
CANON = {
    "SessionStart": {"script": ".openbrain/on-start.sh", "timeout": 30,  "statusMessage": "OpenBrain: pulling latest"},
    "Stop":         {"script": ".openbrain/on-stop.sh",  "timeout": 120, "statusMessage": "OpenBrain: syncing to git"},
}

# Load existing (tolerate absent/empty/corrupt → start clean, but back up a
# corrupt file rather than silently discard it).
data = {}
if settings_path.exists():
    raw = settings_path.read_text()
    if raw.strip():
        try:
            data = json.loads(raw)
        except Exception:
            bak = settings_path.with_name(settings_path.name + ".corrupt-backup")
            bak.write_text(raw)
            sys.stderr.write(f"[wire-claude-hooks] existing settings.json was unparseable; "
                             f"backed up to {bak}, regenerating hooks block\n")
            data = {}
if not isinstance(data, dict):
    data = {}

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("[wire-claude-hooks] .hooks is not an object; refusing to edit")

def owned_path(cmd, basename):
    """Return the path token in cmd ending in /.openbrain/<basename>, or None.
    cmd may be 'ENV=x /abs/.openbrain/on-start.sh' — owns by suffix, not equality."""
    for tok in cmd.split():
        if tok.endswith("/.openbrain/" + basename):
            return tok
    return None

changed = []
for event, spec in CANON.items():
    basename = spec["script"].split("/")[-1]
    want_path = f"{repo_root}/{spec['script']}"
    groups = hooks.get(event)
    if not isinstance(groups, list):
        groups = []
        hooks[event] = groups

    # Collect (group, inner-hook) pairs that are openbrain-owned for this event.
    owned = []
    for g in groups:
        if not isinstance(g, dict):
            continue
        for h in g.get("hooks", []):
            if isinstance(h, dict) and isinstance(h.get("command"), str):
                if owned_path(h["command"], basename) is not None:
                    owned.append((g, h))

    if not owned:
        # No openbrain entry for this event → add the canonical one.
        groups.append({"hooks": [{
            "type": "command",
            "command": want_path,
            "timeout": spec["timeout"],
            "statusMessage": spec["statusMessage"],
        }]})
        changed.append(f"{event}: added")
        continue

    # Keep the first owned entry; fix ONLY a stale path prefix, preserving any
    # env prepend / other tokens. Drop the rest as duplicates.
    keep_group, keep_hook = owned[0]
    cur = keep_hook["command"]
    cur_path = owned_path(cur, basename)
    if cur_path != want_path:
        keep_hook["command"] = cur.replace(cur_path, want_path)
        changed.append(f"{event}: path → {want_path}")

    if len(owned) > 1:
        # Remove duplicate owned inner-hooks (and any group left empty).
        for g, h in owned[1:]:
            if h in g.get("hooks", []):
                g["hooks"].remove(h)
        hooks[event] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
        changed.append(f"{event}: deduped {len(owned)-1} stale")

# Atomic + validated write.
payload = json.dumps(data, indent=2) + "\n"
json.loads(payload)  # must parse before we commit it
tmp = settings_path.with_name(settings_path.name + ".openbrain-tmp")
tmp.write_text(payload)
os.replace(tmp, settings_path)

if changed:
    print("[wire-claude-hooks] " + "; ".join(changed))
else:
    print("[wire-claude-hooks] hooks already correct (no change)")
PY
