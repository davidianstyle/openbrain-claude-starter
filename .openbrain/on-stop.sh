#!/usr/bin/env bash
# OpenBrain vault Stop hook.
# 1. Regenerate Home.md MOC index from + Spaces/*.md
# 2. Smart auto-commit + pull --rebase + push to origin (if configured)
# Fails soft: conflicts and push errors become Inbox notes, never blocks the hook.

set -uo pipefail

VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$VAULT" || exit 0

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
INBOX="$VAULT/+ Inbox"
LOG_FILE="${TMPDIR:-/tmp}/openbrain-on-stop.log"

log() { printf '[on-stop %s] %s\n' "$TS" "$*" >&2; }

# -----------------------------------------------------------------------------
# Step 1: regenerate Home.md MOC index
# -----------------------------------------------------------------------------
regen_moc_index() {
  local home="$VAULT/Home.md"
  [[ -f "$home" ]] || return 0

  local start_marker='<!-- openbrain:moc-index:start -->'
  local end_marker='<!-- openbrain:moc-index:end -->'

  grep -q "$start_marker" "$home" || return 0
  grep -q "$end_marker" "$home" || return 0

  local tmp index_tmp
  tmp="$(mktemp)"
  index_tmp="$(mktemp)"

  {
    if compgen -G "$VAULT/+ Spaces/*.md" > /dev/null; then
      find "$VAULT/+ Spaces" -maxdepth 1 -name '*.md' -type f -print0 \
        | sort -z \
        | while IFS= read -r -d '' f; do
            local base
            base="$(basename "$f" .md)"
            printf -- '- [[%s]]\n' "$base"
          done
    else
      printf '*No MOCs yet. Create your first one in `+ Spaces/` using the `MOC` template.*\n'
    fi
  } > "$index_tmp"

  awk -v start="$start_marker" -v end="$end_marker" -v idxfile="$index_tmp" '
    BEGIN { in_block = 0 }
    {
      if ($0 ~ start) {
        print
        while ((getline line < idxfile) > 0) print line
        close(idxfile)
        in_block = 1
        next
      }
      if ($0 ~ end) {
        in_block = 0
        print
        next
      }
      if (!in_block) print
    }
  ' "$home" > "$tmp" && mv "$tmp" "$home"

  rm -f "$index_tmp"
}

regen_moc_index || log "MOC index regen failed (non-fatal)"

# -----------------------------------------------------------------------------
# Step 2: smart auto-commit + push
# -----------------------------------------------------------------------------

# Determine the current branch + whether an upstream exists
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
HAS_UPSTREAM=0
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  HAS_UPSTREAM=1
fi

# Skip if working tree clean (and nothing unpushed)
if [[ -z "$(git status --porcelain)" ]]; then
  if (( HAS_UPSTREAM )) && [[ -n "$(git log @{u}..HEAD 2>/dev/null)" ]]; then
    log "clean tree, but local commits ahead of upstream — pushing"
    git push 2>&1 | tee -a "$LOG_FILE" || true
  fi
  exit 0
fi

# Pull with rebase (autostash) if we have an upstream
if (( HAS_UPSTREAM )); then
  if ! git pull --rebase --autostash 2>&1 | tee -a "$LOG_FILE"; then
    log "rebase failed, aborting"
    git rebase --abort 2>/dev/null || true
    mkdir -p "$INBOX"
    cat > "$INBOX/⚠️ Merge Conflict $TS.md" <<EOF
---
title: Merge Conflict $TS
created: $TS
tags: [needs-review, openbrain-error]
---

# Merge Conflict — $TS

The Stop hook tried to \`git pull --rebase\` and hit conflicts. The rebase was aborted; your local changes are intact but **not committed or pushed**.

## To resolve

1. Open a terminal in \`$VAULT\`
2. Run \`git status\` to see what diverged
3. Manually merge / rebase and push
4. Delete this note when done

## Log tail

\`\`\`
$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)
\`\`\`
EOF
    exit 0
  fi
fi

# Stage everything
git add -A

# Bail if nothing is actually staged after the rebase
if [[ -z "$(git diff --cached --name-only)" ]]; then
  exit 0
fi

STAT="$(git diff --cached --stat --stat-width=80 | tail -n 1 | sed 's/^ *//')"

# Count changed files by top-level folder for a terser summary
SUMMARY="$(git diff --cached --name-only | awk -F/ '
  /^\+ Inbox/     { inbox++ }
  /^\+ Spaces/    { spaces++ }
  /^\+ Atlas/     { atlas++ }
  /^\+ Sources/   { sources++ }
  /^\+ Extras/    { extras++ }
  /^\+ Archive/   { archive++ }
  /^Home\.md$/    { home++ }
  /^CLAUDE\.md$/  { claude++ }
  END {
    parts = ""
    if (inbox)   parts = parts (parts?", ":"") inbox " inbox"
    if (spaces)  parts = parts (parts?", ":"") spaces " MOC"
    if (atlas)   parts = parts (parts?", ":"") atlas " atlas"
    if (sources) parts = parts (parts?", ":"") sources " source"
    if (extras)  parts = parts (parts?", ":"") extras " template/asset"
    if (archive) parts = parts (parts?", ":"") archive " archive"
    if (home)    parts = parts (parts?", ":"") "home"
    if (claude)  parts = parts (parts?", ":"") "CLAUDE"
    print parts
  }
')"

MSG="auto: ${SUMMARY:-vault update} ($STAT)"

if ! git commit -m "$MSG" 2>&1 | tee -a "$LOG_FILE"; then
  log "commit failed (pre-commit hook rejected?)"
  exit 0
fi

if (( HAS_UPSTREAM )); then
  if ! git push 2>&1 | tee -a "$LOG_FILE"; then
    log "push failed, leaving local commit in place"
    mkdir -p "$INBOX"
    cat > "$INBOX/⚠️ Push Failed $TS.md" <<EOF
---
title: Push Failed $TS
created: $TS
tags: [needs-review, openbrain-error]
---

# Push Failed — $TS

The Stop hook committed locally but \`git push\` failed. Your work is safe in the local repo.

## To resolve

1. Open a terminal in \`$VAULT\`
2. Run \`git status\` and \`git log @{u}..HEAD\` to see pending commits
3. Investigate the push failure (network? auth? branch protection?)
4. Push manually when resolved
5. Delete this note when done

## Log tail

\`\`\`
$(tail -n 20 "$LOG_FILE" 2>/dev/null || true)
\`\`\`
EOF
    exit 0
  fi
fi

log "committed${HAS_UPSTREAM:+ + pushed}: $MSG"
exit 0
