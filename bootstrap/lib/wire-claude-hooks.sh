#!/usr/bin/env bash
# Wire OpenBrain's SessionStart/Stop hooks into .claude/settings.json — the
# single source of truth for that wiring (setup.sh calls this at bootstrap; the
# pull's runtime-reconcile calls it when a hook-invocation change lands).
#
# SELF-RESOLVING PATH (candidate D). The canonical command is
#   "$CLAUDE_PROJECT_DIR"/.openbrain/<script>
# a documented Claude Code path placeholder that resolves to the project root at
# hook-fire time. The hooks live in the vault's OWN .claude/settings.json, so
# when the vault moves, settings.json moves with it and the placeholder tracks
# it — there is NO absolute path to go stale, EVER.
#
# INFERENCE-FREE. There is NO path extraction, NO parsing of an existing command,
# NO auto-rewrite anywhere in this script. The wirer does exactly three things:
#   - ADD the canonical placeholder entry when an event has no openbrain hook;
#   - NO-OP when the existing openbrain command already carries the canonical
#     placeholder at shell top level (it is self-resolving, never stale);
#   - REFUSE (loud, exit 4) for any other existing openbrain command — printing
#     the exact one-time manual edit. A legacy absolute-path entry (e.g. from a
#     pre-D install) is NOT rewritten; the human converts it once by hand. This
#     is deterministic end-to-end: the only remaining "decision" is a byte-exact
#     match against a KNOWN string (canon_span), never a guess about an unknown
#     one.
#   - plus: collapse duplicate openbrain entries for an event to one (dedup),
#     and never touch foreign hooks or other events.
# An openbrain entry is identified by its command containing the script-path
# suffix `/.openbrain/<script>` — robust to env prepends and wrappers.
#
# The placeholder is SHELL-FORM and DOUBLE-QUOTED so `$` expands
# ("$CLAUDE_PROJECT_DIR" → the resolved root; "$CLAUDE_PROJECT_DIR"/.openbrain/…
# concatenates the quoted expansion with the literal suffix into one word, so a
# project root containing spaces still resolves correctly). Exec-form args are
# NOT placeholder-substituted by Claude Code, so exec form is not used for the
# token; shell form works via the exported CLAUDE_PROJECT_DIR env var.
#
# MERGE-SAFE by design. settings.json is gitignored and may carry user edits:
# extra hooks (PreToolUse, …), an env prepend on the command
# (OPENBRAIN_AUTOPUSH=0 …), a wrapper (bash "…"), a customized timeout or
# statusMessage. Foreign hooks and other events are never touched; a user's
# wrapper/env-prepend around the placeholder is preserved (it is not the
# openbrain command's canonical form we write on CREATE, but on an existing
# entry we only ever NO-OP or REFUSE — we never strip it).
#
# OUTCOMES (never-silent-clean). For an event with NO openbrain entry: ADD. For
# a DETECTED owned entry: NO-OP or REFUSE.
#   ADD — the event has no openbrain entry at all: append the canonical
#       placeholder entry.
#   NO-OP — the existing command carries the canonical placeholder span at a
#       token boundary AND at shell top level: a self-resolving path is never
#       stale, so nothing to do. Top level matters — a placeholder inside
#       top-level single quotes does not expand (a dead hook) and is refused,
#       not no-op'd. LIMITATION (accepted, inference-free tradeoff): the check
#       confirms the placeholder is a top-level command/arg TOKEN, not that it
#       is the program actually executed; a deliberately-mangled command that
#       merely CONTAINS the placeholder at top level (a commented-out `#…`, an
#       `echo …`) reads as no-op. Verifying command position would require the
#       env-prepend/wrapper parsing this design deliberately dropped.
#   REFUSE — anything else (a legacy absolute path, a wrapper around one, an
#       'args'/exec-form entry, a non-canonical self-resolving form, the suffix
#       appearing more than once, multiple DIFFERING openbrain entries, an
#       exotic shape): print the exact manual fix, leave that entry semantically
#       untouched (byte formatting may still change if ANOTHER event's write
#       reserializes the file), do NOT append a duplicate canonical entry, do NOT
#       dedup that event (a refused event is entirely hands-off), and exit 4
#       after processing the other events (partial progress is fine; silent skip
#       is not).
#
# G4 — no-semantic-change ⇒ no settings.json write. The runtime reconciler
# detects hook drift by running this wirer on a COPY of settings.json and
# byte-comparing; an unconditional reserialize would read as drift on every run.
# A placeholder-form entry (a) is "current" and never re-serialized, so a
# converged install reconciles clean forever.
#
# Atomic + validated writes: a crash or malformed merge can never leave an
# unparseable settings.json that bricks Claude Code.
#
# Exit codes: 0 = converged (incl. no-op); 4 = one or more refusals (other
# events still processed and written); anything else = crash. Callers must
# surface a nonzero rc loudly (setup.sh and reconcile-runtime.sh both do).
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
import json, os, shlex, sys
from pathlib import Path

# resolve() so a symlinked settings.json (dotfiles managers) keeps its link:
# the temp-sibling + os.replace lands on the TARGET, not over the symlink.
# Unconditional (non-strict) resolve: a DANGLING symlink must also resolve to
# its target — an exists() gate would leave the link itself as the write
# target and os.replace would destroy it.
settings_path = Path(sys.argv[1]).resolve()

# The self-resolving placeholder token. Double-quoted so the shell expands it;
# see the header for why shell-form (not exec-form) and why double quotes.
PLACEHOLDER = '"$CLAUDE_PROJECT_DIR"'

# Canonical openbrain hooks. timeout/statusMessage are used ONLY when CREATING a
# missing entry — never forced onto an existing one (that would clobber user
# customizations). Keep these equal to what setup.sh historically generated so
# factoring this out is behavior-neutral at first bootstrap.
CANON = {
    "SessionStart": {"script": ".openbrain/on-start.sh", "timeout": 30,  "statusMessage": "OpenBrain: pulling latest"},
    "Stop":         {"script": ".openbrain/on-stop.sh",  "timeout": 120, "statusMessage": "OpenBrain: syncing to git"},
}

# Load existing (tolerate absent/empty/corrupt → start clean, but back up
# rather than silently discard). "Corrupt" covers BOTH unparseable text AND
# valid JSON whose root is not an object (e.g. a top-level array) — either way
# we are about to regenerate a hooks-only object, so the prior content must be
# preserved to disk first, not dropped.
data = {}
if settings_path.exists():
    # utf-8-sig: tolerate a leading BOM (some editors add one) rather than
    # treating an otherwise-valid config as "unparseable" and regenerating it.
    raw = settings_path.read_text(encoding="utf-8-sig")
    if raw.strip():
        bad = None
        parsed = None
        try:
            parsed = json.loads(raw)
        except Exception as e:
            bad = f"unparseable JSON ({e})"
        else:
            if not isinstance(parsed, dict):
                bad = f"valid JSON but its root is not an object (top-level {type(parsed).__name__})"
        if bad is not None:
            bak = settings_path.with_name(settings_path.name + ".corrupt-backup")
            bak.write_text(raw, encoding="utf-8")
            sys.stderr.write(f"[wire-claude-hooks] existing settings.json was {bad}; "
                             f"backed up to {bak}, regenerating hooks block\n")
            data = {}
        else:
            data = parsed

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    # A malformed .hooks is a determinate refusal (needs a manual fix), not a
    # crash — exit 4 so callers (reconcile-runtime) classify it as such, not as
    # "drift state unknown".
    sys.stderr.write(f"[wire-claude-hooks] REFUSED: .hooks in {settings_path} is not an object "
                     f"(found {type(hooks).__name__}); refusing to edit. Fix it to an object "
                     f"(e.g. {{}}) and re-run.\n")
    sys.exit(4)

def owns(command, suffix):
    """True iff `command` invokes an openbrain script: the suffix appears ending
    at a token boundary. A plain `suffix in command` also matches a DIFFERENT
    script whose name merely starts with ours ('/.openbrain/on-start.sh-local'),
    which would then be wrongly deduped/refused — require the suffix to end at a
    boundary (end-of-string / space / quote / ';' / '&' / '|' / ')')."""
    i = command.find(suffix)
    while i != -1:
        j = i + len(suffix)
        if j == len(command) or command[j] in " \t'\";&|)":
            return True
        i = command.find(suffix, i + 1)
    return False

def valid_occurrences(cmd, span):
    """Positions where the KNOWN canonical span occurs in cmd at a shell token
    boundary — used ONLY for no-op detection. Preceded by start-of-string /
    space / tab / quote / '(' (NOT '=': a span glued after '=' is an assignment
    RHS — `FOO=<span>` executes nothing, so it must not read as a live no-op),
    and followed by end-of-string / space / tab / quote / ';' / '&' / '|' / ')'.
    A raw substring match is not enough (the placeholder text could appear
    embedded in a larger token)."""
    out = []
    i = cmd.find(span)
    while i != -1:
        j = i + len(span)
        if (i == 0 or cmd[i - 1] in " \t'\"(") and (j == len(cmd) or cmd[j] in " \t'\";&|)"):
            out.append(i)
        i = cmd.find(span, i + 1)
    return out

def top_level(cmd, at):
    """True iff position `at` in cmd is at shell top level (not inside any
    quoted region) — i.e. the prefix cmd[:at] has balanced quoting. The
    placeholder only expands when it is shell-active: a canonical span sitting
    inside TOP-LEVEL single quotes ('"$CLAUDE_PROJECT_DIR"/…') is a dead hook,
    so it must NOT count as the no-op case."""
    try:
        shlex.split(cmd[:at])
        return True
    except ValueError:
        return False

changed = []   # settings.json semantic changes (drive the settings write)
refusals = []  # loud-refusal messages; nonzero exit after all events process

def refuse(event, cur, why, canon_span):
    bn = canon_span.rsplit("/", 1)[-1]
    refusals.append(
        f"[wire-claude-hooks] REFUSED: the {event} openbrain hook is not in the\n"
        f"  self-resolving placeholder form, and this wirer never rewrites an existing\n"
        f"  command automatically.\n"
        f"  command: {cur}\n"
        f"  reason: {why}\n"
        f"  Fix: edit {settings_path} so the {event} command uses the placeholder. Keep\n"
        f"  any wrapper or env-prepend you have — replace ONLY the absolute script path\n"
        f"  with:\n"
        f"      {canon_span}\n"
        f'  e.g. `bash "/Users/…/.openbrain/{bn}"` becomes `bash {canon_span}`.\n'
        f"  The vault's own .claude/settings.json travels with the vault, so\n"
        f'  "$CLAUDE_PROJECT_DIR" always resolves to the vault root — no absolute path\n'
        f"  needed. Then re-run (bootstrap/setup.sh, or .openbrain/lib/reconcile-runtime.sh --apply).")

for event, spec in CANON.items():
    basename = spec["script"].split("/")[-1]
    suffix = "/.openbrain/" + basename
    canon_span = PLACEHOLDER + suffix          # "$CLAUDE_PROJECT_DIR"/.openbrain/<script>
    groups = hooks.get(event)
    if groups is None:
        groups = []
        hooks[event] = groups
    elif not isinstance(groups, list):
        # A non-list event value (a dict/string hand-edit) may carry hooks; do
        # NOT silently reset it to [] and append — that discards its content.
        # Refuse and leave it untouched.
        refusals.append(
            f"[wire-claude-hooks] REFUSED: the {event} value in {settings_path} is not a list of "
            f"hook groups (found {type(groups).__name__}); refusing to edit so its content is not "
            f"discarded. Fix it to an array of hook groups and re-run.")
        continue

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
                if owns(h["command"], suffix):
                    owned.append((g, h))

    if not owned:
        # (c) ADD: no openbrain entry for this event → append the canonical
        # placeholder one.
        groups.append({"hooks": [{
            "type": "command",
            "command": canon_span,
            "timeout": spec["timeout"],
            "statusMessage": spec["statusMessage"],
        }]})
        changed.append(f"{event}: added")
        continue

    # Keep the first owned entry; resolve it to NO-OP or REFUSE.
    keep_hook = owned[0][1]
    cur = keep_hook["command"]

    # An `args` key means exec form, where the `command` string is NOT
    # shell-expanded (so a "$CLAUDE_PROJECT_DIR" command would be a dead hook).
    # We only ever manage shell-form hooks; refuse. The only convergent fix is
    # shell form — do NOT suggest keeping `args`, which would just refuse again.
    if "args" in keep_hook:
        refuse(event, cur,
               "the entry has an 'args' key (exec form); this wirer only manages shell-form "
               "hooks. Rewrite as shell form — drop the 'args' key and put the command in the "
               "'command' string", canon_span)
        continue

    # The script-path suffix must occur exactly once. More than once (two owned
    # paths, or the path echoed in an argument) is ambiguous — even a command
    # that carries the placeholder plus a second, stale absolute path must not
    # be blessed as a no-op.
    if cur.count(suffix) > 1:
        refuse(event, cur,
               f"the script-path suffix {suffix!r} appears more than once; the command is "
               f"ambiguous (it may carry a stale second path alongside the placeholder)", canon_span)
        continue

    ph_occ = valid_occurrences(cur, canon_span)
    if ph_occ and any(top_level(cur, i) for i in ph_occ):
        # (a) NO-OP: already self-resolving placeholder form at shell top level.
        # Fall through to dedup only; no settings write for this entry (G4).
        pass
    else:
        # (b) REFUSE: any other existing openbrain command. No inference, no
        # rewrite — the human converts it once, guided by the printed fix.
        refuse(event, cur,
               "the command is not the self-resolving placeholder form (it looks like a "
               "legacy absolute path, a wrapper around one, or another custom shape)", canon_span)
        continue

    if len(owned) > 1:
        # Dedup collapses ACCIDENTAL duplicates — byte-identical commands. If the
        # extra owned entries DIFFER from the kept one, they are not duplicates
        # but distinct configs (e.g. a plain placeholder alongside an
        # `OPENBRAIN_AUTOPUSH=0 …` customization). Dropping one would silently
        # discard a customization (re-enabling autopush against the user's
        # intent), so refuse and let the human choose. Only identical extras are
        # removed.
        if any(h["command"] != cur for _g, h in owned[1:]):
            refuse(event, cur,
                   "there are multiple DIFFERENT openbrain entries for this event; the wirer will "
                   "not choose between them or drop a customization — remove the extra entries by "
                   "hand, keeping the one you want", canon_span)
            continue
        # Remove the identical duplicate inner-hooks, then drop any group WE just
        # left empty. Only groups in the owned set are eligible for removal — a
        # foreign group the user left with an empty "hooks" list ({"matcher":…,
        # "hooks": []}) must survive (dropping it would violate "never touch
        # foreign hooks").
        owned_group_ids = {id(g) for g, _h in owned}
        for g, h in owned[1:]:
            if h in g.get("hooks", []):
                g["hooks"].remove(h)
        hooks[event] = [g for g in groups
                        if not (isinstance(g, dict) and g.get("hooks") == []
                                and id(g) in owned_group_ids)]
        changed.append(f"{event}: deduped {len(owned)-1} identical")

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
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, settings_path)

if changed:
    print("[wire-claude-hooks] " + "; ".join(changed))
elif not refusals:
    # Only claim "no change" when nothing changed AND nothing refused — a
    # pure-refuse run must not print a converged-looking stdout line (the
    # REFUSED detail goes to stderr and rc is 4).
    print("[wire-claude-hooks] hooks already correct (no change)")

if refusals:
    for r in refusals:
        sys.stderr.write(r + "\n")
    sys.exit(4)
PY
