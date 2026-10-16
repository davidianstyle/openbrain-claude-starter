#!/usr/bin/env bash
# Register every configured MCP server with Claude Code.
#
# Reads ~/.config/openbrain/.env and ~/.config/openbrain/tokens/ to discover
# which Google slugs, Microsoft accounts, Slack workspaces, Asana workspaces,
# and Fathom keys are configured, then ensures ~/.claude.json has matching
# mcpServers entries.
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

# CLAUDE_JSON + CONFIG_DIR come from common.sh (overridable via OPENBRAIN_CLAUDE_JSON
# / OPENBRAIN_CONFIG_DIR for sandboxed testing — never point them at live config
# in a test).
[[ -f "$CLAUDE_JSON" ]] || die "$CLAUDE_JSON not found — start Claude Code at least once to initialize it"

# -----------------------------------------------------------------------------
# 1. Install launcher scripts to ~/.config/openbrain/lib/
# -----------------------------------------------------------------------------
mkdir -p "$LIB_DIR"
chmod 755 "$LIB_DIR"
# Deploy ONLY the runtime launcher set (managed_launchers in common.sh is the
# single definition — *-mcp.sh + _common.sh + _mcp-decl.sh + mcp-local-build.sh). Other .openbrain/lib/*.sh
# (clone-pii-gate.sh, template-scope.sh) are clone-tier tooling that runs from
# the repo, not the per-machine runtime — don't pollute LIB_DIR with them.
while IFS= read -r f; do
  dest="$LIB_DIR/$(basename "$f")"
  if ! cmp -s "$f" "$dest" 2>/dev/null; then
    rm -f "$dest"        # replace a stale file or dev symlink, don't write through it
    cp "$f" "$dest"
    chmod 755 "$dest"
  fi
done < <(managed_launchers "$REPO_ROOT/.openbrain/lib")
ok "launcher scripts installed at $LIB_DIR"
# .openbrain/mcp/ is no longer a source of MCP servers: nothing copies or builds
# it. Say so loudly when it still holds something, instead of silently ignoring it.
if [[ -d "$REPO_ROOT/.openbrain/mcp" ]] && [[ -n "$(ls -A "$REPO_ROOT/.openbrain/mcp")" ]]; then
  warn "$REPO_ROOT/.openbrain/mcp/ is not empty, but custom MCP server copies there are no longer synced or built."
  warn "  To keep running one: make its folder a git repo and commit the code (git init && git add -A && git commit), then give it a"
  warn "  *-mcp.sh launcher in .openbrain/lib/ with a '# openbrain-mcp: shape=checkout dir=<name> url=file:///absolute/path/to/that/repo' declaration"
  warn "  (grammar: .openbrain/lib/_mcp-decl.sh) and register it with 'claude mcp add'. Only committed code is built. See README: Adding your own MCP."
fi

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

MICROSOFT_SLUGS_JSON='[]'
if compgen -G "$TOKEN_DIR/microsoft-*-credentials.json" > /dev/null; then
  MICROSOFT_SLUGS_JSON="$(
    for f in "$TOKEN_DIR"/microsoft-*-credentials.json; do
      base="${f##*/}"; slug="${base#microsoft-}"; slug="${slug%-credentials.json}"
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
  "src_lib_dir": "$REPO_ROOT/.openbrain/lib",
  "google_slugs": $GOOGLE_SLUGS_JSON,
  "microsoft_slugs": $MICROSOFT_SLUGS_JSON,
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
print(f"  Microsoft accounts: {len(plan['microsoft_slugs'])}")
for s in plan['microsoft_slugs']: print(f"    • {s}")
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
src_lib_dir = plan["src_lib_dir"].rstrip("/")

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
    # Launcher-existence guard, checked against the REPO's launcher set (the
    # source section 1 installs from) — NOT the deployed lib_dir: a stale
    # launcher left in lib_dir by a prior deploy of a since-changed repo would
    # otherwise pass the guard here and then be orphan-removed by section 4 in
    # the same run, stranding a registry entry whose command no longer exists.
    # Feature-ahead entries (e.g. gtasks_/mstodo_) stay safe to carry: they
    # self-suppress on repos that don't ship those launchers. (If the repo
    # ships it, section 1 has already copied it into lib_dir, so the entry's
    # command path is guaranteed present.)
    if not os.path.exists(os.path.join(src_lib_dir, script)):
        print(f"[register-mcps] skip {name}: launcher {script} not shipped by this repo (inert)")
        return
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
# gtasks_/mstodo_ are carried here (feature-ahead) so a machine that DOES ship
# those launchers still gets its stale entries cleaned; harmless where absent.
managed_prefixes = ("asana_", "gmail_", "gcal_", "gmeet_", "gdrive_", "gslides_",
                    "gtasks_", "mstodo_", "google_", "slack_")
resolved_lib_dir = Path(lib_dir).resolve()  # constant across the loop; resolve() stats the filesystem
removed_managed = []  # so a delete-without-re-register can warn below instead of vanishing silently
for k in list(servers.keys()):
    v = servers[k]
    cmd = v.get("command") if isinstance(v, dict) else ""
    # Explicit null / empty / non-string command is never ours — and an empty
    # cmd must not reach the normpath guard below: dirname("") → "." equals an
    # empty/degenerate lib_dir and would delete a foreign entry.
    if not isinstance(cmd, str) or not cmd:
        continue
    if k == "fathom" or k.startswith(managed_prefixes):
        # resolve() both sides: lexical differences (double slashes, ./ or ..
        # segments) AND symlinks (a dotfile-managed ~/.config) must not let a
        # managed entry dodge the guard or vice versa. resolve() is non-strict,
        # so entries pointing at already-deleted launchers still compare.
        # Absolute commands only: a bare/relative command ("node") has
        # Path(cmd).parent == ".", which resolves to the CWD and would match
        # lib_dir when the script happens to run from there — a launcher we
        # manage always has an absolute path, so anything else is never ours.
        cmd_path = Path(cmd)
        if cmd_path.is_absolute() and cmd_path.parent.resolve() == resolved_lib_dir:
            del servers[k]
            removed_managed.append(k)

if plan["has_asana_personal"]:
    stdio("asana_personal", "asana-mcp.sh", "personal")
if plan["has_asana_work"]:
    stdio("asana_work", "asana-mcp.sh", "work")

for slug in plan["google_slugs"]:
    key = slug.replace("-", "_")
    stdio(f"google_{key}", "google-mcp.sh", slug)
    stdio(f"gtasks_{key}", "gtasks-mcp.sh", slug)

for slug in plan["microsoft_slugs"]:
    key = slug.replace("-", "_")
    stdio(f"mstodo_{key}", "mstodo-mcp.sh", slug)

for slug in plan["slack_slugs"]:
    key = slug.replace("-", "_")
    stdio(f"slack_{key}", "slack-mcp.sh", slug)

if plan["has_fathom"]:
    stdio("fathom", "fathom-mcp.sh")

# A managed entry that the cleanup removed and no stdio() call re-registered
# has VANISHED this run — the account is still configured but its launcher is
# no longer shipped by this repo. That must be loud (stderr), not a scroll-by
# skip line: every skill routing to that server fails at next session.
vanished = sorted(k for k in removed_managed if k not in servers)
if vanished:
    print(f"[register-mcps] WARNING: previously-registered managed entries removed and NOT re-registered this run: {', '.join(vanished)} — their launchers are not shipped by this repo; skills routing to them will fail", file=sys.stderr)

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
# -----------------------------------------------------------------------------
# Flag CLAUDE.md account-registry drift (guarded with || true; never blocks the
# bootstrap flow). register-mcps is the chokepoint every account add/remove
# funnels through, so it's where a mismatch between the live registry and the
# hand-curated routing listing surfaces. The checker locates the registry block
# by its explicit marker (<!-- openbrain:account-registry -->) and exits loud —
# never silent-clean — when the marker is absent. No-op if the script isn't
# present.
# -----------------------------------------------------------------------------
# -f + explicit bash, not -x + direct exec: a lost executable bit (ZIP
# extraction, some shared mounts) would silently skip the check — the same
# silent-failure class it exists to prevent.
if [[ -f "$HERE/check-registry-drift.sh" ]]; then
  step "Checking CLAUDE.md account registry for drift"
  bash "$HERE/check-registry-drift.sh" || true
fi

step "Done registering MCPs"
info "Restart Claude Code so it picks up the new mcpServers entries"
info "Verify with: claude mcp list (or run /mcp inside a session)"

# -----------------------------------------------------------------------------
# 5. Keep the clone's PII gate patterns in sync with the account registry
#    (sync model v2). register-mcps.sh is the chokepoint every account
#    add/remove funnels through, so it's where the gate's patterns get
#    refreshed. pii-reseed.sh is script-only and this is its only caller; it
#    ships separately. Skipped when the repo doesn't ship it, and
#    a no-op (with a note) on a machine with no clone patterns file to refresh.
# -----------------------------------------------------------------------------
# -f + explicit bash, not -x + direct exec: a lost executable bit (ZIP
# extraction, some shared mounts) would silently skip the reseed — the same
# silent-failure class the drift-check call above guards against.
# || warn, not || true: the reseed MUTATES the PII gate's pattern set; a
# swallowed failure leaves the gate matching stale patterns, and a later
# template push could leak a new account's identifiers with every check
# reporting clean. Still non-blocking — bootstrap continues.
if [[ -f "$HERE/pii-reseed.sh" ]]; then
  step "Syncing PII gate patterns with the account registry"
  bash "$HERE/pii-reseed.sh" || warn "pii-reseed FAILED (rc=$?) — PII gate patterns may be stale; fix before the next template push"
fi
