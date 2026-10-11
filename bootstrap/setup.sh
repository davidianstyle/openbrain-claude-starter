#!/usr/bin/env bash
# OpenBrain setup wizard — run this ONCE after `git clone` to bootstrap your vault.
#
# What it does:
#   1. Checks prereqs (python3, node, git, optionally gh/claude CLI)
#   2. Asks for your name and writing-voice blurb
#   3. Substitutes those into CLAUDE.md and generates Home.md
#   4. Copies .openbrain/lib/*.sh → ~/.config/openbrain/lib/ (install-time paths)
#   5. Creates ~/.config/openbrain/.env from .openbrain/env.example
#   6. Loops through each supported service and asks "add an account? [y/N]"
#   7. Runs register-mcps.sh to wire ~/.claude.json
#   8. Runs validate.sh to sanity-check the install
#
# Re-runnable: the script is defensive. Re-running won't clobber existing
# secrets — you'll get prompts only for missing or explicitly re-entered values.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

banner() {
  printf '\n%s%s════════════════════════════════════════════════════════════%s\n' "$_C_BOLD" "$_C_BLUE" "$_C_RESET"
  printf '%s%s  %s%s\n' "$_C_BOLD" "$_C_BLUE" "$*" "$_C_RESET"
  printf '%s%s════════════════════════════════════════════════════════════%s\n\n' "$_C_BOLD" "$_C_BLUE" "$_C_RESET"
}

banner "OpenBrain — personal AI Chief of Staff setup"

cat <<EOF
This wizard will:
  • Customize CLAUDE.md with your name + writing voice
  • Create ~/.config/openbrain/ and install launcher scripts
  • Walk you through OAuth for every service you want to wire up
  • Register MCP servers with Claude Code

It assumes this repo is already cloned to the directory you want to use as
your vault. Current repo path: $_C_BOLD$REPO_ROOT$_C_RESET

EOF

if ! yes_no "Continue?" y; then
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 1: prereqs (auto-installs missing dependencies)
# -----------------------------------------------------------------------------
step "1/10 · Checking & installing prerequisites"
ensure_prereqs

# If asdf is active, ensure .tool-versions exists so node/python resolve in this dir
if command -v asdf >/dev/null 2>&1 && [[ ! -f "$REPO_ROOT/.tool-versions" ]]; then
  NODE_VER="$(node --version 2>/dev/null | sed 's/^v//')"
  if [[ -n "$NODE_VER" ]]; then
    echo "nodejs $NODE_VER" > "$REPO_ROOT/.tool-versions"
    ok "created .tool-versions (nodejs $NODE_VER) for asdf compatibility"
  fi
fi

# -----------------------------------------------------------------------------
# Step 2: PII scanner (REQUIRED — the outbound sync gate depends on it)
# -----------------------------------------------------------------------------
step "2/10 · Installing the PII scanner"
cat <<'EOF'
The push sync skill scans everything it publishes
for personal data using a local NER model (Microsoft Presidio + spaCy).
The text being scanned never leaves your machine. A pattern list only catches
identifiers someone enumerated in advance; the leaks that matter are the ones
nobody thought of. Without this scanner the push skill refuses to run rather than
fall back to patterns alone.

First install downloads ~430MB of model (~570MB venv) and takes a few minutes.
Later runs are a no-op.
EOF
if ! "$HERE/lib/install-pii-scan.sh"; then
  warn "PII scanner not installed — pushing to the template"
  warn "will refuse until you run:"
  warn "  ./bootstrap/lib/install-pii-scan.sh"
fi

# -----------------------------------------------------------------------------
# Step 3: user profile
# -----------------------------------------------------------------------------
step "3/10 · Tell me about yourself"

USER_NAME="$(prompt 'Your full name' "${USER:-}")"
USER_VOICE="$(prompt 'Describe your writing voice in a sentence' 'direct, terse, no filler')"

# -----------------------------------------------------------------------------
# Step 4: customize CLAUDE.md
# -----------------------------------------------------------------------------
step "4/10 · Customizing CLAUDE.md"

BOOTSTRAP_DATE="$(date +%Y-%m-%d)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

"$PYTHON_BIN" - "$CLAUDE_MD" "$USER_NAME" "$USER_VOICE" "$BOOTSTRAP_DATE" <<'PY'
import sys
path, name, voice, date = sys.argv[1:]
content = open(path).read()
content = (content
    .replace("{{USER_NAME}}", name)
    .replace("{{USER_VOICE}}", voice)
    .replace("{{BOOTSTRAP_DATE}}", date)
    # Placeholder blocks get cleared to a "none configured" stub; the tables
    # get populated fully by a later pass (after accounts are added).
    .replace("{{ASANA_ROUTING_TABLE}}",  "_No Asana workspaces configured yet. Run `./bootstrap/lib/add-asana.sh personal|work` to add one._")
    .replace("{{GOOGLE_ACCOUNTS_TABLE}}", "_No Google accounts configured yet. Run `./bootstrap/lib/add-google-account.sh <email>` to add one._")
    .replace("{{SLACK_WORKSPACES_TABLE}}", "_No Slack workspaces configured yet. Run `./bootstrap/lib/add-slack-workspace.sh <subdomain>` to add one._")
    # §11's registry lists WHICH accounts are configured; §5's routing table
    # covers HOW Asana notes route. Both name the workspaces, so both get a
    # stub — the registry one is what check-registry-drift.sh diffs.
    .replace("{{ASANA_WORKSPACES_TABLE}}", "_No Asana workspaces configured yet. Run `./bootstrap/lib/add-asana.sh personal|work` to add one._")
    .replace("{{FATHOM_TABLE}}", "_Fathom not configured. Run `./bootstrap/lib/add-fathom.sh` to add it._")
)
open(path, "w").write(content)
PY
ok "CLAUDE.md customized"

# Generate Home.md if missing
if [[ ! -f "$REPO_ROOT/Home.md" ]]; then
  cat >"$REPO_ROOT/Home.md" <<EOF
---
title: Home
tags: [moc]
created: $BOOTSTRAP_DATE
---

# ${USER_NAME}'s OpenBrain

The front door. Edit the MOC index below as you add new Maps of Content.

## Top MOCs

<!-- openbrain:moc-index:start -->
<!-- openbrain:moc-index:end -->

## Quick access

- [[+ Inbox]] — capture first, triage later
- [[+ Atlas/Daily]] — daily notes
- [[+ Sources]] — literature / references
- [[+ Extras/Templates]] — note templates

## How this vault works

- **Capture first, organize later.** Everything starts in \`+ Inbox/\`.
- **Atomic notes.** One idea per note.
- **Links over folders.** Structure comes from \`[[wikilinks]]\` and MOCs.
- See [[CLAUDE]] for the full operating manual.
EOF
  ok "Home.md created"
fi

# -----------------------------------------------------------------------------
# Step 5: install config dir + env
# -----------------------------------------------------------------------------
# The shared-layer dir setup + launcher install lives in lib/minimal-init.sh
# so external consumers can re-use it without inheriting the rest of this
# wizard. Inlined logic was equivalent; see commit history.
step "5/10 · Installing ~/.config/openbrain/"
"$HERE/lib/minimal-init.sh"

# -----------------------------------------------------------------------------
# Step 6: wire up services
# -----------------------------------------------------------------------------
step "6/10 · Wiring up services"

# Google — optional but recommended
if yes_no "Wire up Google accounts (Gmail + Calendar + Meet + Drive)?" y; then
  "$HERE/lib/setup-google-oauth.sh"
  while true; do
    email="$(prompt 'Google account email to add (blank to finish)')"
    [[ -z "$email" ]] && break
    "$HERE/lib/add-google-account.sh" "$email" || warn "failed to add $email — continuing"
  done
fi

# Slack
if yes_no "Wire up Slack workspaces?" y; then
  while true; do
    sub="$(prompt 'Slack workspace subdomain (e.g. acme → acme.slack.com, blank to finish)')"
    [[ -z "$sub" ]] && break
    "$HERE/lib/add-slack-workspace.sh" "$sub" || warn "failed to add $sub — continuing"
  done
fi

# Asana
if yes_no "Wire up Asana (personal)?" y; then
  "$HERE/lib/add-asana.sh" personal || warn "failed to add personal Asana"
fi
if yes_no "Wire up Asana (work)?" y; then
  "$HERE/lib/add-asana.sh" work || warn "failed to add work Asana"
fi

# Fathom
if yes_no "Wire up Fathom?" y; then
  "$HERE/lib/add-fathom.sh" || warn "failed to add Fathom"
fi

# -----------------------------------------------------------------------------
# Step 7: register MCPs in ~/.claude.json
# -----------------------------------------------------------------------------
step "7/10 · Registering MCPs with Claude Code"
"$HERE/lib/register-mcps.sh"

# -----------------------------------------------------------------------------
# Step 8: git hook
# -----------------------------------------------------------------------------
step "8/10 · Git hooks"
if [[ -d "$REPO_ROOT/.git" ]]; then
  HOOK="$REPO_ROOT/.git/hooks/pre-commit"
  if [[ ! -e "$HOOK" ]] || ! cmp -s "$REPO_ROOT/.openbrain/pre-commit.sh" "$HOOK"; then
    ln -sf "$REPO_ROOT/.openbrain/pre-commit.sh" "$HOOK"
    chmod +x "$REPO_ROOT/.openbrain/pre-commit.sh"
    ok "pre-commit hook linked"
  else
    ok "pre-commit hook already linked"
  fi
  PUSH_HOOK="$REPO_ROOT/.git/hooks/pre-push"
  if [[ ! -e "$PUSH_HOOK" ]] || ! cmp -s "$REPO_ROOT/.openbrain/pre-push.sh" "$PUSH_HOOK"; then
    ln -sf "$REPO_ROOT/.openbrain/pre-push.sh" "$PUSH_HOOK"
    chmod +x "$REPO_ROOT/.openbrain/pre-push.sh"
    ok "pre-push guardrail linked"
  else
    ok "pre-push guardrail already linked"
  fi
else
  warn "not a git repo — skipping git hooks. Run 'git init' then re-run this script."
fi

# The pull skill's baseline: /pull-openbrain-template starts only from a declared `upstream` row in
# .openbrain/local/taken.tsv (per machine, gitignored). Setup records the last template commit this vault
# carries — `git merge-base HEAD <template>/main`, against the same source pull uses: the template clone at
# OPENBRAIN_TEMPLATE_DIR (default ~/openbrain-claude-starter), its `upstream` remote, else `origin`, fetched first.
# No template clone, or no shared history (a zip or "Use this template" install): warn, no row — the pull then asks.
# Every git failure is CANNOT-CHECK: warned, no row, never a guess. Never overwrites a declared row; re-runs are a no-op.
# --- setup: upstream-baseline ---
BASELINE_MARK="$REPO_ROOT/.openbrain/local/taken.tsv"
BL_NOROW="no upstream baseline recorded; /pull-openbrain-template will ask for one"
if [[ ! -d "$REPO_ROOT/.git" ]]; then
  warn "not a git repo — $BL_NOROW"
else
  brc=0; [[ ! -f "$BASELINE_MARK" ]] || LC_ALL=C awk -F'\t' '$1=="upstream" {f=1} END {exit !f}' "$BASELINE_MARK" || brc=$?
  BL_T="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
  if [[ -f "$BASELINE_MARK" && "$brc" -eq 0 ]]; then
    ok "upstream baseline already declared in $BASELINE_MARK"
  elif [[ -f "$BASELINE_MARK" && "$brc" -ne 1 ]]; then
    warn "CANNOT-CHECK — could not read $BASELINE_MARK (awk exit $brc) — $BL_NOROW"
  elif ! BL_HEAD="$(git -C "$REPO_ROOT" rev-parse -q --verify 'HEAD^{commit}')"; then
    warn "HEAD has no commit — $BL_NOROW"
  elif [[ ! -d "$BL_T/.git" ]]; then
    warn "no template clone at $BL_T (set OPENBRAIN_TEMPLATE_DIR) — $BL_NOROW"
  elif ! BL_REMS="$(git -C "$BL_T" remote)"; then
    warn "CANNOT-CHECK — git remote failed in $BL_T — $BL_NOROW"
  else
    BL_R=""; printf '%s\n' "$BL_REMS" | LC_ALL=C command grep -qx origin && BL_R=origin
    printf '%s\n' "$BL_REMS" | LC_ALL=C command grep -qx upstream && BL_R=upstream
    if [[ -z "$BL_R" ]]; then
      warn "CANNOT-CHECK — the template clone $BL_T has neither an 'upstream' nor an 'origin' remote — $BL_NOROW"
    elif ! GIT_TERMINAL_PROMPT=0 git -C "$BL_T" fetch -q "$BL_R"; then
      warn "CANNOT-CHECK — git fetch $BL_R failed in $BL_T (a stale template would give a wrong baseline) — $BL_NOROW"
    elif ! BL_TIP="$(git -C "$BL_T" rev-parse -q --verify "refs/remotes/$BL_R/main^{commit}")"; then
      warn "CANNOT-CHECK — refs/remotes/$BL_R/main does not resolve in $BL_T — $BL_NOROW"
    elif ! git -C "$REPO_ROOT" fetch -q "$BL_T" "refs/remotes/$BL_R/main"; then
      warn "CANNOT-CHECK — could not fetch the template's $BL_R/main into this vault for the merge-base — $BL_NOROW"
    else
      mbrc=0; BL_SHA="$(git -C "$REPO_ROOT" merge-base "$BL_HEAD" "$BL_TIP")" || mbrc=$?
      if [[ "$mbrc" -eq 1 ]]; then
        warn "this vault shares no history with the template ($BL_T, $BL_R/main) — no shared history (a zip or 'Use this template' install) — $BL_NOROW"
      elif [[ "$mbrc" -ne 0 || -z "$BL_SHA" ]]; then
        warn "CANNOT-CHECK — git merge-base failed (exit $mbrc) — $BL_NOROW"
      else
        mkdir -p "$REPO_ROOT/.openbrain/local" \
          && printf 'upstream\t%s\t%s\n' "$BL_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BASELINE_MARK" \
          && ok "upstream baseline recorded: $BL_SHA (git merge-base HEAD $BL_R/main of $BL_T) in $BASELINE_MARK" \
          || warn "CANNOT-CHECK — could not write $BASELINE_MARK — $BL_NOROW"
      fi
    fi
  fi
fi
# --- end setup: upstream-baseline ---

# -----------------------------------------------------------------------------
# Step 9: auto-commit/auto-pull hooks (opt-in)
# -----------------------------------------------------------------------------
step "9/10 · Auto git sync hooks"
cat <<EOF
OpenBrain can auto-commit and push your vault when Claude Code stops, and
auto-pull when it starts. This keeps your vault in sync across devices
without manual git commands.

  • SessionStart hook — fast-forward-only pull (fail-soft; never rebases)
  • Stop hook — regenerate Home.md MOC index, auto-commit, push

EOF
if yes_no "Enable auto git sync hooks?" n; then
  # Ensure a git remote is configured for push/pull to work
  if ! git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    cat <<EOF

Auto sync needs a git remote to push to. Let's set one up.

You can create a new private repo on GitHub, or use an existing one.

EOF
    if command -v gh >/dev/null 2>&1; then
      REPO_NAME="$(prompt 'GitHub repo name (e.g. my-brain)' 'my-brain')"
      info "Creating private repo and pushing..."
      gh repo create "$REPO_NAME" --private --source="$REPO_ROOT" --push 2>&1 && ok "remote created: $REPO_NAME" \
        || warn "repo creation failed — you can set up a remote manually later"
    else
      REMOTE_URL="$(prompt 'Git remote URL (e.g. git@github.com:you/my-brain.git, blank to skip)')"
      if [[ -n "$REMOTE_URL" ]]; then
        git -C "$REPO_ROOT" remote add origin "$REMOTE_URL" 2>/dev/null \
          || git -C "$REPO_ROOT" remote set-url origin "$REMOTE_URL"
        git -C "$REPO_ROOT" push -u origin main 2>&1 && ok "pushed to $REMOTE_URL" \
          || warn "push failed — check your remote URL and credentials"
      else
        warn "no remote configured — auto sync hooks will commit locally but won't push"
      fi
    fi
  else
    ok "git remote already configured"
  fi

  # Wire the auto-sync hooks via the shared, merge-safe wirer — the single
  # source of truth for this wiring (the pull's runtime-reconcile calls the same
  # script). On a fresh install it creates the canonical entries (self-resolving
  # "$CLAUDE_PROJECT_DIR" path); on a re-run it no-ops if the entry is already
  # that placeholder, and REFUSES (printing the exact one-time manual fix) for
  # any other existing command — it never auto-rewrites (inference-free).
  # A nonzero rc here is a REFUSAL (exit 4: an existing hook entry the wirer
  # can't safely repair — the wirer already printed the exact manual fix) or a
  # crash. Either way, halt setup loudly and name what happened: under bare
  # `set -e` the abort would be silent after the wirer's own message, and an
  # aborted setup is easy to misread as a completed one.
  if ! bash "$REPO_ROOT/bootstrap/lib/wire-claude-hooks.sh" "$REPO_ROOT"; then
    warn "hook wiring FAILED or was refused — read the message above, apply the"
    warn "fix it names, then re-run setup. Stopping here (setup is NOT complete)."
    exit 1
  fi
  ok "auto git sync hooks enabled in .claude/settings.json"
else
  ok "skipped — you can enable them later by re-running setup or editing .claude/settings.json"
fi

# -----------------------------------------------------------------------------
# Step 10: validate
# -----------------------------------------------------------------------------
step "10/10 · Validating install"
"$HERE/lib/validate.sh" || true

# -----------------------------------------------------------------------------
# Final: next steps
# -----------------------------------------------------------------------------
banner "Setup complete"
cat <<EOF
Next steps:

  1. ${_C_BOLD}Restart Claude Code${_C_RESET} in this vault directory so it picks up
     the new MCP servers.

  2. Inside a fresh Claude Code session, run:
       ${_C_CYAN}/mcp${_C_RESET}               # verify every server shows "ready"
       ${_C_CYAN}/daily-brief${_C_RESET}       # smoke-test your first skill

  3. Open the vault in Obsidian:
       ${_C_CYAN}open -a Obsidian $REPO_ROOT${_C_RESET}

     Then install these recommended community plugins:
       • Templater (set folder to + Extras/Templates/)
       • Local Images Plus
           - realTimeUpdate: true
           - processCreated: true
           - attachment pattern: .resources/\${notename}/

  4. Add more accounts any time with:
       ${_C_CYAN}./bootstrap/lib/add-google-account.sh jane@newdomain.com${_C_RESET}
       ${_C_CYAN}./bootstrap/lib/add-slack-workspace.sh newteam${_C_RESET}
       ${_C_CYAN}./bootstrap/lib/add-asana.sh personal${_C_RESET}

See README.md and bootstrap/README.md for troubleshooting.
EOF
