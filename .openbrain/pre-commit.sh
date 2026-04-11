#!/usr/bin/env bash
# OpenBrain vault pre-commit hook (warn-only).
# - Flags notes missing required frontmatter fields
# - Flags broken [[wikilinks]] pointing at non-existent notes
# Always exits 0 — warnings only, never blocks a commit.

set -uo pipefail

VAULT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$VAULT" || exit 0

WARN=0
warn() { printf '\033[33m⚠ pre-commit: %s\033[0m\n' "$*" >&2; WARN=$((WARN+1)); }

# Only look at staged .md files under the vault (excluding templates)
STAGED="$(git diff --cached --name-only --diff-filter=AM | grep -E '\.md$' | grep -v '^\+ Extras/Templates/' || true)"
[[ -z "$STAGED" ]] && exit 0

# Build set of existing note basenames for wikilink check
ALL_NOTES="$(find "$VAULT" -type f -name '*.md' \
  -not -path '*/.git/*' \
  -not -path '*/.obsidian/*' \
  -not -path '*/.trash/*' \
  -exec basename {} .md \; 2>/dev/null | sort -u)"

while IFS= read -r file; do
  [[ -f "$file" ]] || continue

  # --- Frontmatter presence ---
  if ! head -n 1 "$file" | grep -q '^---$'; then
    warn "$file: missing frontmatter"
    continue
  fi

  FM="$(awk '/^---$/{c++; next} c==1{print} c==2{exit}' "$file")"

  if ! grep -qE '^(title|date):' <<<"$FM"; then
    warn "$file: frontmatter missing 'title' or 'date'"
  fi

  if grep -q '#asana/' "$file" || grep -qE '^tags:.*task' <<<"$FM"; then
    if ! grep -qE '^asana_workspace:' <<<"$FM"; then
      warn "$file: task/asana note missing 'asana_workspace' in frontmatter"
    fi
  fi

  # --- Broken wikilinks ---
  LINKS="$(grep -oE '\[\[[^]]+\]\]' "$file" | sed -E 's/^\[\[([^|#]+).*\]\]$/\1/' | sort -u || true)"
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    base="${link##*/}"
    if ! grep -qxF "$base" <<<"$ALL_NOTES"; then
      warn "$file: broken wikilink [[${link}]]"
    fi
  done <<<"$LINKS"

done <<<"$STAGED"

if (( WARN > 0 )); then
  printf '\033[33m%d warning(s) — commit proceeding anyway (warn-only mode)\033[0m\n' "$WARN" >&2
fi

exit 0
