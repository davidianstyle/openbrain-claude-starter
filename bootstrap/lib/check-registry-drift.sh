#!/usr/bin/env bash
# Detect drift between the live MCP registry and what CLAUDE.md's account
# registry claims.
#
# Contract (declared, not inferred): the registry block in CLAUDE.md is the
# region between the explicit marker line
#
#     <!-- openbrain:account-registry -->
#
# and the next markdown heading (or EOF). The script locates the block by
# grepping for that marker ONLY — it never guesses section headings, numbering,
# or table style. A vault opts in by placing the marker directly above its
# configured-accounts listing (bullets or tables both parse). No marker means
# nothing is checked, and the script says so LOUDLY and exits non-clean —
# never silent-clean.
#
# The registry block is hand-curated (roles/status/sunset notes cannot be
# machine-derived), so this script does NOT rewrite CLAUDE.md. It only detects
# and reports:
#   - accounts that are live (have credentials/tokens) but absent from the block
#   - accounts the block claims whose credentials no longer exist
# Coverage: google/microsoft/slack account slugs, PLUS the asana workspaces
# (personal/work) and fathom — everything the success line reports is actually
# diffed; nothing is printed as checked that wasn't (a checker must never
# claim more scope than it verifies).
#
# Exit codes (callers in bootstrap flows guard with `|| true`, so none block):
#   0 = registry block found, matches the live registry
#   1 = drift detected (details on stdout)
#   2 = CLAUDE.md or the marker not found — NOTHING WAS CHECKED
#   3 = marker found but the block is unparseable — NOTHING WAS CHECKED
#
# Called at the end of register-mcps.sh (the chokepoint every account change
# funnels through) and runnable standalone any time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

ensure_python3
load_env

MARKER='<!-- openbrain:account-registry -->'
CLAUDE_MD="${CHECK_REGISTRY_CLAUDE_MD:-$REPO_ROOT/CLAUDE.md}"

if [[ ! -f "$CLAUDE_MD" ]]; then
  warn "CLAUDE.md not found at $CLAUDE_MD — NOTHING WAS CHECKED"
  exit 2
fi
if ! grep -qF "$MARKER" "$CLAUDE_MD"; then
  warn "registry section not found — nothing was checked."
  warn "Opt in by adding this marker line directly above the configured-accounts"
  warn "listing in CLAUDE.md:  $MARKER"
  exit 2
fi

# -----------------------------------------------------------------------------
# Discover live accounts (same sources register-mcps.sh uses)
# -----------------------------------------------------------------------------
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
if grep -qE '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE" 2>/dev/null; then
  SLACK_SLUGS_JSON="$(
    grep -E '^SLACK_TOKEN_[A-Z0-9_]+=.+' "$ENV_FILE" \
      | sed -E 's/^SLACK_TOKEN_([A-Z0-9_]+)=.*/\1/' \
      | "$PYTHON_BIN" -c 'import sys, json; print(json.dumps([l.strip().lower().replace("_","-") for l in sys.stdin if l.strip()]))'
  )"
fi

HAS_ASANA_PERSONAL=false; [[ -n "${ASANA_PAT_PERSONAL:-}" ]] && HAS_ASANA_PERSONAL=true
HAS_ASANA_WORK=false;     [[ -n "${ASANA_PAT_WORK:-}" ]]     && HAS_ASANA_WORK=true
HAS_FATHOM=false;         [[ -n "${FATHOM_API_KEY:-}" ]]     && HAS_FATHOM=true

# -----------------------------------------------------------------------------
# Diff live registry against the marked block (Python does the parse)
# -----------------------------------------------------------------------------
DRIFT_RC=0
"$PYTHON_BIN" - "$CLAUDE_MD" "$GOOGLE_SLUGS_JSON" "$MICROSOFT_SLUGS_JSON" "$SLACK_SLUGS_JSON" \
  "$HAS_ASANA_PERSONAL" "$HAS_ASANA_WORK" "$HAS_FATHOM" <<'PY' || DRIFT_RC=$?
import json, re, sys

(claude_md, google_json, microsoft_json, slack_json,
 asana_personal, asana_work, fathom) = sys.argv[1:8]
live = {
    "google":    set(json.loads(google_json)),
    "microsoft": set(json.loads(microsoft_json)),
    "slack":     set(json.loads(slack_json)),
}
has_asana_personal = asana_personal == "true"
has_asana_work     = asana_work == "true"
has_fathom         = fathom == "true"

# Explicit UTF-8: the file is hand-curated prose (arrows, em-dashes). Any read
# failure (permissions, malformed encoding) must exit as CANNOT-CHECK — an
# uncaught crash exits 1, which the wrapper would report as "drift".
try:
    text = open(claude_md, encoding="utf-8").read()
except Exception as e:
    print(f"[drift] failed to read {claude_md}: {e} — NOTHING WAS CHECKED",
          file=sys.stderr)
    sys.exit(3)

# The registry block: from the marker line to the next markdown heading or EOF.
MARKER = "<!-- openbrain:account-registry -->"
idx = text.find(MARKER)
if idx < 0:
    # The bash wrapper already grepped for the marker; belt-and-suspenders.
    print("[drift] registry marker not found — nothing was checked", file=sys.stderr)
    sys.exit(2)
block = text[idx + len(MARKER):]
nxt = re.search(r'^#{1,6}\s', block, re.M)
if nxt:
    block = block[:nxt.start()]

# Managed MCP-key service prefixes, so a token like `google_<account_slug>` or
# `mcp__slack_<slug>__*` (an MCP server key in prose) reduces to its bare
# account slug.
PREFIXES = ("google_", "gtasks_", "gmail_", "gcal_", "gmeet_", "gdrive_",
            "gslides_", "mstodo_", "slack_", "asana_")

def strip_prefix(tok):
    for p in PREFIXES:
        if tok.startswith(p):
            return tok[len(p):]
    return tok

# Claimed account slugs: every backtick token in the block, in any rendered
# form — bare dash-form (`jane-acme-com`), bare underscore-form
# (`jane_acme_com`), or an MCP server key (`mcp__google_jane_acme_com__*`) —
# service-prefix-stripped and normalized to dashes. Only slug-shaped results
# count: at least TWO separators, because every real account slug has them
# (email → local-domain-tld; Slack → sub-slack-com). One separator would
# sweep in ordinary hyphenated prose in backticks (`read-only`, `dev-mode`)
# AND the presence-service names (`asana-work`) — which belong to the
# presence diff below, not the slug diff, and would false-flag as stale here.
SLUGISH = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+){2,}$')
# Accept uppercase in the token scan and lowercase FIRST (before the mcp__ /
# prefix strips, which are written lowercase): a capitalized `Jane-Acme-Com`
# must still enter the claimed set — dropped, it would both escape the stale
# check and, in an all-capitalized block, false-trigger the exit-3
# unparseable floor.
raw_tokens = re.findall(r'`([A-Za-z0-9_*.@-]+)`', block)
claimed = set()
for tok in raw_tokens:
    tok = tok.lower()
    tok = re.sub(r'^mcp__', '', tok)
    tok = re.sub(r'__\*?$', '', tok)
    tok = strip_prefix(tok).replace("_", "-")
    if SLUGISH.match(tok):
        claimed.add(tok)

live_all = live["google"] | live["microsoft"] | live["slack"]
live_any = bool(live_all) or has_asana_personal or has_asana_work or has_fathom

# Malformed block: the marker is there but nothing parseable follows (e.g. the
# listing was deleted or restructured beyond recognition) while live accounts
# exist — ANY live account, not just slug-shaped ones: a vault with only asana
# or fathom configured must hit this floor too, or an emptied block reads as
# "in sync". Loud, non-clean.
if not raw_tokens and live_any:
    print("[drift] registry block is unparseable (no account tokens after the "
          "marker) — NOTHING WAS CHECKED. Fix the block or move the marker.")
    sys.exit(3)

# An account is documented if its slug appears in the block as a whole token —
# in dash or underscore form (covers bullets, tables, and prose) — or in the
# claimed set (covers backticked MCP keys, whose service prefix glues to the
# slug and defeats a boundary match). NOT a raw substring test: a live slug
# `acme-com` must not count as documented because `jane-acme-com` appears.
# (Consciously out of scope: a mention inside a strikethrough/retired note
# still counts as documented — the block is hand-curated and a status note IS
# documentation; and non-backticked MCP keys in prose are not matched.)
def mentioned(slug):
    if slug in claimed:
        return True
    # re.I: the block is hand-curated and may capitalize (`Jane-Acme-Com`).
    # The boundary classes stay correct under IGNORECASE (they match A-Z too).
    for form in (slug, slug.replace("-", "_")):
        if re.search(rf'(?<![a-z0-9_-]){re.escape(form)}(?![a-z0-9_-])', block, re.I):
            return True
    return False

missing = sorted(s for s in live_all if not mentioned(s))   # live but undocumented
stale   = sorted(c for c in claimed if c not in live_all)   # claimed but not live

# Asana/fathom: presence-shaped services (no account slug). Diff the block's
# claim against the live env token — these used to be parsed and then consumed
# ONLY by the success message, i.e. printed as checked without being checked.
def block_has(pattern):
    return re.search(pattern, block, re.I) is not None

PRESENCE = [
    ("asana-personal", has_asana_personal, block_has(r'asana[_\-/]personal')),
    ("asana-work",     has_asana_work,     block_has(r'asana[_\-/]work')),
    ("fathom",         has_fathom,         block_has(r'\bfathom\b')),
]
for name, is_live, is_claimed in PRESENCE:
    if is_live and not is_claimed:
        missing.append(name)
    elif is_claimed and not is_live:
        stale.append(name)

issues = 0
if missing:
    issues += len(missing)
    print("[drift] LIVE accounts missing from the CLAUDE.md registry block:")
    for s in missing:
        print(f"          + {s}  (has credentials/tokens but the block doesn't list it)")
if stale:
    issues += len(stale)
    print("[drift] CLAUDE.md registry block lists accounts with no live credentials:")
    for s in stale:
        print(f"          - {s}  (in the block but no credentials file / env token found)")

if issues:
    print(f"[drift] {issues} mismatch(es). The registry block is hand-curated — "
          "reconcile manually (roles/status/sunset notes can't be auto-derived).")
    sys.exit(1)
else:
    print("[drift] CLAUDE.md registry block matches the live registry "
          f"(google={len(live['google'])}, microsoft={len(live['microsoft'])}, "
          f"slack={len(live['slack'])}, asana_personal={has_asana_personal}, "
          f"asana_work={has_asana_work}, fathom={has_fathom}).")
    sys.exit(0)
PY

case "$DRIFT_RC" in
  0) ok "CLAUDE.md account registry in sync with the live registry" ;;
  1) warn "CLAUDE.md account registry has drifted from the live registry (see above). Detect-only — reconcile by hand." ;;
  *) warn "registry check could not run (see above) — NOTHING WAS CHECKED" ;;
esac
exit "$DRIFT_RC"
