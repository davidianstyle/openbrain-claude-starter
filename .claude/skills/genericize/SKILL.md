---
name: genericize
description: Diff this vault's portable infrastructure (skills, hooks, templates, CLAUDE.md, MCP launcher patterns) against the upstream openbrain-template repo, port improvements with personal data stripped out, and stage them as a commit (never pushes).
---

# /genericize

Sync improvements from this live vault back to the upstream [openbrain-template](https://github.com/davidianstyle/openbrain-template) repo. The template repo must be cloned locally — by default at `~/Code/openbrain-template`. Set the `OPENBRAIN_TEMPLATE_DIR` environment variable to override.

The vault is the working bench; the template is what other people clone. Anything that's a real improvement (a new skill, a bug fix in a hook, a smarter procedure, a new template field) should make it back to the template — but stripped of the user's name, accounts, orgs, memories, and any other personal data.

## Inputs

- `$1` (optional): scope hint — one of `all` (default), `skills`, `hooks`, `claude-md`, `templates`, `obsidian`, or a specific path like `.claude/skills/capture-meeting/SKILL.md`. Limits which files the skill compares.
- `$2` (optional): `--dry-run` — show the planned changes and the genericized diff but do not write to the template repo.

## Scope: what's portable vs. what stays in the vault

**In scope** (compare and port):

| Vault path | Template path | Notes |
|---|---|---|
| `.claude/skills/*/SKILL.md` | `.claude/skills/*/SKILL.md` | Procedures — always port improvements |
| `.openbrain/on-stop.sh` | `.openbrain/on-stop.sh` | Genericize hardcoded vault paths to `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` |
| `.openbrain/on-start.sh` | `.openbrain/on-start.sh` | Same |
| `.openbrain/pre-commit.sh` | `.openbrain/pre-commit.sh` | Same |
| `.openbrain/env.example` | `.openbrain/env.example` | Strip real account slugs; keep structure + comments |
| `+ Extras/Templates/*.md` | `+ Extras/Templates/*.md` | Note templates — port schema changes verbatim (already generic) |
| `CLAUDE.md` | `CLAUDE.md` | Most delicate — see §"CLAUDE.md handling" below |
| `.obsidian/app.json`, `core-plugins.json`, `appearance.json`, `graph.json` | same | Only port if a setting is universally useful (e.g. enabling templates plugin). Skip `workspace.json`, `community-plugins.json`, plugin data. |
| `README.md` | `README.md` | Only port if there's a real improvement; the template README is the public-facing one |

**Out of scope** (never port):

- Anything under `+ Atlas/`, `+ Spaces/`, `+ Inbox/`, `+ Sources/`, `+ Archive/` — these are content, not infrastructure
- `.obsidian/workspace.json`, `.obsidian/plugins/*` — per-machine state and plugin internals
- `~/.claude/projects/.../memory/MEMORY.md` (auto-memory) — never touch
- `~/.config/openbrain/.env` — never read, never touch
- The `bootstrap/` folder in the template repo — it has its own architecture; only update if explicitly asked
- Anything containing real secrets (PATs, OAuth client IDs, refresh tokens, xoxp-* tokens)

## Procedure

### 1. Inventory drift

Resolve paths:

```bash
VAULT="$(pwd)"
TEMPLATE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/Code/openbrain-template}"
```

For each in-scope path, compare vault vs. template using `diff -rq`:

```bash
diff -rq "$VAULT/.claude/skills/" "$TEMPLATE/.claude/skills/"
diff -rq "$VAULT/.openbrain/" "$TEMPLATE/.openbrain/"
diff -rq "$VAULT/+ Extras/Templates/" "$TEMPLATE/+ Extras/Templates/"
diff -u "$VAULT/CLAUDE.md" "$TEMPLATE/CLAUDE.md"
```

Build a working list with three categories:
- **Vault-only** files (exist in vault, not in template) — candidates for **add**
- **Template-only** files (exist in template, not in vault) — usually skip; flag if it looks like the vault drifted backwards
- **Differing** files (exist in both, different content) — candidates for **update**

Filter the list to in-scope paths per the table above. Drop anything that matches the out-of-scope rules.

### 2. Per-file analysis

For each candidate, read both versions side-by-side. Classify each hunk in the diff:

- **(P) Personal**: contains the user's name, email/Slack/account identifiers, orgs, specific people from the vault, hardcoded user-specific paths, Asana workspace gids, memory pointers, delegation tables. → **strip or rewrite** before porting.
- **(I) Improvement**: a real procedure change, bug fix, new feature, schema update, clearer wording. → **port**, after genericization.
- **(N) Noise**: timestamps, formatting nits, accidental edits. → **skip**.
- **(R) Regression**: vault is *behind* the template (e.g. template has `HAS_UPSTREAM` handling that the vault still hardcodes `origin/main`). → **flag** to user, don't auto-port the vault version backwards. The template should stay ahead.

If a file is **all (P)** with no (I), skip it.
If a file is **all (R)**, skip it and add a line to the report telling the user the vault should pull this change forward.

### 3. Genericization rules

Apply these substitutions to any text you port. They are deliberate — do them by hand, hunk by hunk, not as a blind regex pass, because context matters.

#### Identity substitutions

| Vault literal | Template form |
|---|---|
| User's real name (subject) | `the user` or `you` (match the surrounding voice) |
| User's name (possessive) | `the user's` or `your` |
| Specific colleague names | Generic example name (`Sarah`, `Alex`) or remove if not load-bearing |
| Real email addresses | `you@example.com` or remove |
| Real company/org names | `your company`, `acme.com` |
| Context-specific orgs (churches, clubs) | Remove if not load-bearing |
| Hardcoded vault path (e.g. `/Users/jane/Code/openbrain`) | `~/OpenBrain` or `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` for bash |
| Other hardcoded home paths | Generic `$HOME/...` |

#### MCP-name substitutions

The vault uses concrete slugs like `google_jane_acme_com`, `slack_acme_slack_com`. The template uses pattern references and the placeholder tables in CLAUDE.md.

| Vault literal | Template form |
|---|---|
| `mcp__google_<specific>__*` | `mcp__google_<slug>__*` |
| `mcp__slack_<specific>__*` | `mcp__slack_<workspace_slug>__*` |
| Specific `google_*` default (e.g. for work) | "the user's work `google_*` MCP (see CLAUDE.md §12)" |
| Hardcoded Asana workspace gid | `<asana_work_workspace_gid>` placeholder, or strip |
| References to `asana_work` and `asana_personal` MCPs | Keep — these names are already generic and used in the template |

#### CLAUDE.md handling

CLAUDE.md is the most personal file in the vault. Most of it should NOT be ported. Only port:

- Section structure changes (new section, renumbered section, reorganized headers)
- Convention changes that are universally true (e.g. a new tag in the taxonomy, a new frontmatter requirement)
- Clarifications to the "What you must NOT do" rules
- Improvements to skill descriptions in the skills table

NEVER port:
- §1 "Primary collaborator" identity line
- Per-machine bootstrap sections (the template has its own bootstrap wizard)
- Maintenance automation summaries that reference user-specific scheduler plans
- Multi-account routing tables — the template uses `{{GOOGLE_ACCOUNTS_TABLE}}` etc. placeholders that the bootstrap fills in
- Any "delegations" / "memory pointers" / specific people lists
- The `# auto memory` block

The template version of CLAUDE.md uses `{{USER_NAME}}`, `{{USER_VOICE}}`, `{{ASANA_ROUTING_TABLE}}`, `{{GOOGLE_ACCOUNTS_TABLE}}`, `{{SLACK_WORKSPACES_TABLE}}`, `{{FATHOM_TABLE}}`, `{{BOOTSTRAP_DATE}}`. **Preserve those placeholders verbatim.** Never resolve them to the vault values.

When in doubt, leave a CLAUDE.md hunk un-ported and surface it in the report for the user to decide.

#### Skill-file handling

Skills are the bread and butter of this skill. Most diffs in `.claude/skills/*/SKILL.md` are tractable:

- "After displaying the numbered list, ask [Name] to..." → "After displaying the numbered list, ask the user to..."
- Default MCP slugs in fall-back instructions → generic `<slug>` pattern + a CLAUDE.md §12 reference
- Example timestamps and example interaction note slugs → keep as examples but ensure they don't reference real people

If the vault has a skill the template doesn't, port it as a new file. Strip any vault-specific paths. Make sure the frontmatter `name:` and `description:` are clean.

**If the skill being ported is `/genericize` itself:** that's fine — the template ships the skill so users can run it on their own forked vaults to upstream improvements to their own template repos. Keep the vault paths as variables, not hardcoded.

#### Hook-script handling

Bash scripts under `.openbrain/`:

- Replace any hardcoded vault path with `VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`
- Replace `git push origin main` with `git push` (no branch hardcoded)
- Replace `git pull --rebase --autostash origin main` with `git pull --rebase --autostash`
- Wrap upstream-dependent operations in a `HAS_UPSTREAM` guard so a fresh clone without a remote doesn't error
- Use `${TMPDIR:-/tmp}/openbrain-on-stop.log` instead of hardcoded `/tmp/...`
- Strip any user-specific comments

If the template version already has these patterns and the vault doesn't, that's a (R) regression — flag and skip.

#### env.example handling

`.openbrain/env.example` is the tracked secrets template. It must contain **zero real values**:

- `ASANA_PAT_PERSONAL=` (empty)
- `GOOGLE_OAUTH_CLIENT_ID=` (empty)
- `GOOGLE_OAUTH_CLIENT_SECRET=` (empty)
- All Slack `SLACK_USER_TOKEN_*` variables empty
- All comments that list specific Google account slugs → replaced with the `--- GOOGLE_SLUGS (managed by bootstrap) ---` marker block from the template
- All workspace-admin gotchas referencing specific domains → genericized to "Google Workspace accounts (custom domains)" / "managed Slack workspaces"

Comments and section headers can be ported if they're a real improvement (e.g. clearer instructions, an additional OAuth scope).

### 4. Stage changes in the template repo

For each file flagged as "port":

1. Read the existing template version (if any).
2. Apply only the (I) hunks, with genericization substitutions baked in.
3. Write the resulting file to the template repo path.
4. For brand-new files (vault-only), create the file from scratch using the genericized vault content.
5. Use the `Edit` tool when modifying an existing template file (preserve the rest of the file). Use `Write` only for new files.

After all writes, run:

```bash
cd "$TEMPLATE" && git status && git diff --stat
```

### 5. Show the diff and confirm before committing

This is **mandatory**. Personal data leaking into a public repo is the worst-case failure mode for this skill.

Run:

```bash
cd "$TEMPLATE" && git diff
```

Then prompt the user via `AskUserQuestion`:

> Reviewed the diff above. **Scan for any leftover personal data** (names, emails, slugs, paths, org names) — does anything look wrong?
>
> Options:
> - **Looks good — commit** (creates a commit in the template repo, does NOT push)
> - **Revert all** (`git checkout -- .` in the template repo)
> - **Edit specific files** — list which ones, then re-run the genericize step on those
> - **Show me path X** — read a specific staged file

Only proceed to step 6 on **Looks good — commit**.

### 6. Commit (never push)

```bash
cd "$TEMPLATE" && git add -A && git commit -m "$(cat <<'EOF'
sync: port improvements from upstream vault

<one-line summary of what changed>

- <bullet per ported change>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Never `git push`.** The user reviews the commit and pushes manually when ready. A committed change is local and trivially `git reset --soft HEAD~1` to undo. Pushing makes the change visible on github.com.

### 7. Report

Output to the user:

- **Ported**: list of files changed in the template repo, one line each, with a 5–10 word summary of what was ported.
- **Skipped (personal-only)**: list of files where the diff was 100% personal data and nothing was worth porting.
- **Skipped (regression)**: list of files where the template was *ahead* of the vault — the user should pull these forward into the vault. Include a `git diff` snippet so they can see what's missing.
- **Flagged for manual review**: list of files where the genericization was non-trivial and the user should look at the result before pushing. Include the staged template path.
- **Vault-only files added**: list of new files added to the template repo.
- **Commit hash** (if a commit was made), and a reminder: *Run `cd ~/Code/openbrain-template && git push` when ready.*

## Output

A structured report (the items in §7) plus the path to the template repo's working tree state.

## Notes

- This skill is **read-mostly on the vault side, write-only on the template side**. It must never edit the vault.
- The skill is **idempotent**: running it twice in a row should produce a no-op the second time, because the template will already match the genericized vault.
- The skill **never touches secrets**: it never reads `~/.config/openbrain/.env`, and it scans every staged hunk for the patterns `xoxp-`, `0/`, `apps.googleusercontent.com`, `ASANA_PAT_`, and any 40-character-hex-looking string before allowing the commit. If found, abort and ask the user.
- The `/dry-run` mode does steps 1–3 plus a *preview* of what step 4 would write, but skips writes and the commit.
- If the user asks `/genericize all` and the diff is huge, batch the work file-by-file with a brief progress line, rather than one giant report.
- The template's `bootstrap/` folder has its own architecture and is **not** a port target by default — only touch it on explicit request, since the bootstrap wizard isn't mirrored in the vault.
- This skill is itself a candidate for porting. The template version of `/genericize` helps users keep their personal forks of the template in sync with their own upstreams.
