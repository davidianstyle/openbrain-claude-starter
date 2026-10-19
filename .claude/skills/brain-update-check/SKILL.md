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
- `ask` — report only; you offer `--apply` and apply only on the user's go. A go builds
  **exactly what the report showed**: every `--apply` the report prints carries a `--pin` listing
  the commits it saw, and you always run it with that pin (see step 3).
- `auto` — `--full` applies it when the test gate passes (last-good build kept on failure,
  "installed — restart Claude Code to apply"). Held only when a human must act first: the tree
  (dirty-tree, off-branch, unpushed) or the configuration (shape-mismatch, bad-declaration, unenrolled,
  unsupported-key, fork-mismatch, origin-mismatch).
  Plain npm on the stable channel has **no test gate**: auto just records the latest publish,
  which the launcher pins to. Auto applies unpinned — its consent is the standing policy, so it
  takes whatever is live when `--full` runs; the post-apply re-check reports what landed.
- An invalid value (or a line that isn't `key=value`) is never defaulted: invalid mode →
  CANNOT-CHECK and the launcher refuses to start; a stray line → `bad-policy`. Relay the fix.
- To revert a server, rebuild a previous commit locally:
  `cd <checkout> && git checkout <sha> && npm ci --ignore-scripts && npm run build && git rev-parse HEAD > dist/.built-from` (a monorepo package builds with
  `-w <sub>` and stamps `<sub>/dist/.built-from`). The restamp is what keeps the report honest: the
  checker then shows `off-branch` (plus `source-behind` for a checkout, `dist-stale` for a fork), and auto holds it. `--apply` refuses
  a checkout-shaped server that isn't on its branch, so to go forward again, `git switch <branch>` in the
  checkout (`main` or the declared/`.branch=` one; `local-build` for a fork), then `--apply`.
  An npm server (stable channel) reverts by recording the older version, which the launcher's
  `npx <pkg>@<version>` reads at its next start: `printf '%s\n' <version> > ~/.config/openbrain/mcp-updates/<name>.applied`, then restart
  Claude Code (under `auto`, set `<name>.update=ask` first, or the next `--full` records the latest again).
- **Stale offers (the one full statement of this rule).** Every offer's pin ends in `built=`, the build
  the offer was made against. A go is refused as `stale` (nothing built or recorded) when the current
  build differs from that build, because an apply, a build or a revert landed after the offer; a pin with
  no `built=` is refused the same way. The check compares build identity, not order, so any offer passes
  again once the current build is the one it was made against; the realistic way back is a revert.
  **After a revert, discard every older offer and re-run this skill:** an offer made against the exact
  build you reverted to still passes, and its go would re-apply what the revert removed. A fresh
  report's offer moves forward from the reverted build.

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
   Every `⚠` / `?` line and every Auto-updates line is followed by one `  in plain words: …` line
   (the technical line and command stay as printed). The user may read on a phone: lead with the plain
   line and keep the technical line for the command; never drop either. On a clean run there are none.
2. If an **Auto-updates** section is present, relay it first: `✓ applied` items (each ends with
   "installed — restart Claude Code to apply"), `⏸ held` items with
   the reason (something needs a human first; the finding stays below), `✗ failed` items
   (tests failed or the engine refused; last-good build kept).
3. For each `⚠` finding, offer its listed command and wait for a yes. **Run the command exactly as
   printed, `--pin <pin>` included — never strip, edit or reuse a pin from an earlier report.** The
   pin is the exact build the report showed, and the go builds exactly it: a fork's
   `main=<sha>,feat/<name>=<sha>,…` (origin/main + every `fork/feat/*` tip), a checkout's
   `origin/<branch>` commit, an npm version — each ending in `,built=<sha|version|none>`, the build
   the offer was made against. A go whose `built=` is no longer the current build is refused as `stale`
   (nothing is built or recorded); re-run this skill (or `--offer <name>`) and offer the new command. The
   full rule, including its limit after a revert, is the **Stale offers** bullet above. (A bare `--apply <name>` applies
   whatever is live at apply time; run it only when the user types it themselves.) The setup
   remedies `missing` / `shape-mismatch` carry no pin — nothing is fetched yet — so say in the
   offer that they install whatever is live.
   **No pin, no offer:** a finding whose remedy reads "no pinned --apply can be offered — see the
   CANNOT-CHECK for <name>" has no command to run. Relay that CANNOT-CHECK (it says why: no
   `origin/<branch>`, unreadable refs, a feat name a pin cannot carry, registry down) and **never** substitute a
   bare `--apply` for it.
   - `no-dist` / `unproven-build` / `dist-stale` / `source-behind` / `no-local-build` /
     `update-available` / `unpinned` → `bash .openbrain/lib/check-updates.sh --apply <name> --pin <pin>`.
     fork → rebuilds `local-build` from the offered `origin/main` + `feat/*` tips (`source-behind`
     on a fork also means a `feat/*` tip not yet in `local-build`); checkout → ff to the offered
     commit + build; npm → records the offered version as the applied version (the launcher pins
     to it; no test gate). Every fork/checkout/canary apply is gated on tests and keeps the last-good build on
     failure, and ends with "installed — restart Claude Code to apply".
   - `stranded-build` → an interrupted build left the last-good `dist/` in `.dist.bak`; offer
     its printed `--apply <name> --pin <pin>` (relaunching the server also restores it). Not uncommitted work.
   - `unproven-build` also covers an unstamped `dist/` (an interrupted, mixed or hand build, or one
     from before provenance stamps): the launcher still runs it (launch never rebuilds a `dist/`
     whose entry exists); its printed `--apply <name> --pin <pin>`, run exactly as printed,
     rebuilds and stamps it.
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
   - Anything pushed after the report is simply not in the go — the next report offers it. A fork
     go also drops a `feat/*` that local-build has but the fork no longer does (the report says so
     as `source-behind … neither origin/main nor any live`); name that drop in the offer.
   - `stale` (exit 5) → the offer is out of date (rule: **Stale offers** above). Nothing was built or
     recorded. Re-run this skill and offer the fresh command; never edit the pin to get past it.
   - `held` (exit 4) → a checkout's HEAD is still past the approved commit with changes to that
     package (local unpushed commits, or another server's apply moved a shared checkout). Nothing
     was built. Relay the printed cause and its fix; there is nothing to re-run until it is fixed.
   - `failed` naming an approved commit "not in … after the fetch" → that commit is gone from the
     remote (force-pushed away) or the pin was mistyped: nothing was built; re-run this skill.
   - A checkout or npm go builds exactly the offered commit / records exactly the offered
     version, even when something newer has been pushed or published since (as long as the build
     itself has not changed — else `stale`); the next report offers the newer one.
5. To stop being nagged about a known/intended state: `bash .openbrain/lib/check-updates.sh --snooze`
   (silences `--check` until the pending findings change). CANNOT-CHECK is never snoozed.

## Notes

- Modes: `--check` (cheap, local, no network, never mutates — the session-start summary: a line
  plus its one plain-words line, nothing at all when clean; run by `.openbrain/on-start.sh`) · `--full` (this skill) · `--report` (`--full` without auto-apply)
  · `--apply <mcp> [--pin <pin>]` · `--offer <mcp>` (one MCP's pinned offer + its new/have/drop lines;
  `/push-mcp-change` step 6) · `--snooze`.
- Auto-apply only happens when `--full` runs, i.e. when this skill runs. Nothing schedules it.
- Engine: `.openbrain/lib/mcp-local-build.sh` (fork mode, and `--checkout` mode). Apply history:
  `~/.config/openbrain/mcp-updates/applied.log`; npm last-applied versions: `…/mcp-updates/<name>.applied`.
- A launcher with a missing checkout self-installs on first launch (lazy clone of the branch its
  build tracks + build from the declaration's `url=`). Dependencies install with
  `--ignore-scripts` (skipped when `package-lock.json` is unchanged since the last complete
  install); the build and the tests run explicitly. A build stamps `dist/.built-from` only when
  every file in `dist/` is its own; otherwise it fails loudly and leaves `dist/` unstamped, which
  the checker reports as `unproven-build` until `--apply` rebuilds it.
