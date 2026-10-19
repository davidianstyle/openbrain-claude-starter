---
name: push-mcp-change
description: Stage a change to a hand-managed MCP server onto its fork as a feat/* branch so every machine picks it up, and optionally release it as an upstream PR. The produce-side counterpart to /brain-update-check.
---

# push-mcp-change

The **produce** side of the MCP mechanism. `/brain-update-check` consumes (reports drift, rebuilds
`local-build`); this skill produces (authors a change, enrolls it, optionally opens the upstream PR).

**Not for MCPs you author yourself.** Servers you publish from your own monorepo ship via npm
publish — a different mechanism entirely. This skill is
only for **hand-managed third-party forks**: a clone under the configured MCP source root
(`root=` in `~/.config/openbrain/mcp-config`, default `~/Code`) whose launcher lives at
`~/.config/openbrain/lib/<name>.sh` and which has both an `origin` (upstream) and a `fork` remote
(find the clone with `mcp_get <launcher> dir`, from `_mcp-decl.sh`).

The model in brief: CLAUDE.md "MCP sync model". Read it if anything here is ambiguous.

## Sync model

Two modes:

| Mode | What it does |
|---|---|
| **stage** (default) | push the work to the fork as `feat/<slug>`, rebuild `local-build`, remind about restart |
| **release** (`--pr`) | additionally open the upstream PR from that same branch |

Staging is cheap and reversible; release is the gate. Work can sit staged indefinitely, getting real
mileage on every machine, and be released later or never.

## The one rule that matters

**`feat/` is an enrollment namespace, not a naming taxonomy.** `mcp-local-build.sh` merges
`refs/remotes/fork/feat/*` and nothing else. A branch under any other prefix is **silently absent**
from the build — no error, and `/brain-update-check` still reports every other condition clean.
Bugfixes, chores, and spikes all go under `feat/` if they are meant to run. Never widen the glob.

## Procedure

1. **Confirm the target is hand-managed — on this machine.** Two things, both required:
   - `~/.config/openbrain/mcp-config` has a `<name>.fork=<your fork's URL>` line, different from
     the declared origin. Without it the launcher's effective shape is `checkout`: it builds
     `main` alone, and no `feat/*` branch is ever merged or run. Add the line if it is missing.
   - In the clone (`mcp_get <launcher> dir`):
     ```
     git remote        # must list BOTH origin and fork
     ```
   No `fork` remote, or no fork you can push to → this is not a hand-managed MCP; stop and ask.

2. **Branch from current upstream**, never from `main`-as-it-sits and never on `main` itself:
   ```
   git fetch origin && git checkout -b feat/<slug> origin/main
   ```
   Pick `<slug>` for the change, not its category: `feat/gmail-blank-text-part`, not `feat/bugfix`.

3. **Make the change. Test it against real data, not just types.** `tsc` passing is not a test.
   Run the repo's suite, then run the changed path for real. **Reproduce the bug or behavior on the
   current build first** (before touching code), so you have seen it fail; then show old failing →
   new working, on a **scratch resource** (a throwaway repo, test mailbox, scratch doc, dummy record),
   never a real user resource. If you cannot reproduce it on the old build, you do not yet understand the
   change. For detection/parsing changes the failure mode is the silent false-negative, so a
   throwaway harness against real data is mandatory.

4. **Add regression tests, then mutation-check them.** Revert the fix, confirm each new test fails,
   restore. A test that passes both ways pins nothing.

5. **Review, then push to the fork.** The fork is a public repo, so the push publishes the diff and
   its commit messages. Before it, run `/code-review` at **high** effort on the branch diff against
   `origin/main`, and scrub the diff **and the commit messages** for anything personal. Verify each
   finding on the merits, fix what holds, and re-run. Bounded: **max 2 fix rounds**, then stop and
   escalate to the user with the open findings rather than a third round. Only then, with the user's go
   for the push (see Guardrails):
   ```
   git push -u fork feat/<slug>
   ```
   If this is rejected with *"refusing to allow an OAuth App to create or update workflow"*, the fork
   is behind upstream and upstream touched `.github/workflows/`. Fix with
   `gh auth refresh -h github.com -s workflow` (one-time, then `gh api repos/<user>/<repo>/merge-upstream -f branch=main`),
   or sync the fork from GitHub's web UI. Do **not** work around it by rewriting history.

6. **Apply — do not skip this, and pin it.** Your author build is *not* the applied build. First get
   the offer:
   ```
   bash .openbrain/lib/check-updates.sh --offer <name>
   ```
   (`<name>` is the launcher name, e.g. `google-mcp`.) It fetches, then prints the pinned
   `--apply <name> --pin <pin>` (the pin lists the exact commits the go builds) and one line per
   entry: `new` = the go lands it, `have` = `local-build` already has it, `drop` = `local-build`
   has it and the go removes it (gone from the fork).
   - **If any `new` line is not your own `fork/feat/<slug>`** (another feat, or `origin/main`), **or
     there is any `drop` line you did not intend**, the apply would change work nobody showed
     the user in this flow. **STOP:** list those lines for the user and apply only on their go. (A bare
     `--apply <name>` would land whatever is live, silently — never use one here.)
   - Otherwise run the printed command exactly, `--pin` included:
     `bash .openbrain/lib/check-updates.sh --apply <name> --pin <pin>`. Anything pushed to the fork
     after the offer is not in it; the next offer shows it.
   - `--offer` exiting 20 (`cannot — …`) means no pinned offer is possible (fetch failed, refs
     unreadable): fix what it names, then re-run it. `--apply` `failed` naming an approved commit
     "not in … after the fetch" means it was force-pushed away: re-run `--offer`.
   - `--apply` `stale` (exit 5) means the offer is out of date and nothing was built (the rule and its
     revert limit: `/brain-update-check`, **Stale offers**). Re-run `--offer` and re-check its
     `new`/`drop` lines — they may differ now.
   The apply runs the fork engine under the build lock and keeps the last-good build if tests
   fail. It must report `applied`; `failed` means the build did not land.
   Author build = your branch alone, on whatever base you cut from, with no provenance marker.
   `local-build` = current `origin/main` + **every** live `feat/*` merged, with `dist/.built-from`
   written. They coincide only when there is exactly one in-flight branch based on current upstream —
   which is precisely when it's easy to believe they're always the same.

7. **Tell the user to restart.** MCP servers read their build at launch, so every open session
   keeps running the old build until Claude Code restarts — parallel sessions each hold their own.
   `check-updates.sh` reports such a process as `stale-process`, but only restarting fixes it.
   State it plainly, every time.

8. **Verify what's live** if the change is behaviourally interesting — spawn the real launcher and
   speak MCP over stdio rather than importing the changed function directly, against a scratch
   resource as in step 3. A server that won't boot passes every unit test.

9. **Release (`--pr`) only when asked.** Before opening or updating a PR, run a pre-PR gauntlet
   (the step 5 review covered the push; re-run it on the final diff): lint/typecheck, real-data
   test, `/code-review` at high effort, and
   a **fresh subagent given the raw diff and the job of refuting it** — never the author's reasoning
   or expected verdict. Verify each finding on the merits; the refuter is sometimes wrong.
   Then scrub the outgoing diff **and the commit message** for anything personal, and:
   ```
   gh pr create --repo <upstream>/<repo> --base main --head <user>:feat/<slug> --title ... --body ...
   ```
   **Use the same `feat/*` branch as the PR head.** One branch serves both enrollment and review, so
   there are never two names for one commit.

10. **Report** the branch, whether `local-build` rebuilt cleanly, the PR URL if one was opened, and
    the restart reminder.

## Lifecycle after merge

Upstream merges → the branch becomes an ancestor of `origin/main` → its merge into `local-build`
becomes a no-op, and `--apply` reports it as a drop candidate. Delete it from the fork then.
Nothing breaks if you forget; it just accumulates.

## Guardrails

- **Never author on `main`.** `main` tracks `origin/main` and nothing else.
- **Never hand-build `dist/`** as the final step. Step 6 owns that, and only it writes `.built-from`.
- **Never commit to `local-build`.** It is derived and rebuilt from scratch every apply; edits there
  are destroyed without warning.
- **Never push to a public remote without the vault owner's go for that push** — the fork included.
- **Never run `npm audit fix`** on an upstream lockfile mid-change. It forks the lockfile and
  pollutes every future diff. Dependency CVEs are upstream's; check for a dependabot PR instead.
- Merge conflict during apply → resolve it **in the feature branch**, never in `local-build`.

## Notes

- Read state from refs, never from memory: enrolled = `fork/feat/*` exists; build provenance =
  `dist/.built-from`; PR status = `gh pr list`.
- There is deliberately **no `pull-mcp-change`**. Applying is one deterministic command with no
  decisions in it, so `/brain-update-check` dispatches it directly. The asymmetry with
  `/push-openbrain-template` + `/pull-openbrain-template` is intentional: judgment lives on the
  produce side here, not the consume side.
