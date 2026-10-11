#!/usr/bin/env bash
# install-pii-scan.sh — provision the local PII scanner (Microsoft Presidio +
# spaCy NER) that the outbound sync procedure depends on. Idempotent.
#
# WHY THIS IS A REQUIRED SETUP COMPONENT, not an optional extra:
# the outbound procedure is specified to scan
# the content it is about to publish for personal data. A pattern list can only
# match identifiers someone thought to enumerate; the leaks that matter are the
# ones nobody enumerated — a third party's name, a street address, a stranger's
# email quoted in a comment. Those need NER. A machine without this component
# must REFUSE to push rather than fall back to patterns-only. Hence: required.
# (Which skills call it, and how: see bootstrap/PII-SCAN-CONTRACT.md.)
#
# What it installs:
#   - a dedicated Python venv (default ~/.local/share/pii-scan-venv) holding
#     presidio-analyzer, presidio-anonymizer, a pinned spaCy, and the
#     en_core_web_lg model (~430MB; ~570MB for the whole venv). Dedicated so the
#     heavy NLP deps never pollute system Python and survive a brew upgrade.
#   - a symlink <bindir>/pii-scan -> <repo>/bootstrap/lib/pii-scan, putting it
#     on PATH. The scanner lives under bootstrap/lib/ rather than a top-level
#     bin/ because bin/ is hard-denied by the outbound sync rules (it is where
#     machine-local personal tooling lives), so a scanner shipped there could
#     never receive an update through the very gate it powers.
#
# spaCy is pinned to the range the model declares (`spacy_version >=3.8,<3.9`).
# Unpinned, a fresh install would one day pair spaCy 3.9 with a 3.8 model and
# break — fail-closed, but only on new machines, the hardest kind to diagnose.
#
# Usage:
#   install-pii-scan.sh            # install if missing, verify, no-op if healthy
#   install-pii-scan.sh --check    # verify only; never installs. 0 healthy, 2 not
#   install-pii-scan.sh --force    # rebuild the venv from scratch
#
# Exit: 0 = healthy, 2 = could not get to healthy. NEVER any other code — an
# unexpected failure is trapped and reported as 2, because a caller gating on
# `-eq 2` would otherwise read a bare `set -e` finish 1 as "not unhealthy".
#
# It ALWAYS verifies by running `pii-scan --selftest` THROUGH PATH — the same
# resolution a caller will use. Testing the repo's copy instead would pass while
# a hijacked or missing ~/.local/bin/pii-scan is what actually gets run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installed BEFORE sourcing common.sh: a partial checkout makes that source fail,
# and under `set -e` it would finish 1 — which a caller gating on `-eq 2` reads as
# "not unhealthy". Uses echo, not err(), because err() is defined by common.sh.
# Exit status is tracked with an explicit flag rather than inferred from $? in
# the trap: a failing `source` under `set -e` did not reliably surface as a
# nonzero $? there, so the script exited 0 on an incomplete checkout — reporting
# HEALTHY for a machine with no scanner. Every deliberate exit goes through
# finish(); anything else is an unexpected failure and becomes 2.
_finished=""
finish() { _finished=1; exit "$1"; }
_normalize_exit() {
  if [[ -z "$_finished" ]]; then
    echo "install-pii-scan: exited without completing — treating as NOT healthy" >&2
    exit 2
  fi
}
trap _normalize_exit EXIT

# shellcheck source=common.sh
source "$HERE/common.sh"

VENV="${PII_SCAN_VENV:-$HOME/.local/share/pii-scan-venv}"
BIN_DIR="${PII_SCAN_BIN_DIR:-$HOME/.local/bin}"
WRAPPER="$HERE/pii-scan"
LINK="$BIN_DIR/pii-scan"

SPACY_MODEL="en_core_web_lg"
SPACY_MODEL_VERSION="3.8.0"
SPACY_PIN="spacy>=3.8,<3.9"
SPACY_MODEL_URL="https://github.com/explosion/spacy-models/releases/download/${SPACY_MODEL}-${SPACY_MODEL_VERSION}/${SPACY_MODEL}-${SPACY_MODEL_VERSION}-py3-none-any.whl"

MODE="install"
case "${1:-}" in
  --check) MODE="check" ;;
  --force) MODE="force" ;;
  "")      ;;
  *)       err "unknown argument: $1"; finish 2 ;;
esac
[[ $# -le 1 ]] || { err "too many arguments (got: $*)"; finish 2; }

# Resolve pii-scan the way a caller would: through PATH, with BIN_DIR added
# since a just-created symlink will not be on the inherited PATH yet.
resolved_scanner() {
  # The INHERITED PATH, exactly as a caller has it. Prepending BIN_DIR here was
  # the bug: it made `--check` validate our link while a caller with any other
  # pii-scan earlier on PATH silently got that one instead.
  command -v pii-scan 2>/dev/null || true
}
same_file() { [[ -e "$1" && -e "$2" ]] && [[ "$1" -ef "$2" ]]; }

# Where the wrapper will look for pii-scan.py: beside its own physical location,
# after walking symlinks. Must mirror bootstrap/lib/pii-scan exactly.
wrapper_dir() {
  local self="$1" target
  while [[ -L "$self" ]]; do
    target="$(readlink "$self")"
    case "$target" in
      /*) self="$target" ;;
      *)  self="$(dirname "$self")/$target" ;;
    esac
  done
  (cd "$(dirname "$self")" && pwd)
}

# Healthy means: the scanner a CALLER will run is ours, and it passes selftest
# against the pinned model. Checking $WRAPPER instead would miss a hijack.
# Healthy means: the pii-scan a CALLER resolves is ours, and its canary passes.
# `-ef` compares the resolved inode, so relative links, multi-level links and
# symlinked parent directories all compare correctly.
healthy() {
  local found
  found="$(resolved_scanner)"
  [[ -n "$found" ]] || { err "no pii-scan on PATH"; return 1; }
  same_file "$found" "$WRAPPER" || {
    err "pii-scan on PATH is $found, not this repo's $WRAPPER"
    return 1
  }
  same_file "$found" "$LINK" || warn "pii-scan resolves via $found, not $LINK"
  # The wrapper execs the pii-scan.py sitting beside it, and derives that path
  # from $0 by walking symlinks — a HARDLINKED wrapper has nothing to walk, so
  # it would run a foreign implementation while passing the -ef check above.
  # The implementation is what actually scans, so check its identity too.
  same_file "$(wrapper_dir "$found")/pii-scan.py" "$HERE/pii-scan.py" || {
    err "the pii-scan.py beside $found is not this repo's bootstrap/lib/pii-scan.py"
    return 1
  }
  PII_SCAN_VENV="$VENV" PII_SCAN_SPACY_MODEL="$SPACY_MODEL" \
    "$found" --selftest >/dev/null 2>&1
}

if [[ "$MODE" == "check" ]]; then
  if healthy; then
    ok "pii-scan: healthy ($(resolved_scanner), venv $VENV, model $SPACY_MODEL)"
    finish 0
  fi
  err "pii-scan: NOT healthy — outbound sync must refuse to push on this machine"
  err "  repair with: $(printf '%q' "$HERE/install-pii-scan.sh")"
  finish 2
fi

[[ -x "$WRAPPER" ]] || { err "missing $WRAPPER — is this a complete checkout?"; finish 2; }

# ---------- PATH link FIRST, so `healthy` can ever be true ----------
# (This used to sit after the early "already installed" return, which meant
# install mode could never create a missing link or surface a hijacked one.)
mkdir -p "$BIN_DIR" || { err "could not create $BIN_DIR"; finish 2; }
if [[ -L "$LINK" ]]; then
  existing="$(readlink "$LINK")"
  # -ef, matching healthy(): a relative target or a symlinked parent directory
  # makes a healthy link string-compare unequal and read as a hijack.
  if ! same_file "$LINK" "$WRAPPER"; then
    if [[ "$MODE" == "force" ]]; then
      ln -sfn "$WRAPPER" "$LINK"; ok "repointed $LINK -> $WRAPPER"
    else
      err "$LINK already points at $existing, not $WRAPPER"
      err "  a caller running 'pii-scan' would get that instead of this scanner."
      err "  re-run with --force to repoint it, or remove it by hand."
      finish 2
    fi
  fi
elif [[ -e "$LINK" ]]; then
  if [[ "$MODE" == "force" ]]; then
    rm -f "$LINK" && ln -s "$WRAPPER" "$LINK" && ok "replaced $LINK -> $WRAPPER"
  else
    err "$LINK exists and is not a symlink — re-run with --force to replace it"
    finish 2
  fi
else
  ln -s "$WRAPPER" "$LINK"; ok "linked $LINK -> $WRAPPER"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH — add it to your shell profile, or the outbound skills will not find pii-scan" ;;
esac

if [[ "$MODE" == "install" ]] && healthy; then
  ok "pii-scan: already installed and passing selftest — nothing to do"
  finish 0
fi

if [[ "$MODE" == "force" && -d "$VENV" ]]; then
  info "removing existing venv at $VENV (--force)"
  rm -rf "$VENV"
fi

mkdir -p "$(dirname "$VENV")" || { err "could not create $(dirname "$VENV")"; finish 2; }

# spaCy and its thinc/blis dependencies ship as compiled wheels, and those lag
# new CPython releases — `python3` on a current macOS can easily be ahead of
# them. A venv built on such an interpreter fails deep inside pip with a
# wheel-resolution error, so the pip path picks a supported interpreter by
# version and refuses if there is none. uv sidesteps this by fetching its own.
# (The model wheel itself is py3-none-any; the bound comes from spaCy, not it.)
PY_MIN_MINOR=9
PY_MAX_MINOR=13

find_supported_python() {
  local c ver minor
  for c in python3.12 python3.11 python3.13 python3.10 python3.9 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    ver="$("$c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || continue
    [[ "${ver%%.*}" == "3" ]] || continue
    minor="${ver#*.}"
    if (( minor >= PY_MIN_MINOR && minor <= PY_MAX_MINOR )); then
      PYTHON_BIN="$(command -v "$c")"
      return 0
    fi
  done
  return 1
}

if command -v uv >/dev/null 2>&1; then
  INSTALLER="uv"
else
  INSTALLER="pip"
  if ! find_supported_python; then
    err "no Python with current spaCy wheels found (need 3.${PY_MIN_MINOR}-3.${PY_MAX_MINOR})"
    err "  easiest fix: brew install uv  (it fetches its own 3.12), then re-run"
    err "  or: brew install python@3.12"
    finish 2
  fi
  info "using $PYTHON_BIN ($("$PYTHON_BIN" -V 2>&1))"
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  info "creating pii-scan venv at $VENV (one-time, ~570MB — this takes a few minutes)"
  if [[ "$INSTALLER" == "uv" ]]; then
    uv venv "$VENV" --python 3.12 >/dev/null || { err "uv venv failed"; finish 2; }
  else
    "$PYTHON_BIN" -m venv "$VENV" || { err "venv creation failed"; finish 2; }
    [[ -x "$VENV/bin/python" ]] || ln -sf python3 "$VENV/bin/python"
  fi
fi

PY="$VENV/bin/python"
[[ -x "$PY" ]] || { err "venv creation failed — no interpreter at $PY"; finish 2; }

vpip() {
  if [[ "$INSTALLER" == "uv" ]]; then
    uv pip install --python "$PY" "$@"
  else
    "$PY" -m pip install --quiet "$@"
  fi
}

if ! "$PY" -c "import presidio_analyzer" 2>/dev/null; then
  info "installing presidio-analyzer, presidio-anonymizer, $SPACY_PIN"
  if [[ "$INSTALLER" == "pip" ]]; then
    "$PY" -m pip install --quiet --upgrade pip || { err "pip self-upgrade failed"; finish 2; }
  fi
  vpip presidio-analyzer presidio-anonymizer "$SPACY_PIN" >/dev/null \
    || { err "installing presidio/spacy failed"; finish 2; }
fi

if ! "$PY" -c "import ${SPACY_MODEL}" 2>/dev/null; then
  info "installing spaCy model ${SPACY_MODEL} ${SPACY_MODEL_VERSION} (~430MB)"
  vpip "$SPACY_MODEL_URL" >/dev/null || { err "installing $SPACY_MODEL failed"; finish 2; }
fi

if healthy; then
  ok "pii-scan installed and verified ($(resolved_scanner), model $SPACY_MODEL)"
  finish 0
fi

err "pii-scan installed but verification FAILED — treat this machine as unable to scan"
case ":$PATH:" in
  *":$BIN_DIR:"*) err "  try: $(printf '%q' "$HERE/install-pii-scan.sh") --force" ;;
  *) err "  $BIN_DIR is not on your PATH (--force will not fix that): add it to your shell profile, open a new shell, then run $(printf '%q' "$HERE/install-pii-scan.sh") --check" ;;
esac
finish 2
