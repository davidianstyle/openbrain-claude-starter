---
name: brain-update-check
description: Report whether this brain's MCP servers have updates waiting (upstream moved, dist stale, npm publish, an open session running an old build) with stated coverage, auto-apply what the update policy allows, and offer to apply the rest. Applies beyond the policy only on the user's go.
---

# brain-update-check

The front end for the brain's MCP update mechanism (`.openbrain/lib/check-updates.sh`). It
covers the MCP servers registered in `~/.claude.json` — its user-scope servers plus its
project entry for this vault (nothing else: a project `.mcp.json` is not read; the Coverage
block names the source). Each
`~/.config/openbrain/lib/*-mcp.sh` launcher declares its shape in one
`# openbrain-mcp: shape=fork|checkout|npm ...` line (grammar: `.openbrain/lib/_mcp-decl.sh`), and
every registered stdio server must resolve to a declared launcher. It is also the single "is
anything waiting?" entry point for the **template**: every live template branch, checked against
`.openbrain/local/taken.tsv` by `.openbrain/lib/taken-status.sh` (step 0). It only reports;
applying upstream is `/pull-openbrain-template`.

**Update policy** is per MCP and per machine: `<launcher>.update=auto|ask` lines in
`~/.config/openbrain/mcp-config` (no line → `ask`). Nothing is inferred — not ownership,
not the channel (canary does not imply auto).
- `ask` — report only; you offer `--apply` and apply only on the user's go.
- `auto` — `--full` applies it when the test gate passes (last-good build kept on failure,
  "installed — restart Claude Code to apply"). Held only when a human must act first: the tree
  (dirty-tree, off-branch, unpushed) or the configuration (shape-mismatch, bad-declaration, unenrolled,
  unsupported-key, fork-mismatch, origin-mismatch).
  Plain npm on the stable channel has **no test gate**: auto just records the latest publish,
  which the launcher pins to.
- An invalid value (or a line that isn't `key=value`) is never defaulted: invalid mode →
  CANNOT-CHECK and the launcher refuses to start; a stray line → `bad-policy`. Relay the fix.
- To revert a server, rebuild a previous commit locally:
  `cd <checkout> && git checkout <sha> && npm ci --ignore-scripts && npm run build && git rev-parse HEAD > dist/.built-from` (a monorepo package builds with
  `-w <sub>` and stamps `<sub>/dist/.built-from`). The restamp is what keeps the report honest: the
  checker then shows `off-branch` (plus `source-behind` for a checkout, `dist-stale` for a fork), and auto holds it. `--apply` refuses
  a checkout-shaped server that isn't on its branch, so to go forward again, `git switch <branch>` in the
  checkout (`main` or the declared/`.branch=` one; `local-build` for a fork), then `--apply`.

**Channel** (npm-shaped MCPs only; same per-machine file, `channel=stable|canary` default plus
`<launcher>.channel=…` overrides, e.g. `<launcher>.channel=canary`):
- `stable` — the published npm package via npx, pinned to the last-applied version; npm checks.
- `canary` — runs from the source checkout (`src=`/`sub=` on the declaration, `main`), lazily
  cloned from `url=` on first launch and built by the same engine; checked and applied exactly
  like `shape=checkout`. "Unreleased vs npm" appears under **Info (not findings)** — relay it as
  information only, never as something to fix.
- Switching = edit the file + restart Claude Code. An invalid value is CANNOT-CHECK and the
  launcher refuses to start — relay the printed fix, never guess a channel.

## Steps

0. Template branches (read-only; fetches the template clone, never merges or writes `taken.tsv`):
   ```
   bash .openbrain/lib/taken-status.sh --all
   ```
   One line per live branch — `nothing-new`, `new` (N commits past this vault's last recorded point) or `cannot-check`
   — then a coverage line. Exit **0** nothing new · **10** something new · **20** CANNOT-CHECK, which
   is **not** clean: name each `cannot-check` line and its reason. Relay the coverage line verbatim.
   - `new` on `upstream` → offer `/pull-openbrain-template`; on any other branch → report it
     and what is new. Never apply anything without the user's go.
   - `new … never taken here` → this vault has no `taken.tsv` row for that branch yet.
   - `not asked:` lists taken branches no longer on staging. Rows accumulate by design — never
     suggest deleting them.
   - `staging: not configured` → the clone has no `staging` remote; only upstream was checked. Not
     a failure (a staging remote that is present but unreachable is `cannot-check`).
1. Run the report (fetches each checkout, consults npm, auto-applies per policy, re-checks):
   ```
   bash .openbrain/lib/check-updates.sh --full
   ```
   Exit codes: **0** CLEAN · **10** FINDINGS · **20** CANNOT-CHECK. Exit 20 is **not** clean —
   say so and name the `?` lines. Always relay the Coverage block's `checked` count and any
   `declared-not-registered` programs, so "clean" is never a claim about fewer servers than it sounds.
2. If an **Auto-updates** section is present, relay it first: `✓ applied` items (each ends with
   "installed — restart Claude Code to apply"), `⏸ held` items with
   the reason (something needs a human first; the finding stays below), `✗ failed` items
   (tests failed or the engine refused; last-good build kept).
3. For each `⚠` finding, offer its listed command and wait for a yes:
   - `no-dist` / `unproven-build` / `dist-stale` / `source-behind` / `no-local-build` /
     `update-available` / `unpinned` → `bash .openbrain/lib/check-updates.sh --apply <name>`.
     fork → rebuilds `local-build` from the fork's `feat/*` branches (`source-behind` on a fork also
     means a `feat/*` tip not yet in `local-build`); checkout → ff-pull + build;
     npm → records the latest publish as the applied version (the launcher pins to it; no test
     gate). Every fork/checkout/canary apply is gated on tests and keeps the last-good build on
     failure, and ends with "installed — restart Claude Code to apply".
   - `stranded-build` → an interrupted build left the last-good `dist/` in `.dist.bak`; offer
     `--apply <name>` (relaunching the server also restores it). Not uncommitted work.
   - `unproven-build` also covers an unstamped `dist/` (an interrupted, mixed or hand build, or one
     from before provenance stamps): the launcher still runs it (launch never rebuilds a `dist/`
     whose entry exists); `--apply <name>` rebuilds and stamps it.
   - A Coverage/Info line "build in progress" next to a `.dist.bak` is a live build's backup —
     not a finding; nothing to do.
   - `stale-process` → nothing to build; an open session is running an older build than the one
     on disk, or still runs the other channel after a switch. Tell the user to **restart Claude
     Code** (all sessions using that server).
   - `dirty-tree` / `off-branch` / `unpushed` → tell the user to commit/stash/switch/push first;
     never apply over it (the engine refuses anyway). On a fork, `off-branch` means HEAD is not on
     `local-build`, so the stamp no longer proves what `dist/` holds.
   - `unsupported-key` → a fork-shaped server carries a key the fork engine cannot honour
     (`sub=`, `entry=`, or a branch other than `main`); every build of it stops until the key is
     removed or the `.fork=` line is dropped. Relay the printed fix.
   - `unenrolled` → a fork branch outside the `feat/*` enrollment namespace; `--apply` will **not**
     include it. Offer the printed choice: re-push as `feat/<slug>`, or delete it if dead. Never
     widen the glob (CLAUDE.md "MCP sync model").
   - `undeclared` / `undeclared-server` / `bypasses-launcher` / `bad-declaration` / `bad-policy` /
     `shape-mismatch` / `dangling-registration` → configuration problems; relay the printed fix.
     `undeclared` right after a pull usually just means the runtime wasn't redeployed: the fix is
     `bash .openbrain/lib/reconcile-runtime.sh --apply`, never an edit to the installed launcher
     (the next redeploy overwrites it). A suggested declaration line is an inference for the user
     to confirm, never apply it silently.
   - `publish-lag` → an own npm package has unpublished source changes; publishing is public and
     needs the user's explicit go.
4. Apply only the items the user approves, one at a time, reporting each result.
5. To stop being nagged about a known/intended state: `bash .openbrain/lib/check-updates.sh --snooze`
   (silences `--check` until the pending findings change). CANNOT-CHECK is never snoozed.

## Notes

- Modes: `--check` (cheap, local, no network, never mutates — the session-start one-liner,
  run by `.openbrain/on-start.sh`) · `--full` (this skill) · `--report` (`--full` without auto-apply)
  · `--apply <mcp>` · `--snooze`.
- Auto-apply only happens when `--full` runs, i.e. when this skill runs. Nothing schedules it.
- Engine: `.openbrain/lib/mcp-local-build.sh` (fork mode, and `--checkout` mode). Apply history:
  `~/.config/openbrain/mcp-updates/applied.log`; npm last-applied versions: `…/mcp-updates/<name>.applied`.
- A launcher with a missing checkout self-installs on first launch (lazy clone of the branch its
  build tracks + build from the declaration's `url=`). Dependencies install with
  `--ignore-scripts` (skipped when `package-lock.json` is unchanged since the last complete
  install); the build and the tests run explicitly. A build stamps `dist/.built-from` only when
  every file in `dist/` is its own; otherwise it fails loudly and leaves `dist/` unstamped, which
  the checker reports as `unproven-build` until `--apply` rebuilds it.
