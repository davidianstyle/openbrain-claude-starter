#!/usr/bin/env bash
# bootstrap/lib/smoke-test.sh
#
# Fast, side-effect-free soundness check for the bootstrap layer. Runs against a
# fresh checkout with NOTHING installed, and never touches your real $HOME.
#
# This is the pre-install counterpart to validate.sh: validate.sh checks whether
# *this machine's install* is healthy (real ~/.config/openbrain + ~/.claude.json
# state, after setup.sh has run); smoke-test.sh checks whether the *code in this
# checkout* is sound, before you install anything. Three tiers:
#
#   1. every shell script under bootstrap/ and .openbrain/ parses (bash -n)
#   2. minimal-init.sh stands up the shared layer in a throwaway $HOME —
#      dirs + .env + launchers, and is idempotent on a re-run   [if present]
#   3. the _oauth_env indirect-expansion helper behaves under set -u:
#      set var -> value, unset var -> empty (no crash)          [if present]
#
# Tiers 2 and 3 self-skip when the feature isn't in the tree yet, so the script
# is safe to run at any point in the repo's history and grows coverage as those
# land. Exits non-zero on the first hard failure — CI-friendly.
#
# Especially useful when porting changes between the claude/gemini editions: the
# bootstrap/lib layer is byte-identical across both, so a green run in each repo
# is executable proof the shared layer hasn't drifted.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIBDIR="$REPO_ROOT/bootstrap/lib"

# Self-contained output helpers. Deliberately do NOT source common.sh — tier 1
# is testing that file, and the script must run even if it fails to parse.
if [[ -t 1 ]]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_0=$'\033[0m'; else C_G=; C_R=; C_0=; fi
FAILED=0
pass() { printf '  %sok%s   %s\n'   "$C_G" "$C_0" "$*"; }
fail() { printf '  %sFAIL%s %s\n'   "$C_R" "$C_0" "$*"; FAILED=$((FAILED + 1)); }
skip() { printf '  --   %s\n' "$*"; }
sect() { printf '\n== %s ==\n' "$*"; }

# One temp root for every sandboxed tier; a single EXIT trap removes it, so the
# script never leaks a directory regardless of which tiers run or how it exits.
TMPROOT="$(mktemp -d)" || { printf 'could not create temp dir\n' >&2; exit 1; }
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { printf 'mktemp gave no dir\n' >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# 1. Parse check — every shell script must parse under bash.
# ---------------------------------------------------------------------------
sect "parse (bash -n)"
checked=0
while IFS= read -r f; do
  checked=$((checked + 1))
  if bash -n "$f" 2>/dev/null; then pass "${f#"$REPO_ROOT"/}"; else fail "${f#"$REPO_ROOT"/} (syntax)"; fi
done < <(find "$REPO_ROOT/bootstrap" "$REPO_ROOT/.openbrain" -type f -name '*.sh' 2>/dev/null | sort)
# A CI gate that checked nothing must not pass — guard against a wrong cwd /
# renamed dirs producing an empty file set.
(( checked > 0 )) || fail "no shell scripts found under bootstrap/ or .openbrain/ (wrong cwd?)"

# ---------------------------------------------------------------------------
# 2. minimal-init.sh stands up the shared layer in a sandbox $HOME.
# ---------------------------------------------------------------------------
sect "minimal-init.sh (sandbox HOME)"
# -f, not -x: we invoke it via `bash <file>`, so the exec bit is irrelevant and
# checking it would wrongly skip the tier if a checkout/CI dropped the mode.
if [[ -f "$LIBDIR/minimal-init.sh" ]]; then
  SBX="$TMPROOT/init"; mkdir -p "$SBX"
  if HOME="$SBX" bash "$LIBDIR/minimal-init.sh" >/dev/null 2>&1; then
    cfg="$SBX/.config/openbrain"
    if [[ -f "$cfg/.env" ]]; then pass ".env created from template"; else fail ".env not created"; fi
    if ls "$cfg/lib/"*.sh >/dev/null 2>&1; then pass "launcher scripts installed"; else fail "no launcher scripts copied"; fi
    # Idempotency: a marker added to .env must survive a re-run. Only meaningful
    # if the first run actually produced .env — otherwise the append would create
    # it and the re-run could pass spuriously.
    if [[ -f "$cfg/.env" ]]; then
      printf 'SMOKE_SENTINEL=1\n' >> "$cfg/.env"
      if HOME="$SBX" bash "$LIBDIR/minimal-init.sh" >/dev/null 2>&1 && grep -q SMOKE_SENTINEL "$cfg/.env"; then
        pass "idempotent (.env preserved on re-run)"
      else
        fail ".env clobbered on re-run"
      fi
    fi
  else
    fail "minimal-init.sh exited non-zero"
  fi
else
  skip "minimal-init.sh not present — skipping"
fi

# ---------------------------------------------------------------------------
# 3. _oauth_env indirect-expansion helper, exercised under set -u.
# ---------------------------------------------------------------------------
sect "_oauth_env helper (set -u)"
if grep -qE '_oauth_env[[:space:]]*\(\)' "$LIBDIR/common.sh" 2>/dev/null; then
  # Source common.sh WITHOUT set -e (avoid any source-time abort), then enable
  # the nounset guard that is the whole point of the test, then probe both a set
  # and an unset provider var. Expect "abc|" (value, then empty — no crash).
  oauth_home="$TMPROOT/oauth"; mkdir -p "$oauth_home"
  out="$(HOME="$oauth_home" bash -c '
    source "'"$LIBDIR"'/common.sh" >/dev/null 2>&1 || { printf SRCERR; exit 0; }
    set -u
    GOOGLE_OAUTH_CLIENT_ID=abc
    printf "%s|%s" "$(_oauth_env google CLIENT_ID)" "$(_oauth_env microsoft CLIENT_ID)"
  ' 2>/dev/null)"
  if [[ "$out" == "abc|" ]]; then
    pass "set->value, unset->empty under set -u"
  else
    fail "unexpected output: [$out] (expected [abc|])"
  fi
else
  skip "_oauth_env not present — skipping"
fi

# ---------------------------------------------------------------------------
sect "result"
if (( FAILED == 0 )); then
  printf '%ssmoke test passed%s\n' "$C_G" "$C_0"
  exit 0
else
  printf '%ssmoke test FAILED — %d check(s)%s\n' "$C_R" "$FAILED" "$C_0"
  exit 1
fi
