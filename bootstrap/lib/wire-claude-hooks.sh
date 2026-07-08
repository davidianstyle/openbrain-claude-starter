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
import json, os, re, sys
from pathlib import Path

# resolve() so a symlinked settings.json (dotfiles managers) keeps its link:
# the temp-sibling + os.replace lands on the TARGET, not over the symlink.
settings_path = Path(sys.argv[1])
if settings_path.exists():
    settings_path = settings_path.resolve()
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
    raw = settings_path.read_text(encoding="utf-8")
    if raw.strip():
        try:
            data = json.loads(raw)
        except Exception:
            bak = settings_path.with_name(settings_path.name + ".corrupt-backup")
            bak.write_text(raw, encoding="utf-8")
            sys.stderr.write(f"[wire-claude-hooks] existing settings.json was unparseable; "
                             f"backed up to {bak}, regenerating hooks block\n")
            data = {}
if not isinstance(data, dict):
    data = {}

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("[wire-claude-hooks] .hooks is not an object; refusing to edit")

def owned_span(cmd, basename):
    """Return the exact substring of cmd that is the openbrain script path
    (ending in /.openbrain/<basename>), including surrounding quotes if any,
    or None. Handles env prepends ('ENV=x /abs/…'), quoted paths, and
    unquoted paths containing spaces — token-splitting would return only the
    last fragment of a spaced path and corrupt the command on replacement."""
    suffix = "/.openbrain/" + basename
    idx = cmd.find(suffix)
    if idx == -1:
        return None
    end = idx + len(suffix)
    # Quoted path: a closing quote right after the suffix with a matching
    # opener earlier — return the span including its quotes. But ONLY if the
    # quoted content reads as a path: a shell-wrapper string
    # (sh -c 'cmd && /path/.openbrain/on-start.sh') also puts its closing
    # quote right after the suffix, and returning that span would fold the
    # wrapper's whole body into the "path" and destroy it on replacement.
    # Wrapper-shaped content (first word not path-shaped) falls through to
    # the left-scan below, which extracts the bare path span from inside the
    # quoted body and repairs it in place.
    if end < len(cmd) and cmd[end] in "'\"":
        q = cmd[end]
        start = cmd.rfind(q, 0, idx)
        if start != -1:
            inner = cmd[start + 1:end]
            first = inner.split(" ")[0] if inner else ""
            if first.startswith(("/", ".", "~", "$")) or "/" in first:
                return cmd[start:end + 1]
    # Unquoted: scan from the LEFT, skipping tokens that cannot start the
    # script path — env prepends (NAME=VALUE), wrapper words/flags with no
    # path shape (e.g. 'bash', 'nice', '-n', '10'), and known interpreters/
    # wrappers given as ABSOLUTE paths ('/bin/bash', '/usr/bin/env'): those
    # contain '/' but are not the script path's first fragment, and treating
    # them as it would fold the wrapper into the span and destroy it on
    # replacement. The basename allowlist keeps this bounded — an unlisted
    # abs-path wrapper still breaks the scan early (rare; documented trade).
    # Everything from the first path-shaped token through the suffix is the
    # span. A backward scan keyed on token prefixes is ambiguous here: an
    # interior fragment of a spaced path may itself start with '.', '~', '$'
    # or '/' ('My .secret/…') and would truncate the span.
    WRAPPERS = ("env", "bash", "sh", "zsh", "dash", "python", "python3", "node", "nice")
    toks = cmd[:end].split(" ")
    i = 0
    while i < len(toks) - 1:
        t = toks[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1  # env-assignment prepend
            continue
        if "/" in t and t.rsplit("/", 1)[-1] in WRAPPERS:
            i += 1  # known interpreter/wrapper by absolute path
            continue
        if "/" not in t and not t.startswith(("~", "$", ".")):
            i += 1  # wrapper word or flag (no path shape)
            continue
        break
    return " ".join(toks[i:])

def unquoted(span):
    """The path inside a span, quotes removed if present."""
    if span[:1] in "'\"" and span[-1:] == span[:1] and len(span) >= 2:
        return span[1:-1]
    return span

def as_command_path(path):
    """A path formatted for use inside a hook command string: quoted iff needed."""
    return f'"{path}"' if " " in path else path

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
        # "hooks" may be explicitly null or a non-list — iterate only a real list.
        inner = g.get("hooks")
        if not isinstance(inner, list):
            continue
        for h in inner:
            if isinstance(h, dict) and isinstance(h.get("command"), str):
                if owned_span(h["command"], basename) is not None:
                    owned.append((g, h))

    if not owned:
        # No openbrain entry for this event → add the canonical one.
        groups.append({"hooks": [{
            "type": "command",
            "command": as_command_path(want_path),
            "timeout": spec["timeout"],
            "statusMessage": spec["statusMessage"],
        }]})
        changed.append(f"{event}: added")
        continue

    # Keep the first owned entry; fix ONLY a stale path prefix, preserving any
    # env prepend / other tokens — and the original quoting style, so a quoted
    # spaced path stays quoted (and a replacement that needs quotes gets them).
    # Drop the rest as duplicates.
    keep_group, keep_hook = owned[0]
    cur = keep_hook["command"]
    cur_span = owned_span(cur, basename)
    if unquoted(cur_span) != want_path:
        if cur_span[:1] in "'\"" and cur_span[-1:] == cur_span[:1]:
            new_span = cur_span[0] + want_path + cur_span[0]
        else:
            new_span = as_command_path(want_path)
        keep_hook["command"] = cur.replace(cur_span, new_span, 1)
        changed.append(f"{event}: path → {want_path}")

    if len(owned) > 1:
        # Remove duplicate owned inner-hooks (and any group left empty).
        for g, h in owned[1:]:
            if h in g.get("hooks", []):
                g["hooks"].remove(h)
        hooks[event] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
        changed.append(f"{event}: deduped {len(owned)-1} stale")

# Atomic + validated write — ONLY when something semantically changed. The
# no-change path must not touch the file at all: an unconditional write
# reserializes to json.dumps(..., indent=2, ensure_ascii=False) + "\n", so any
# file an external writer formatted differently (legacy \uXXXX escapes from an
# ensure_ascii dump, another tool's indent/ordering, hand edits) would be
# rewritten here — and the runtime reconciler, which detects hook drift by
# running this wirer on a COPY and byte-comparing, would read that pure
# formatting delta as drift on every run and "converge" it forever.
if changed:
    payload = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    json.loads(payload)  # must parse before we commit it
    tmp = settings_path.with_name(settings_path.name + ".openbrain-tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, settings_path)
    print("[wire-claude-hooks] " + "; ".join(changed))
else:
    print("[wire-claude-hooks] hooks already correct (no change)")
PY
