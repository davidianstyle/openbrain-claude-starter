---
name: pull-openbrain-template
description: Pull the latest changes from the upstream openbrain-claude-starter repo, diff against this vault's infrastructure, and interactively apply each change with user approval.
---

# /pull-openbrain-claude-starter

Pull improvements from the upstream [openbrain-claude-starter](https://github.com/davidianstyle/openbrain-claude-starter) repo into this vault. The inverse of `/push-openbrain-claude-starter`: that skill pushes vault improvements upstream; this skill pulls template improvements downstream.

The template repo must be cloned locally — by default at `~/openbrain-claude-starter`. Set the `OPENBRAIN_TEMPLATE_DIR` environment variable to override.

## Inputs

- `$1` (optional): scope hint — one of `all` (default), `skills`, `hooks`, `claude-md`, `templates`, `obsidian`, or a specific path like `.claude/skills/capture-meeting/SKILL.md`. Limits which files the skill compares.
- `$2` (optional): `--dry-run` — show the planned changes but do not write anything to the vault.

## Scope: what's comparable

Same in-scope paths as `/push-openbrain-claude-starter`, but in the reverse direction (template → vault):

| Template path | Vault path | Notes |
|---|---|---|
| `.claude/skills/*/SKILL.md` | `.claude/skills/*/SKILL.md` | Procedure improvements |
| `.openbrain/pre-commit.sh` | `.openbrain/pre-commit.sh` | Pre-commit linter |
| `.openbrain/env.example` | `.openbrain/env.example` | Secrets template |
| `+ Extras/Templates/*.md` | `+ Extras/Templates/*.md` | Note templates |
| `CLAUDE.md` | `CLAUDE.md` | Operating manual (most delicate — see §"CLAUDE.md handling") |
| `.obsidian/app.json`, `core-plugins.json`, `appearance.json`, `graph.json` | same | Only universally useful settings |
| `bootstrap/` | `bootstrap/` | Bootstrap scripts — include in diff, but flag for careful review |
| `README.md` | `README.md` | Only if the template has real improvements |

**Out of scope** (never touch from template):

- Content folders: `+ Atlas/`, `+ Spaces/`, `+ Inbox/`, `+ Sources/`, `+ Archive/`
- `~/.claude/projects/.../memory/` — auto-memory
- `~/.config/openbrain/.env` — secrets
- `.obsidian/workspace.json`, `.obsidian/plugins/*` — per-machine state

## Procedure

### 1. Fetch latest template

Resolve paths:

```bash
VAULT="$(pwd)"
TEMPLATE="${OPENBRAIN_TEMPLATE_DIR:-$HOME/openbrain-claude-starter}"
```

If the template directory exists, sync it; otherwise clone it. **Branch-aware:** if the clone is already checked out on a non-`main` branch (e.g. a staging or integration branch prepared for this pull), keep that checkout and skip the pull — the user put it there deliberately. Announce which ref is being diffed and name it again in the final report.

```bash
if [ -e "$TEMPLATE/.git" ]; then
  (
    cd "$TEMPLATE" && {
      BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
      if [ "$BRANCH" = "main" ] || [ -z "$BRANCH" ]; then
        git checkout main && git pull --rebase --autostash
      else
        echo "template clone is on '$BRANCH' — diffing that tree as-is (no checkout/pull)"
      fi
    }
  )
else
  git clone git@github.com:davidianstyle/openbrain-claude-starter.git "$TEMPLATE"
fi
```

### 2. Inventory drift

For each in-scope path, compare template vs. vault:

```bash
diff -rq "$TEMPLATE/.claude/skills/" "$VAULT/.claude/skills/"
diff -rq "$TEMPLATE/.openbrain/" "$VAULT/.openbrain/"
diff -rq "$TEMPLATE/+ Extras/Templates/" "$VAULT/+ Extras/Templates/"
diff -u "$TEMPLATE/CLAUDE.md" "$VAULT/CLAUDE.md"
diff -rq "$TEMPLATE/bootstrap/" "$VAULT/bootstrap/"
```

Build a working list with three categories:
- **Template-only** files (exist in template, not in vault) — candidates for **add**
- **Vault-only** files (exist in vault, not in template) — skip (vault extensions, not regressions)
- **Differing** files (exist in both, different content) — candidates for **update**

Filter to in-scope paths. Drop anything matching out-of-scope rules.

**Then apply the ignore manifest.** If `$VAULT/.openbrain/template-ignore` exists, drop every candidate whose vault-root-relative path matches one of its entries (one path or glob per line; `#` comments and blank lines skipped — see the file's header). These are known intentional divergences (keepers): the vault's version stays, whatever the template does. So the skip is never silent, report one line in the final summary:

> `template-ignore: N path(s) skipped (path1, path2, …)`

with N=0 and no list when nothing matched. If a specific path entry (not a glob) matched no candidate and that file no longer exists in either the vault or the template, note it as stale — the divergence it covered is gone. Glob entries and currently-identical files are not stale; they are dormant and stay silent.

### 3. Per-file analysis

For each candidate, read both versions. Classify each hunk:

- **(I) Improvement from template**: a real procedure change, bug fix, new feature, schema update, clearer wording that the vault should adopt. → **propose to apply**.
- **(P) Personal in vault**: the vault version has the user's specific data (account slugs, names, gids) where the template has placeholders. The vault version is correct for this vault — keep it. → **skip**.
- **(G) Generic placeholder**: the template uses `{{PLACEHOLDER}}` or `<slug>` where the vault has resolved values. The vault values are correct. → **skip**.
- **(N) Noise**: whitespace, formatting nits, generated timestamps. → **skip**.
- **(V) Vault-ahead**: the vault has an improvement the template doesn't — this is a `/push-openbrain-claude-starter` candidate, not a pull candidate. → **flag** for future `/push-openbrain-claude-starter` run.

### 4. De-genericize template content

When applying template content to the vault, reverse the genericization:

| Template form | Vault form |
|---|---|
| `the user` / `you` (as subject) | The user's real name (where the vault convention uses it) |
| `{{USER_NAME}}` | The user's full name (from CLAUDE.md §1) |
| `{{USER_EMAIL}}` | The user's primary email |
| `{{GOOGLE_ACCOUNTS_TABLE}}` | Keep the vault's existing resolved table |
| `{{SLACK_WORKSPACES_TABLE}}` | Keep the vault's existing resolved table |
| `{{ASANA_ROUTING_TABLE}}` | Keep the vault's existing resolved table |
| `{{FATHOM_TABLE}}` | Keep the vault's existing resolved table |
| `{{BOOTSTRAP_DATE}}` | Keep the vault's existing date |
| `~/OpenBrain` | The vault's actual path |
| `$HOME/...` (generic) | The vault's absolute paths (if the vault uses them) |
| `mcp__google_<slug>__*` | Vault's concrete MCP names |
| `mcp__slack_<workspace_slug>__*` | Vault's concrete Slack MCP names |
| `<slug>` pattern references | Keep vault's concrete slugs where they exist |

**Important:** Never blindly replace the vault's resolved routing tables or identity sections with template placeholders. Only port the *structural/procedural* improvements around them.

### 5. Present changes interactively

For each file with applicable (I) hunks, present the diff to the user via `AskUserQuestion`:

> **File: `<path>`**
>
> The template has the following improvement over the vault:
>
> ```diff
> <unified diff of just the (I) hunks, de-genericized>
> ```
>
> Options:
> - **Apply** — write this change to the vault
> - **Skip** — leave the vault version as-is
> - **Show full file** — display both versions side by side
> - **Edit** — apply with modifications (describe what you want changed)

Process files one at a time (or in small batches of closely related changes). Never bulk-apply without per-change confirmation.

### 6. Apply approved changes

For each approved change:

1. Read the current vault file.
2. Apply only the approved hunks using the `Edit` tool.
3. Verify the result is valid (no broken frontmatter, no orphaned placeholders).

After all approved changes are applied:

```bash
cd "$VAULT" && git status && git diff --stat
```

**Do not commit.** The vault's stop hook handles commits automatically. Just leave the changes as unstaged modifications.

### 7. Report

Output to the user:

- **Applied**: list of files changed in the vault, one line each, with a summary of what was pulled in.
- **Skipped (personal/placeholder)**: files where the diff was entirely resolved-vs-generic and nothing needed porting.
- **Skipped (user declined)**: files the user chose to skip.
- **Vault-ahead (push candidates)**: files where the vault has improvements the template doesn't — suggest running `/push-openbrain-claude-starter` to port them upstream.
- **Template-only files not added**: new files in the template that weren't added to the vault (with a note on why, or ask if the user wants them).

## Notes

- This skill is **read-only on the template side, write-only on the vault side**. It must never edit the template repo.
- The skill is **idempotent**: running it twice yields no changes the second time.
- The skill **never touches secrets**: it never reads `~/.config/openbrain/.env` and never writes credentials into the vault.
- `--dry-run` mode does steps 1–4 and shows what would be proposed, but skips the interactive apply loop and writes nothing.
- If the scope is `all` and the diff is large, batch the interactive prompts by category (skills first, then hooks, then templates, then CLAUDE.md last since it's most sensitive).
- CLAUDE.md changes require extra care — the vault version has fully resolved tables and user-specific content. Only port structural changes (new sections, reworded rules, new skill entries in tables). Never overwrite the resolved routing tables with `{{PLACEHOLDER}}` markers.
- The `bootstrap/` folder is included in the diff but flagged as "careful review" — bootstrap changes may require re-running `bootstrap/setup.sh` after applying.
