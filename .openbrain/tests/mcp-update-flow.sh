#!/usr/bin/env bash
# Harness for the LIVE check-updates.sh / mcp-local-build.sh / _common.sh / _mcp-decl.sh
# (per-MCP auto|ask update policy). Runs the live bytes; fixtures only under $T.
#
# SCOPE: nothing here reads a machine's deployed launchers, its ~/.claude.json registrations
# or its MCP checkouts. Everything below is self-contained: it runs against the repo's own shipped launchers
# (VLIB) and synthetic fixtures under $T, and never touches real ~/.claude.json,
# ~/.config/openbrain, or any checkout outside $T.
set -uo pipefail
VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VLIB="$VAULT/.openbrain/lib"
CU="$VLIB/check-updates.sh"
ENGINE="$VLIB/mcp-local-build.sh"
LIVE_LIB="${LIVE_LIB:-$VLIB}"      # the repo's own shipped launchers (self-contained)
T="$(mktemp -d "${TMPDIR:-/tmp}/mcp-update-flow-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
# Undeclared launchers (the pre-declaration shape), derived from the shipped ones by
# stripping the declaration line, so the fixture never goes stale or leaves the machine.
OLD_LIB="$T/undeclared-lib"; mkdir -p "$OLD_LIB"
for f in "$LIVE_LIB"/*-mcp.sh "$LIVE_LIB"/_common.sh; do [ -f "$f" ] && grep -v '^# openbrain-mcp:' "$f" > "$OLD_LIB/$(basename "$f")"; done
pass=0; fail=0; skipped=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf 'SKIP  %s  (%s)\n' "$1" "$2"; skipped=$((skipped+1)); }
sedi(){ sed "$1" "$2" > "$2.sedi" && mv "$2.sedi" "$2"; }   # portable in-place edit (BSD and GNU sed differ on -i)
sed_verify(){  # sed_verify <file> <expected-substring> <label> — a fixture sed that
               # silently matches nothing is a false PASS waiting to happen; scream instead.
  grep -qF -- "$2" "$1" || { printf 'FIXTURE BUG: %s — expected substring not found in %s after sed: %s\n' "$3" "$1" "$2" >&2; exit 90; }
}
expect(){
  local label="$1" want="$2" yes="$3" nay="$4" good=1
  [ "$RC" = "$want" ] || good=0
  if [ "$yes" != - ] && ! printf '%s\n' "$OUT" | grep -Eq -- "$yes"; then good=0; fi
  if [ "$nay" != - ] &&   printf '%s\n' "$OUT" | grep -Eq -- "$nay"; then good=0; fi
  if [ "$good" = 1 ]; then ok "$label"; else no "$label  (rc=$RC want=$want)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}
run(){ OUT="$(env "$@" bash "$CU" --raw 2>&1)"; RC=$?; }
runa(){ OUT="$(env "$@" bash "$CU" --auto-raw 2>&1)"; RC=$?; }
HERM=(MCP_UPDATE_STATE="$T/state" MCP_CONFIG_FILE="$T/no-policy")
commit(){ git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }

echo "== B. broken inputs — each must SCREAM (synthetic registry; shipped launchers only)"
# Synthetic ~/.claude.json registering the four launchers this template ships, all
# pointing at LIVE_LIB (never the real ~/.claude.json).
CJSON="$T/claude.json"
printf '{"mcpServers":{"asana_personal":{"type":"stdio","command":"%s/asana-mcp.sh","args":["personal"]},"fathom":{"type":"stdio","command":"%s/fathom-mcp.sh","args":[]},"google_x":{"type":"stdio","command":"%s/google-mcp.sh","args":["x"]},"slack_y":{"type":"stdio","command":"%s/slack-mcp.sh","args":["y"]}}}\n' \
  "$LIVE_LIB" "$LIVE_LIB" "$LIVE_LIB" "$LIVE_LIB" > "$CJSON"
REAL=(MCP_LIB_DIR="$LIVE_LIB" MCP_CLAUDE_JSON="$CJSON" OPENBRAIN_VAULT="$VAULT" MCP_NO_FETCH=1)
run "${REAL[@]}" "${HERM[@]}" MCP_LIB_DIR="$OLD_LIB" MCP_REGISTERED_LIB="$LIVE_LIB"
expect "B1 undeclared launchers -> CANNOT-CHECK"               20 'none resolved to a declared launcher' $'^cov\tchecked\t[1-9]'
mkdir -p "$T/emptylib"; cp "$VLIB/_mcp-decl.sh" "$T/emptylib/"
run "${REAL[@]}" "${HERM[@]}" MCP_LIB_DIR="$T/emptylib"
expect "B2 zero launchers -> CANNOT-CHECK"                     20 'zero \*-mcp.sh launchers' -
printf '{not json' > "$T/bad.json"
run "${REAL[@]}" "${HERM[@]}" MCP_CLAUDE_JSON="$T/bad.json"
expect "B3 unparseable ~/.claude.json -> CANNOT-CHECK"         20 'cannot read/parse' -
# B4 (npm registry unreachable) dropped: the template ships no npm-shaped launcher by
# default, so there is nothing here to exercise check_npm's registry-lookup-failure path
# hermetically. npm registry behaviour (view failures, pinning, stale-vs-published) is
# still covered by section E below via a fully synthetic npm-shaped launcher.
run "${REAL[@]}" "${HERM[@]}" MCP_PS_FILE="$T/nonexistent-ps"
expect "B5 ps unavailable -> CANNOT-CHECK (not a silent 0 stale)" 20 'ps failed' $'procs\t'
# badlib/mislib are built from the VAULT's current (relative-dir=) launchers, not
# the possibly-stale LIVE deployed copies — these are declaration-syntax tests,
# not real-checkout tests, so they must target what the launchers actually say today.
mkdir -p "$T/badlib"; cp "$VLIB"/*-mcp.sh "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$T/badlib/"
sedi 's/^# openbrain-mcp: shape=checkout dir=google-mcp /# openbrain-mcp: shape=frok dir=google-mcp /' "$T/badlib/google-mcp.sh"
sed_verify "$T/badlib/google-mcp.sh" 'shape=frok dir=google-mcp' "B6 sed"
printf '# openbrain-mcp: shape=npm pkg=x\n' >> "$T/badlib/asana-mcp.sh"
sedi 's|^# openbrain-mcp: shape=checkout dir=fathom-mcp url=|# openbrain-mcp: update=auto shape=checkout dir=fathom-mcp url=|' "$T/badlib/fathom-mcp.sh"
sed_verify "$T/badlib/fathom-mcp.sh" '# openbrain-mcp: update=auto shape=checkout dir=fathom-mcp url=' "B8 sed"
run "${REAL[@]}" "${HERM[@]}" MCP_LIB_DIR="$T/badlib" MCP_REGISTERED_LIB="$LIVE_LIB"
expect "B6 typo'd shape -> bad-declaration"                    10 $'google-mcp\tbad-declaration' -
expect "B7 two declaration lines -> bad-declaration"           10 $'asana-mcp\tbad-declaration' -
expect "B8 update= left on a declaration -> bad-declaration, NOT honoured" 10 $'fathom-mcp\tbad-declaration.*remove update=' 'fathom-mcp=auto'
# B9: the tracked declaration is shape=checkout — no shape-mismatch
# class exists for it unless a resolved .fork= promotes it to fork. Both halves share a
# hermetic checkout (root= pointed at a temp dir, never the real ~/Code or ~/<name>) with
# only an 'origin' remote — never touches a real checkout.
mkdir -p "$T/mislib"; cp "$VLIB"/*-mcp.sh "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$T/mislib/"
mkdir -p "$T/broot"
# B9a: no checkout at all yet, no .fork= -> resolves as checkout (never shape-mismatch,
# a fork-specific class); "missing" is checkout's own remedy for "not installed yet".
printf 'root=%s\n' "$T/broot" > "$T/b9-nofork"
run "${REAL[@]}" MCP_UPDATE_STATE="$T/state" MCP_CONFIG_FILE="$T/b9-nofork" MCP_LIB_DIR="$T/mislib" MCP_REGISTERED_LIB="$LIVE_LIB"
expect "B9a fork-less checkout, no .fork= -> checkout (no shape-mismatch)" 10 $'fathom-mcp\tmissing' $'fathom-mcp\tshape-mismatch'
# B9b: same root=, but .fork= promotes the resolved shape to fork; a bare git init
# with only 'origin' (never fetched — check_fork's remote check returns before
# needing any real refs) stands in for "a checkout that predates the fork" —
# hermetic, never a real checkout under ~/Code or ~/<name>.
mkdir -p "$T/broot/fathom-mcp"; git -C "$T/broot/fathom-mcp" init -q -b main
git -C "$T/broot/fathom-mcp" remote add origin "https://github.com/davidianstyle/fathom-mcp.git"
printf 'root=%s\nfathom-mcp.fork=https://github.com/someoneelse/fathom-mcp.git\n' "$T/broot" > "$T/b9-fork"
run "${REAL[@]}" MCP_UPDATE_STATE="$T/state" MCP_CONFIG_FILE="$T/b9-fork" MCP_LIB_DIR="$T/mislib" MCP_REGISTERED_LIB="$LIVE_LIB"
expect "B9b .fork= set, resolved shape=fork, remote missing on disk -> shape-mismatch (read-only checker never adds it)" 10 $'fathom-mcp\tshape-mismatch' -
printf 'sometimes\n' > "$T/badpolicy"
run "${REAL[@]}" MCP_UPDATE_STATE="$T/state" MCP_CONFIG_FILE="$T/badpolicy"
expect "B10 bare-word policy line -> bad-policy, never a mode" 10 $'bad-policy.*sometimes.*not a key=value' '=sometimes'

echo "== C. scratch monorepo fixture (checkout shape, sub=packages/a) — engine: mcp-local-build.sh --checkout"
F="$T/fx"; mkdir -p "$F/seed" "$F/lib"
git -C "$F/seed" init -q -b main
mkdir -p "$F/seed/packages/a/src" "$F/seed/packages/b/src"
# mk_server <file> <tools-json> — a dependency-free stdio MCP stub
mk_server(){
  cat > "$1" <<JS
const TOOLS = $2;
if (process.argv.includes("--help")) { console.log("Usage: stub [options]\\n  --slug <s>"); process.exit(0); }
const rl = require("readline").createInterface({ input: process.stdin });
const out = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
rl.on("line", (l) => { let m; try { m = JSON.parse(l); } catch { return; }
  if (m.method === "initialize") out(m.id, { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "stub", version: "0" } });
  else if (m.method === "tools/list") out(m.id, { tools: TOOLS }); });
JS
}
T1='[{"name":"t1","inputSchema":{"type":"object","properties":{"x":{},"y":{}},"required":["x"]}}]'
T3_BRK='[{"name":"t1","inputSchema":{"type":"object","properties":{"x":{}},"required":["x"]}},{"name":"t2","inputSchema":{"type":"object","properties":{}}}]'
for p in a b; do
  printf '{"name":"%s","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src/index.js dist/index.js"}}\n' "$p" > "$F/seed/packages/$p/package.json"
  mk_server "$F/seed/packages/$p/src/index.js" "$T1"
done
printf 'dist/\nnode_modules/\npackage-lock.json\n' > "$F/seed/.gitignore"
printf '{"name":"root","private":true}\n' > "$F/seed/package.json"
commit "$F/seed" init
git clone -q --bare "$F/seed" "$F/origin"
git clone -q "$F/origin" "$F/work"
cp "$VLIB/_mcp-decl.sh" "$F/lib/"
decl_line(){ printf '# openbrain-mcp: shape=checkout dir=%s sub=packages/a url=%s' "$F/work" "$F/origin"; }
set_decl(){ printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$(decl_line)" > "$F/lib/a-mcp.sh"; }
set_decl
printf '{"mcpServers":{"a":{"type":"stdio","command":"%s/lib/a-mcp.sh","args":[]}}}\n' "$F" > "$F/claude.json"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n' > "$F/ps.txt"
FX=(MCP_LIB_DIR="$F/lib" MCP_REGISTERED_LIB="$F/lib" MCP_CLAUDE_JSON="$F/claude.json" OPENBRAIN_VAULT=/nonexistent
    MCP_NO_FETCH=1 MCP_PS_FILE="$F/ps.txt" OPENBRAIN_UPDATE_SNOOZE="$T/snooze" MCP_UPDATE_STATE="$T/fxstate" MCP_CONFIG_FILE="$T/fxpolicy"
    MCP_CHECKOUT_BUILD_CMD="npm run build --silent && npm run test --if-present --silent")
marker(){ cat "$F/work/packages/a/dist/.built-from" 2>/dev/null; }
push_a(){ mk_server "$F/other/packages/a/src/index.js" "$1"; commit "$F/other" "$2"; git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin; }

run "${FX[@]}"
expect "C1 never built -> no-dist"                           10 $'a-mcp\tno-dist' -
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
expect "C2 --apply builds via the engine + says restart"      0 'applied.*restart Claude Code to apply' -
[ "$(marker)" = "$(git -C "$F/work" rev-parse HEAD)" ] && ok "C2b marker == HEAD" || no "C2b marker"
run "${FX[@]}"
expect "C3 fresh build -> CLEAN (exit 0)"                     0 'checked.1 program' '^(mcp|cannot)'
printf 'console.log("b v2")\n' > "$F/work/packages/b/src/index.js"; commit "$F/work" "sibling change"; git -C "$F/work" push -q origin main
run "${FX[@]}"
expect "C4 sibling-package commit -> still CLEAN"             0 - '^(mcp|cannot)'
printf '\n// a v2\n' >> "$F/work/packages/a/src/index.js"; commit "$F/work" "a change"
run "${FX[@]}"
expect "C5 own-package commit -> dist-stale"                  10 $'a-mcp\tdist-stale' -
expect "C5b ...and unpushed"                                  10 $'a-mcp\tunpushed' -
git -C "$F/work" push -q origin main
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
run "${FX[@]}"
expect "C6 rebuilt -> CLEAN"                                  0 - '^(mcp|cannot)'
git clone -q "$F/origin" "$F/other"
push_a "$T1" "upstream a (no tool change)"
run "${FX[@]}"
expect "C7 origin moved on own package -> source-behind"      10 $'a-mcp\tsource-behind' -
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
run "${FX[@]}"
expect "C8 --apply ff-pulls + rebuilds -> CLEAN"              0 - '^(mcp|cannot)'
printf 'x\n' >> "$F/work/packages/a/src/index.js"
run "${FX[@]}"
expect "C9 dirty package source -> dirty-tree"                10 $'a-mcp\tdirty-tree' -
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
expect "C9b --apply refuses over dirty source"                1 'uncommitted changes' 'applied'
git -C "$F/work" checkout -q -- packages/a/src/index.js
git -C "$F/work" switch -q -c spike
run "${FX[@]}"
expect "C10 branch switched under live server -> off-branch"  10 $'a-mcp\toff-branch' -
git -C "$F/work" switch -q main
good="$(marker)"; printf 'deadbeef\n' > "$F/work/packages/a/dist/.built-from"
run "${FX[@]}"
expect "C11 garbage provenance -> unproven-build"             10 $'a-mcp\tunproven-build' -
printf '%s\n' "$good" > "$F/work/packages/a/dist/.built-from"
printf '\nthrow new Error("broken")\n' > "$F/other/packages/a/src/index.js.bad"
( cd "$F/other" && cp packages/a/package.json /tmp/pkg.$$ && printf '{"name":"a","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src/index.js dist/index.js","test":"exit 1"}}\n' > packages/a/package.json )
commit "$F/other" "a: failing tests"; git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin
before="$(marker)"
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
expect "C12 failing tests -> apply fails, last-good kept"     1 'failed' 'applied'
[ "$(marker)" = "$before" ] && [ -f "$F/work/packages/a/dist/index.js" ] && ok "C12b previous dist + marker restored" || no "C12b last-good"
cp /tmp/pkg.$$ "$F/other/packages/a/package.json"; rm -f /tmp/pkg.$$ "$F/other/packages/a/src/index.js.bad"; commit "$F/other" "a: tests fixed"; git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?
expect "C12c tests fixed -> applies"                          0 'applied' -

echo "== E. update policy (per-MCP auto | ask; default ask; invalid screams)"
failing_tests(){ printf '{"name":"a","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src/index.js dist/index.js","test":"exit %s"}}\n' "$1" > "$F/other/packages/a/package.json"; }
printf 'a-mcp.update=auto\n' > "$T/fxpolicy"
push_a "$T3_BRK" "a: drop param y"
old="$(marker)"; runa "${FX[@]}"
expect "E1 auto + passing tests -> applied + restart notice, re-check CLEAN" 0 $'act\ta-mcp\tapplied.*restart Claude Code to apply' $'\t(held|failed)\t|^(mcp|cannot)\t'
[ "$(marker)" = "$(git -C "$F/work" rev-parse HEAD)" ] && [ "$(marker)" != "$old" ] && ok "E1b marker advanced" || no "E1b marker advanced"
grep -q $'\ta-mcp\tauto\tapplied\t' "$T/fxstate/applied.log" && ok "E1c apply recorded in applied.log as auto" || no "E1c applied.log"
applied1="$(marker)"
failing_tests 1; printf '\n// v4\n' >> "$F/other/packages/a/src/index.js"; commit "$F/other" "a: failing tests"; git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin
runa "${FX[@]}"
expect "E2 auto + failing tests -> failed, finding stays"      10 $'act\ta-mcp\tfailed.*last-good' $'act\ta-mcp\tapplied'
[ "$(marker)" = "$applied1" ] && [ -f "$F/work/packages/a/dist/index.js" ] && ok "E2b last-good dist + marker kept" || no "E2b last-good marker=$(marker)"
expect "E2c ...and the re-check still reports it"              10 $'a-mcp\t(dist-stale|source-behind)' -
failing_tests 0; commit "$F/other" "a: tests fixed"; git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin
runa "${FX[@]}"
expect "E3 auto + tests fixed -> applied"                      0 $'act\ta-mcp\tapplied' -
OUT="$(env "${FX[@]}" bash "$CU" --bogus a-mcp 2>&1)"; RC=$?
expect "E4 an unknown flag -> the usage error (exit 2)"        2 '^usage:' -
# E5-E8 need a dist-stale finding to (not) act on: move HEAD past the build without building.
printf '\n// e5-e8\n' >> "$F/other/packages/a/src/index.js"; commit "$F/other" "a: upstream moves (E5-E8 fixture)"
git -C "$F/other" push -q origin main; git -C "$F/work" fetch -q origin; git -C "$F/work" merge -q --ff-only origin/main
old="$(marker)"
printf 'a-mcp.update=ask\n' > "$T/fxpolicy"; runa "${FX[@]}"
expect "E5 explicit ask -> never mutates, finding stays"       10 $'a-mcp\tdist-stale' $'^act\t'
: > "$T/fxpolicy"; runa "${FX[@]}"
expect "E6 no line for the MCP -> default ask, never mutates"  10 $'cov\tpolicy\t.*a-mcp=ask' $'^act\t'
rm -f "$T/fxpolicy"; runa "${FX[@]}"
expect "E6b no policy file at all -> ask"                      10 'no policy file — all ask.*a-mcp=ask' $'^act\t'
[ "$(marker)" = "$old" ] && ok "E6c marker unchanged under ask" || no "E6c"
printf 'a-mcp.update=sometimes\n' > "$T/fxpolicy"; runa "${FX[@]}"
expect "E7 invalid mode -> CANNOT-CHECK (rc 20), never applied"  20 "cannot.a-mcp.update='sometimes'.*refuses to start" $'^act\t'
printf 'a-mcp.update=auto\na-mcp.update=ask\n' > "$T/fxpolicy"; runa "${FX[@]}"
expect "E7b duplicate update lines -> CANNOT-CHECK, never applied" 20 'update set more than once' $'^act\t'
printf 'always\n' > "$T/fxpolicy"; runa "${FX[@]}"
expect "E8 bare 'always' line -> bad-policy, NOT auto"     10 'bad-policy.*always.*not a key=value' $'^act\t'
printf 'a-mcp.updat=auto\nzz-mcp.update=auto\n' > "$T/fxpolicy"; runa "${FX[@]}"
expect "E8b typo'd update key -> bad-policy, NOT auto"         10 'bad-policy.*a-mcp.updat: unknown setting' $'^act\t'
expect "E8c update for a launcher that does not exist -> bad-policy" 10 'bad-policy.*zz-mcp.update: no launcher' -
[ "$(marker)" = "$old" ] && ok "E8d marker unchanged through E5-E8" || no "E8d"
printf 'a-mcp.update=auto\n' > "$T/fxpolicy"
printf '\n// local\n' >> "$F/work/packages/a/src/index.js"; commit "$F/work" "local only"
runa "${FX[@]}"
expect "E9 auto but unpushed local work -> held, not applied"  10 $'held\tnot auto-applied' $'act\ta-mcp\tapplied'
git -C "$F/work" reset -q --hard origin/main
OUT="$(env "${FX[@]}" bash "$CU" --apply a-mcp 2>&1)"; RC=$?   # settle for the next sections
# npm policy
N="$T/npm"; mkdir -p "$N/lib" "$N/_npx/abc123/node_modules/@x/y" "$N/_npx/abc123/node_modules/.bin"
cp "$VLIB/_mcp-decl.sh" "$N/lib/"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=npm pkg=@x/y\nexit 0\n' > "$N/lib/y-mcp.sh"
printf '{"mcpServers":{"y":{"type":"stdio","command":"%s/lib/y-mcp.sh","args":[]}}}\n' "$N" > "$N/claude.json"
printf '#!/bin/sh\n[ "$3" = version ] && echo "$FAKE_LATEST"; [ "$3" = gitHead ] && echo ""; exit 0\n' > "$N/npm"; chmod +x "$N/npm"
printf '{"name":"@x/y","version":"0.1.0"}\n' > "$N/_npx/abc123/node_modules/@x/y/package.json"
touch -t 202601010000 "$N/_npx/abc123/node_modules/@x/y/package.json"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 77 Thu Sep 24 11:21:36 2026     node %s/_npx/abc123/node_modules/.bin/y\n' "$N" > "$N/ps.txt"
NX=(MCP_LIB_DIR="$N/lib" MCP_REGISTERED_LIB="$N/lib" MCP_CLAUDE_JSON="$N/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NPM="$N/npm"
    MCP_PS_FILE="$N/ps.txt" MCP_UPDATE_STATE="$T/nstate" MCP_CONFIG_FILE="$T/npolicy" MCP_NETWORK=1)
: > "$T/npolicy"
run "${NX[@]}" FAKE_LATEST=0.1.0
expect "E10 npm, ask, nothing applied -> unpinned (launcher floats)" 10 $'y-mcp\tunpinned' -
OUT="$(env "${NX[@]}" FAKE_LATEST=0.1.0 bash "$CU" --apply y-mcp 2>&1)"; RC=$?
expect "E11 npm --apply pins latest + restart notice"     0 'pinned 0.1.0.*restart Claude Code to apply' -
run "${NX[@]}" FAKE_LATEST=0.1.0
expect "E12 npm pinned + current -> CLEAN"                    0 $'procs\ty-mcp: 1 running, 0 stale' '^(mcp|cannot)'
run "${NX[@]}" FAKE_LATEST=0.1.1
expect "E13 ask + newer publish -> update-available (no semver judgement)" 10 $'y-mcp\tupdate-available.*0.1.0 -> 0.1.1' 'BREAKING'
runa "${NX[@]}" FAKE_LATEST=0.2.0
expect "E14 ask + npm -> never mutates"                        10 $'y-mcp\tupdate-available.*0.1.0 -> 0.2.0' $'^act\t'
printf 'y-mcp.update=auto\n' > "$T/npolicy"
runa "${NX[@]}" FAKE_LATEST=0.2.0
expect "E15 auto + npm stable -> records latest (even a major), no test gate" 10 $'act\ty-mcp\tapplied\tpinned 0.2.0 \\(was 0.1.0\\)' $'y-mcp\tupdate-available'
expect "E15b ...and the session still on 0.1.0 is flagged stale" 10 $'y-mcp\tstale-process' -
rm "$T/nstate/y-mcp.applied"; runa "${NX[@]}" FAKE_LATEST=0.2.1
expect "E15c auto + unpinned -> pins latest"                   10 $'act\ty-mcp\tapplied\tpinned 0.2.1 \\(was unpinned\\)' $'y-mcp\tunpinned'
( export MCP_UPDATE_STATE="$T/nstate" MCP_CONFIG_FILE="$T/npolicy"; . "$VLIB/_mcp-decl.sh"
  a="$(mcp_npm_spec "$N/lib/y-mcp.sh")"; printf 'y-mcp.update=ask\n' > "$T/npolicy"; b="$(mcp_npm_spec "$N/lib/y-mcp.sh")"
  rm "$T/nstate/y-mcp.applied"; u="$(mcp_npm_spec "$N/lib/y-mcp.sh")"
  [ "$a|$b|$u" = "@x/y@0.2.1|@x/y@0.2.1|@x/y" ] ) && ok "E16 launcher npx spec: exact pin in either mode; bare only when nothing applied" || no "E16 npm spec"

echo "== F. stale-process detection (incl. false-negative direction)"
E="$F/work/packages/a/dist/index.js"; M="$F/work/packages/a/dist/.built-from"
touch -t 202609240900 "$M"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 10 Wed Sep 23 20:03:40 2026     node %s --slug x\n 11 Thu Sep 24 11:21:31 2026     node %s --slug y\n' "$E" "$E" > "$T/ps-mixed.txt"
run "${FX[@]}" MCP_PS_FILE="$T/ps-mixed.txt"
expect "F1 process started before the build -> stale-process (restart)" 10 $'a-mcp\tstale-process.*restart Claude Code to apply.*1 of 2' -
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 11 Thu Sep 24 11:21:31 2026     node %s --slug y\n' "$E" > "$T/ps-fresh.txt"
run "${FX[@]}" MCP_PS_FILE="$T/ps-fresh.txt"
expect "F2 process started after the build -> not stale"      "$RC" $'procs\ta-mcp: 1 running, 0 stale' 'stale-process'
touch -t 202609241200 "$M"
run "${FX[@]}" MCP_PS_FILE="$T/ps-fresh.txt"
expect "F3 break it: rebuild lands after the process started -> must flag" 10 $'a-mcp\tstale-process' -
OUT="$(env "${FX[@]}" MCP_PS_FILE="$T/ps-fresh.txt" bash "$CU" --check 2>&1)"; RC=$?
expect "F4 --check (local, no network) surfaces it too"        10 'MCP updates' -
: > "$T/ps-empty.txt"
run "${FX[@]}" MCP_PS_FILE="$T/ps-empty.txt"
expect "F5 empty process list -> CANNOT-CHECK, never '0 stale'" 20 'ps failed' '0 stale'
# an entry path with a space in it (root= under a folder like "My Code") is still matched
SP="$T/sp"; mkdir -p "$SP/lib" "$SP/my code"; cp "$VLIB/_mcp-decl.sh" "$SP/lib/"
git clone -q "$F/origin" "$SP/my code/hp"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=hp sub=packages/a url=%s\nexit 0\n' "$F/origin" > "$SP/lib/hp-mcp.sh"
printf 'root=%s\n' "$SP/my code" > "$SP/cfg"
printf '{"mcpServers":{"hp":{"type":"stdio","command":"%s/lib/hp-mcp.sh","args":[]}}}\n' "$SP" > "$SP/claude.json"
SPX=(MCP_LIB_DIR="$SP/lib" MCP_REGISTERED_LIB="$SP/lib" MCP_CLAUDE_JSON="$SP/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NO_FETCH=1
     MCP_UPDATE_STATE="$SP/state" MCP_CONFIG_FILE="$SP/cfg" MCP_CHECKOUT_BUILD_CMD="npm run build --silent")
OUT="$(env "${SPX[@]}" bash "$CU" --apply hp-mcp 2>&1)"; RC=$?
touch -t 202609241200 "$SP/my code/hp/packages/a/dist/.built-from"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 12 Wed Sep 23 20:03:40 2026     node %s --slug x\n' "$SP/my code/hp/packages/a/dist/index.js" > "$SP/ps.txt"
run "${SPX[@]}" MCP_PS_FILE="$SP/ps.txt"
expect "F6 entry path with a space: a process started before the build -> stale-process (never read as clean)" 10 $'hp-mcp\tstale-process.*1 of 1' -

echo "== D. launcher helpers (live _common.sh) — fake HOME, dummy .env; lazy clone preserved"
H="$T/home"; mkdir -p "$H/.config/openbrain/lib"; : > "$H/.config/openbrain/.env"
cp "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$H/.config/openbrain/lib/"
mklauncher(){  # mklauncher <file> <decl-line>
  cat > "$1" <<EOF
#!/usr/bin/env bash
$2
set -euo pipefail
source "\$(dirname "\${BASH_SOURCE[0]}")/_common.sh"
ensure_mcp_server
exec node "\$(declared_entry)" --help
EOF
  chmod 755 "$1"
}
rm -rf "$F/work/packages/a/dist"
mklauncher "$H/.config/openbrain/lib/a-mcp.sh" "$(decl_line)"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/a-mcp.sh" 2>&1)"; RC=$?
expect "D1 missing dist -> self-heals, then runs the declared entry" 0 'Usage: stub' -
[ -s "$F/work/packages/a/dist/.built-from" ] && ok "D1b self-heal wrote provenance" || no "D1b"
OUT="$(HOME="$H" zsh -c "bash '$H/.config/openbrain/lib/a-mcp.sh'" 2>&1)"; RC=$?
expect "D2 same launcher invoked from zsh"                     0 'Usage: stub' -
mklauncher "$H/.config/openbrain/lib/c-mcp.sh" "# openbrain-mcp: shape=checkout dir=$T/lazy-mono sub=packages/a url=$F/origin"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/c-mcp.sh" 2>&1)"; RC=$?
expect "D3 checkout absent -> LAZY CLONE + build on first launch" 0 'Usage: stub' -
printf '%s\n' "$OUT" | grep -q 'openbrain mcp: cloning' && ok "D3c ...by cloning url=" || no "D3c clone"
[ -d "$T/lazy-mono/.git" ] && [ -s "$T/lazy-mono/packages/a/dist/.built-from" ] && ok "D3b cloned from url= and recorded provenance" || no "D3b"
git clone -q --bare "$F/origin" "$T/forkish.git" 2>/dev/null
( cd "$T" && git clone -q forkish.git forkseed && cd forkseed && git mv packages/a/src src 2>/dev/null; cp packages/a/package.json package.json; git add -A; git -c user.name=t -c user.email=t@t commit -qm flat; git push -q origin HEAD:main )
# Contributing-fork remote: a bare clone of origin, plus one feat/* branch — proves
# the fork engine actually merges it into local-build (not just "builds something").
git clone -q --bare "$T/forkish.git" "$T/forkish-fork.git"
( cd "$T" && git clone -q forkish-fork.git ffseed && cd ffseed && git checkout -q -b feat/marker \
  && printf '\n// feat/marker\n' >> src/index.js && git -c user.name=t -c user.email=t@t commit -qam marker \
  && git push -q origin feat/marker )
# (a) PRE-EXISTING checkout (already cloned from origin, dist never built) + .fork=
# resolves the shape to fork -> lazy build must run the FORK ENGINE (not --checkout),
# add the missing fork remote, and merge feat/* into local-build. Must not refuse.
mkdir -p "$T/droot"; git clone -q "$T/forkish.git" "$T/droot/f2-mcp"
printf 'root=%s\nf2-mcp.fork=file://%s\n' "$T/droot" "$T/forkish-fork.git" > "$H/.config/openbrain/mcp-config"
mklauncher "$H/.config/openbrain/lib/f2-mcp.sh" "# openbrain-mcp: shape=checkout dir=f2-mcp url=$T/forkish.git"
OUT="$(HOME="$H" MCP_BUILD_CMD='npm run build --silent' bash "$H/.config/openbrain/lib/f2-mcp.sh" 2>&1)"; RC=$?
expect "D4a pre-existing fork checkout, dist missing -> builds local-build (does not refuse)" 0 'Usage: stub' 'needs exactly one|no .fork. remote'
[ "$(git -C "$T/droot/f2-mcp" symbolic-ref -q --short HEAD)" = local-build ] && ok "D4a2 ...on local-build" || no "D4a2 branch"
f2log="$(git -C "$T/droot/f2-mcp" log local-build --oneline)"; printf '%s\n' "$f2log" | grep -q marker && ok "D4a3 ...feat/marker merged" || no "D4a3 merge"
[ "$(git -C "$T/droot/f2-mcp" remote | grep -c '^fork$')" = 1 ] && ok "D4a4 ...fork remote added" || no "D4a4 remote"
# (b) FIRST INSTALL — nothing on disk yet, .fork= set from the start -> clones
# origin, adds the fork remote, builds local-build with feat/* merged, ends with
# BOTH remotes present.
printf 'root=%s\nf3-mcp.fork=file://%s\n' "$T/droot" "$T/forkish-fork.git" > "$H/.config/openbrain/mcp-config"
mklauncher "$H/.config/openbrain/lib/f3-mcp.sh" "# openbrain-mcp: shape=checkout dir=f3-mcp url=$T/forkish.git"
OUT="$(HOME="$H" MCP_BUILD_CMD='npm run build --silent' bash "$H/.config/openbrain/lib/f3-mcp.sh" 2>&1)"; RC=$?
expect "D4b first install with .fork= set -> lazy-clones + builds (ensure_mcp_server semantics kept)" 0 'Usage: stub' 'needs exactly one|no .fork. remote'
printf '%s\n' "$OUT" | grep -q 'openbrain mcp: cloning' && ok "D4b2 ...by cloning url=" || no "D4b2 clone"
[ "$(git -C "$T/droot/f3-mcp" symbolic-ref -q --short HEAD)" = local-build ] && ok "D4b3 ...ends on local-build" || no "D4b3 branch"
f3log="$(git -C "$T/droot/f3-mcp" log local-build --oneline)"; printf '%s\n' "$f3log" | grep -q marker && ok "D4b4 ...feat/marker merged" || no "D4b4 merge"
f3remotes="$(git -C "$T/droot/f3-mcp" remote | sort | tr '\n' ' ')"
[ "$f3remotes" = "fork origin " ] && ok "D4b5 ...ends with BOTH origin+fork remotes" || no "D4b5 remotes: $f3remotes"
rm -f "$H/.config/openbrain/mcp-config"
sedi '2d' "$H/.config/openbrain/lib/a-mcp.sh"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/a-mcp.sh" 2>&1)"; RC=$?
expect "D5 launcher with its declaration removed dies loudly"  1 "needs exactly one" -
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "npx $*"\n' > "$T/fakebin/npx"; chmod +x "$T/fakebin/npx"
cat > "$H/.config/openbrain/lib/n-mcp.sh" <<'EOF'
#!/usr/bin/env bash
# openbrain-mcp: shape=npm pkg=@x/n
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
exec_declared_npm
EOF
mkdir -p "$H/.config/openbrain/mcp-updates"; printf '1.2.3\n' > "$H/.config/openbrain/mcp-updates/n-mcp.applied"
OUT="$(HOME="$H" PATH="$T/fakebin:$PATH" bash "$H/.config/openbrain/lib/n-mcp.sh" 2>&1)"; RC=$?
expect "D6 npm launcher execs the last-applied pin"                0 'npx --yes @x/n@1.2.3$' -
printf 'n-mcp.update=sometimes\n' > "$H/.config/openbrain/mcp-config"
OUT="$(HOME="$H" PATH="$T/fakebin:$PATH" bash "$H/.config/openbrain/lib/n-mcp.sh" 2>&1)"; RC=$?
expect "D7 invalid update mode -> npm launcher refuses to start" 1 "update='sometimes'.*use auto or ask" 'npx '
printf 'c-mcp.update=bogus\n' > "$H/.config/openbrain/mcp-config"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/c-mcp.sh" 2>&1)"; RC=$?
expect "D7b invalid update mode -> checkout launcher refuses to start" 1 "update='bogus'" 'Usage: stub'
printf 'c-mcp.update=auto\n' > "$H/.config/openbrain/mcp-config"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/c-mcp.sh" 2>&1)"; RC=$?
expect "D7c valid auto -> launcher starts"                     0 'Usage: stub' -
rm -f "$H/.config/openbrain/mcp-config"

echo "== G. mcp-local-build.sh fork mode (live engine, launcher-path argument) — tests gate, last-good kept"
G="$T/g"; mkdir -p "$G" "$G/lib"
cp "$VLIB/_mcp-decl.sh" "$G/lib/"
git init -q -b main "$G/up"; printf '{"name":"g","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$G/up/package.json"
printf 'console.log(1)\n' > "$G/up/src.js"; printf 'dist/\n' > "$G/up/.gitignore"; commit "$G/up" init
git clone -q --bare "$G/up" "$G/fork.git"; git clone -q "$G/up" "$G/home/gmcp"; git -C "$G/home/gmcp" remote add fork "$G/fork.git"
git -C "$G/home/gmcp" fetch -q fork
# dir= absolute (an explicit escape hatch — this fixture isn't under any root=)
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$G/home/gmcp" "$G/fork.git" > "$G/lib/gmcp-mcp.sh"
OUT="$(MCP_BUILD_CMD='npm run build --silent' bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G1 fork engine builds local-build + marker"           0 'OK — built' -
good="$(cat "$G/home/gmcp/dist/.built-from")"
git -C "$G/home/gmcp" checkout -q main
OUT="$(MCP_BUILD_CMD='npm run build --silent && false' bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G2 failing test step -> dies, previous dist restored" 1 'restored the previous dist' -
[ "$(cat "$G/home/gmcp/dist/.built-from")" = "$good" ] && ok "G2b last-good marker intact" || no "G2b"
# G3: corrupt the LAUNCHER's directory copy of _mcp-decl.sh (simulating a stale
# installed-style copy sitting next to an installed launcher) — the engine must
# still succeed, because it loads its OWN copy beside itself (mcp-local-build.sh
# in the vault), never the launcher's directory. Loading the launcher-dir copy
# would die with a bare `mcp_get: command not found` (rc 127).
printf '#!/usr/bin/env bash\n# stale — deliberately lacks mcp_get/mcp_shape\n' > "$G/lib/_mcp-decl.sh"
rm -rf "$G/home/gmcp/dist"
OUT="$(MCP_BUILD_CMD='npm run build --silent' bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G3 engine loads the parser beside ITSELF — a stale launcher-dir copy never reached (no rc 127)" 0 'OK — built' 'command not found'
# G4–G7: the hand-commit guard. local-build is derived; a hand commit on it must refuse
# (never drop silently), while the engine's own merge commits and a since-deleted
# feat/*'s commits must NOT trip it (false-positive direction — rebuilding drops those
# by design). Fixture state is read with MCP_SKIP_FETCH=1 after an explicit prune.
cp "$VLIB/_mcp-decl.sh" "$G/lib/"   # undo G3's deliberate corruption
GH="$G/home/gmcp"; GB='npm run build --silent'
git clone -q "$G/fork.git" "$G/fw"; git -C "$G/fw" checkout -q -b feat/a; printf 'a\n' > "$G/fw/a.txt"; commit "$G/fw" feat-a
git -C "$G/fw" push -q origin feat/a; git -C "$GH" fetch -q --prune fork
OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G4 feat/a integrated (engine merge commit on local-build)" 0 'OK — built' 'in neither'
OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G5 rebuild over the engine's own merge commit -> no false refusal" 0 'OK — built' 'in neither'
git -C "$G/fw" push -q origin --delete feat/a; git -C "$GH" fetch -q --prune fork
OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G6 deleted feat/a -> rebuild drops it, no false refusal" 0 'OK — built' 'in neither'
[ ! -f "$GH/a.txt" ] && ok "G6b deleted feature is out of local-build" || no "G6b a.txt still present"
# G8: the engine's OWN fetch must prune — without it a feat/* deleted on the fork lingers as a
# stale remote-tracking ref and stays in local-build on every machine that ever fetched it.
# Hermetic git config: a machine-wide fetch.prune=true would mask the defect.
printf '[user]\n\tname = t\n\temail = t@t\n' > "$G/gitconfig"
git -C "$G/fw" checkout -q -b feat/b main; printf 'b\n' > "$G/fw/b.txt"; commit "$G/fw" feat-b; git -C "$G/fw" push -q origin feat/b
OUT="$(GIT_CONFIG_GLOBAL="$G/gitconfig" MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G8a feat/b integrated via the engine's own fetch" 0 'OK — built' -
git -C "$G/fw" push -q origin --delete feat/b
OUT="$(GIT_CONFIG_GLOBAL="$G/gitconfig" MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G8b deleted on the fork -> the engine's fetch prunes it" 0 'OK — built' 'fork/feat/b'
[ ! -f "$GH/b.txt" ] && ok "G8c deleted feature is out of local-build (no manual prune)" || no "G8c b.txt still present — fetch did not prune"
git -C "$GH" checkout -q local-build; printf 'h\n' > "$GH/hand.txt"; commit "$GH" hand-msg-ZQX9
gbr="$(git -C "$GH" symbolic-ref --short HEAD)"; ghd="$(git -C "$GH" rev-parse HEAD)"; grl="$(git -C "$GH" reflog local-build | wc -l)"
OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "$ENGINE" "$G/lib/gmcp-mcp.sh" 2>&1)"; RC=$?
expect "G7 hand commit on local-build -> refuses, names count + short sha" 1 "1 commit\(s\) in neither.*\(${ghd:0:7}\)" 'OK — built'
printf '%s\n' "$OUT" | LC_ALL=C grep -q "$(git -C "$GH" log -1 --format=%s)" && no "G7b refusal leaks the commit message" || ok "G7b refusal shows no commit message"
[ "$(git -C "$GH" symbolic-ref --short HEAD)" = "$gbr" ] && [ "$(git -C "$GH" rev-parse HEAD)" = "$ghd" ] && [ "$(git -C "$GH" reflog local-build | wc -l)" = "$grl" ] \
  && ok "G7c branch, HEAD and reflog unchanged by the refusal" || no "G7c the refusal moved something"
# G9–G12: two feat/* branches appending to the same file's tail conflict. The engine must
# abort the merge and put local-build (and HEAD) back, leaving dist/ + .built-from alone —
# else its own dirty-tree refusal blocks every later rebuild. Own fixture (G7 left $GH dirty).
C="$T/gc"; mkdir -p "$C/lib"; cp "$VLIB/_mcp-decl.sh" "$C/lib/"
git init -q -b main "$C/up"; cp "$G/up/package.json" "$G/up/src.js" "$G/up/.gitignore" "$C/up/"
printf 'base\n' > "$C/up/tail.txt"; commit "$C/up" init
git clone -q --bare "$C/up" "$C/fork.git"; CH="$C/home/cmcp"; git clone -q "$C/up" "$CH"; git -C "$CH" remote add fork "$C/fork.git"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$CH" "$C/fork.git" > "$C/lib/cmcp-mcp.sh"
git clone -q "$C/fork.git" "$C/fw"
cfeat(){ git -C "$C/fw" checkout -q -B "$1" "$2"; printf '%s\n' "$3" >> "$C/fw/tail.txt"; commit "$C/fw" "$1"; git -C "$C/fw" push -q -f origin "$1"; git -C "$CH" fetch -q --prune fork; }
cbuild(){ OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "${1:-$ENGINE}" "$C/lib/cmcp-mcp.sh" 2>&1)"; RC=$?; }
cclean(){ [ -z "$(git -C "$CH" status --porcelain)" ] && ! git -C "$CH" rev-parse -q --verify MERGE_HEAD >/dev/null; }
cfeat feat/x main x; cbuild
expect "G9a feat/x alone builds (the prior good local-build)" 0 'OK — built' -
lb0="$(git -C "$CH" rev-parse local-build)"; bf0="$(cat "$CH/dist/.built-from")"
# advance feat/x (another file) so a rebuild can never reproduce lb0 — G9d stays non-vacuous
printf 'x2\n' > "$C/fw/x2.txt"; commit "$C/fw" x2; git -C "$C/fw" push -q origin feat/x; git -C "$CH" fetch -q fork
cfeat feat/y main y; cbuild
expect "G9b conflicting feat/y -> dies naming both branches + the file" 1 'merge conflict integrating fork/feat/y with fork/feat/x \(conflicted: tail\.txt\)' 'OK — built'
cclean && ok "G9c ...merge aborted, git status clean" || no "G9c checkout left mid-merge: $(git -C "$CH" status --porcelain | tr '\n' ' ')"
[ "$(git -C "$CH" rev-parse local-build)" = "$lb0" ] && [ "$(git -C "$CH" symbolic-ref -q HEAD)" = refs/heads/local-build ] \
  && ok "G9d ...local-build back at its prior sha, still checked out" || no "G9d local-build/HEAD moved"
[ "$(cat "$CH/dist/.built-from")" = "$bf0" ] && [ -f "$CH/dist/index.js" ] && ok "G9e ...dist/ + .built-from untouched" || no "G9e dist changed"
cbuild
expect "G9f re-run is not blocked by the dirty-tree refusal (same conflict, reported again)" 1 'merge conflict integrating fork/feat/y' 'uncommitted changes'
# G10: no local-build yet + HEAD on main (first build) -> back on main, partial local-build deleted.
git -C "$CH" checkout -q main; git -C "$CH" branch -q -D local-build; cbuild
expect "G10a first-build conflict -> dies" 1 'merge conflict integrating fork/feat/y.*restored to its prior absence' 'OK — built'
cclean && [ "$(git -C "$CH" symbolic-ref -q HEAD)" = refs/heads/main ] && ! git -C "$CH" rev-parse -q --verify refs/heads/local-build >/dev/null \
  && ok "G10b ...clean, back on main, no partial local-build left" || no "G10b state not restored"
# G11: mutation control — the live engine with its abort neutralised must leave the
# checkout mid-merge, proving G9c/G10b can go red.
mkdir -p "$C/mut"; cp "$VLIB/_mcp-decl.sh" "$C/mut/"
sed 's/git -C "\$DIR" merge --abort/true/' "$ENGINE" > "$C/mut/mcp-local-build.sh"
[ "$(grep -c 'merge --abort' "$C/mut/mcp-local-build.sh" || true)" = "$(($(grep -c 'merge --abort' "$ENGINE") - 1))" ] \
  || { echo "FIXTURE BUG: G11 mutation did not land" >&2; exit 90; }
cbuild "$C/mut/mcp-local-build.sh"
[ "$RC" != 0 ] && ! cclean && ok "G11 mutant without the abort leaves the checkout mid-merge (the checks can fail)" || no "G11 mutant stayed clean — G9c/G10b are vacuous"
git -C "$CH" merge --abort; git -C "$CH" checkout -q main; git -C "$CH" branch -q -D local-build
# G13 (pair of G10): local-build PRE-EXISTS but HEAD is on main -> it must be restored, never
# deleted (the delete keys only on the pre-run record). G13m: unconditional-delete mutant -> red.
lbm="$(git -C "$CH" rev-parse main)"; git -C "$CH" branch -q local-build main; cbuild
expect "G13a pre-existing local-build, HEAD on main, conflict -> dies" 1 "restored to ${lbm:0:7}" 'OK — built'
cclean && [ "$(git -C "$CH" symbolic-ref -q HEAD)" = refs/heads/main ] && [ "$(git -C "$CH" rev-parse -q --verify local-build)" = "$lbm" ] \
  && ok "G13b ...local-build restored (not deleted), back on main, clean" || no "G13b local-build deleted or moved"
sed 's/if \[ -z "\$prev_lb" \]; then/if true; then/' "$ENGINE" > "$C/mut/mcp-local-build.sh"
[ "$(grep -c 'if true; then' "$C/mut/mcp-local-build.sh" || true)" = 1 ] || { echo "FIXTURE BUG: G13m mutation did not land" >&2; exit 90; }
cbuild "$C/mut/mcp-local-build.sh"
! git -C "$CH" rev-parse -q --verify local-build >/dev/null && ok "G13m unconditional-delete mutant deletes it (G13b can fail)" || no "G13m mutant kept local-build — G13b is vacuous"
git -C "$CH" branch -q -f local-build main
# G14: detached HEAD at start (a sha distinct from local-build's) -> returned to that same
# detached sha; local-build restored. G14m: a restore that detaches at local-build -> red.
lbx="$(git -C "$CH" rev-parse fork/feat/x)"; git -C "$CH" branch -q -f local-build "$lbx"
c14(){ cclean && ! git -C "$CH" symbolic-ref -q HEAD >/dev/null && [ "$(git -C "$CH" rev-parse HEAD)" = "$lbm" ] && [ "$(git -C "$CH" rev-parse local-build)" = "$lbx" ]; }
git -C "$CH" checkout -q --detach main; cbuild
expect "G14a detached start, conflict -> dies" 1 'merge conflict integrating fork/feat/y' 'OK — built'
c14 && ok "G14b ...HEAD detached at its original sha, local-build restored, clean" || no "G14b detached start not restored"
sed 's/checkout -q --detach "\$prev_head"/checkout -q --detach local-build/' "$ENGINE" > "$C/mut/mcp-local-build.sh"
[ "$(grep -c 'checkout -q --detach local-build' "$C/mut/mcp-local-build.sh" || true)" = 1 ] || { echo "FIXTURE BUG: G14m mutation did not land" >&2; exit 90; }
cbuild "$C/mut/mcp-local-build.sh"
c14 && no "G14m detach-at-local-build mutant still passes — G14b is vacuous" || ok "G14m detach-at-local-build mutant fails G14b's check"
git -C "$CH" checkout -q main
# G12: resolve in the feature branch (rebase feat/y onto feat/x) -> rebuild is green.
cfeat feat/y origin/feat/x y; cbuild
expect "G12a resolved in the feature branch -> re-run builds" 0 'OK — built' 'conflict'
[ "$(tr '\n' ' ' < "$CH/tail.txt")" = "base x y " ] && [ "$(cat "$CH/dist/.built-from")" = "$(git -C "$CH" rev-parse local-build)" ] && cclean \
  && ok "G12b ...local-build carries x+y, .built-from matches it, tree clean" || no "G12b resolved build state wrong"
# G15–G17 share a fresh-fixture helper: nfix <name> -> $N (root), $NH (checkout), $NF (fork worktree).
nfix(){ N="$T/$1"; NH="$N/home"; NF="$N/fw"; mkdir -p "$N"; git init -q -b main "$N/up"
  cp "$G/up/package.json" "$G/up/src.js" "$G/up/.gitignore" "$N/up/"; printf '1\n2\n3\n4\n5\n' > "$N/up/lines.txt"; commit "$N/up" init
  git clone -q --bare "$N/up" "$N/fork.git"; git clone -q "$N/up" "$NH"; git -C "$NH" remote add fork "$N/fork.git"; git clone -q "$N/fork.git" "$NF"
  printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$NH" "$N/fork.git" > "$N/mcp.sh"; }
nfeat(){ git -C "$NF" checkout -q -B "$1" main; eval "$2"; git -C "$NF" add -A -f; commit "$NF" "$1"; git -C "$NF" push -q origin "$1"; git -C "$NH" fetch -q --prune fork; }
nbuild(){ OUT="$(MCP_SKIP_FETCH=1 MCP_BUILD_CMD="$GB" bash "${1:-$ENGINE}" "$N/mcp.sh" 2>&1)"; RC=$?; }
nclean(){ [ -z "$(git -C "$NH" status --porcelain)" ] && ! git -C "$NH" rev-parse -q --verify MERGE_HEAD >/dev/null; }
# G15: a feat/* that tracks files under dist/ is refused before any merge (dist/ is build output);
# the last-good dist/ is byte-identical afterwards. G15m: the same engine without the check -> red.
nfix gd; nfeat feat/ok 'printf "ok\n" > "$NF/ok.txt"'; nbuild
expect "G15a prior good build" 0 'OK — built' -
d0="$(cat "$NH/dist/index.js")"; bfd="$(cat "$NH/dist/.built-from")"; lbd="$(git -C "$NH" rev-parse local-build)"
nfeat feat/d 'mkdir -p "$NF/dist"; printf "clobber\n" > "$NF/dist/index.js"'; nbuild
expect "G15b feat/d tracks dist/ -> refused, naming branch + path" 1 'fork/feat/d changes dist/ \(dist/index\.js\)' 'OK — built|merge conflict'
[ "$(cat "$NH/dist/index.js")" = "$d0" ] && [ "$(cat "$NH/dist/.built-from")" = "$bfd" ] && [ "$(git -C "$NH" rev-parse local-build)" = "$lbd" ] && nclean \
  && ok "G15c ...dist/index.js + .built-from + local-build untouched, tree clean" || no "G15c dist/local-build disturbed"
sed 's/\[ -z "\$dp" \] || die/true || die/' "$ENGINE" > "$C/mut/mcp-local-build.sh"
[ "$(grep -c 'true || die "\$b changes dist/' "$C/mut/mcp-local-build.sh" || true)" = 1 ] || { echo "FIXTURE BUG: G15m mutation did not land" >&2; exit 90; }
nbuild "$C/mut/mcp-local-build.sh"
printf '%s\n' "$OUT" | grep -q 'changes dist/' && no "G15m mutant without the dist/ check still refuses — G15b is vacuous" || ok "G15m mutant without the dist/ check does not refuse (G15b can fail)"
# G16: a non-conflict merge failure (failing pre-merge-commit hook) is not called a conflict;
# git's own output is relayed, and local-build is restored.
nfix gh; nfeat feat/h1 'printf "h1\n" > "$NF/h1.txt"'; nbuild
expect "G16a prior good build" 0 'OK — built' -
lbh="$(git -C "$NH" rev-parse local-build)"; mkdir -p "$N/hooks"; git -C "$NH" config core.hooksPath "$N/hooks"
printf '#!/bin/sh\necho "HOOK-SAYS-NO" >&2\nexit 1\n' > "$N/hooks/pre-merge-commit"; chmod +x "$N/hooks/pre-merge-commit"; nbuild
expect "G16b hook refuses the merge commit -> 'not a conflict', relays git's output" 1 'merging fork/feat/h1 failed \(not a conflict\).*HOOK-SAYS-NO' 'merge conflict|OK — built'
nclean && [ "$(git -C "$NH" rev-parse local-build)" = "$lbh" ] && ok "G16c ...merge aborted, local-build restored, clean" || no "G16c state not restored"
# G17: the base is the real conflicting side (base appends; feat/a prepends; feat/b appends)
# -> the base is named, not only the already-merged feat/a.
nfix gb; nfeat feat/a 'printf "a\n" | cat - "$NF/lines.txt" > "$NF/l.tmp"; mv "$NF/l.tmp" "$NF/lines.txt"'
nfeat feat/b 'printf "b\n" >> "$NF/lines.txt"'
printf 'B\n' >> "$N/up/lines.txt"; commit "$N/up" base-append; git -C "$NH" fetch -q origin; nbuild
expect "G17 base-side conflict names the base" 1 'merge conflict integrating fork/feat/b with origin/main.*\(conflicted: lines\.txt\)' 'OK — built'

echo "== H. channels (npm shape: stable = npx, canary = source checkout) — live _common.sh/_mcp-decl.sh/engine"
# Fixture: an npm-declared MCP whose source is the scratch monorepo from section C ($F/origin).
H2="$T/chhome"; HL="$H2/.config/openbrain/lib"; mkdir -p "$HL"; : > "$H2/.config/openbrain/.env"
cp "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$HL/"
CM="$T/ch-mono"; CP="$T/chpolicy"
ch_launcher(){  # ch_launcher [replacement for the " url=..." key]
  cat > "$HL/ch-mcp.sh" <<EOF
#!/usr/bin/env bash
# openbrain-mcp: shape=npm pkg=@x/a src=$CM sub=packages/a${1:-" url=$F/origin"}
set -euo pipefail
source "\$(dirname "\${BASH_SOURCE[0]}")/_common.sh"
exec_declared_npm
EOF
  chmod 755 "$HL/ch-mcp.sh"
}
ch_launcher
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
LENV=(HOME="$H2" PATH="$T/fakebin:$PATH" MCP_CONFIG_FILE="$CP" MCP_CHECKOUT_BUILD_CMD="npm run build --silent && npm run test --if-present --silent")
launch(){ OUT="$(printf '%s\n' "$INIT" | env "${LENV[@]}" bash "$HL/ch-mcp.sh" 2>&1)"; RC=$?; }
printf 'ch-mcp.channel=canary\n' > "$CP"
rm -rf "$CM"; launch
expect "H1 canary, no checkout on this machine -> lazy clone + engine build, then node on it" 0 '"name":"stub"' 'npx '
printf '%s\n' "$OUT" | grep -q "cloning $F/origin" && ok "H1b ...cloned from url=" || no "H1b clone"
printf '%s\n' "$OUT" | grep -q 'mcp-local-build: OK' && ok "H1c ...built by mcp-local-build.sh (test gate + provenance)" || no "H1c engine"
[ "$(cat "$CM/packages/a/dist/.built-from" 2>/dev/null)" = "$(git -C "$CM" rev-parse HEAD)" ] && ok "H1d provenance marker == HEAD" || no "H1d marker"
rm -rf "$CM"
for k in 1 2 3; do ( printf '%s\n' "$INIT" | env "${LENV[@]}" bash "$HL/ch-mcp.sh" > "$T/par$k.out" 2>&1 ) & done; wait
if [ "$(cat "$T"/par*.out | grep -c '"name":"stub"')" = 3 ] && [ "$(cat "$T"/par*.out | grep -c 'cloning')" = 1 ]; then
  ok "H2 3 servers first-launched together -> one clone/build (lock), all 3 start"
else no "H2 lock"; cat "$T"/par*.out | sed 's/^/        /'; fi
printf 'ch-mcp.channel=stable\n' > "$CP"; launch
expect "H3 switch canary -> stable: next launch execs npx (policy spec)"   0 'npx --yes @x/a$' '"name":"stub"'
printf 'channel=canary\n' > "$CP"; launch
expect "H4 switch back via machine default channel=canary -> node on the checkout" 0 '"name":"stub"' 'npx '
printf 'ch-mcp.channel=beta\n' > "$CP"; launch
expect "H5 invalid channel -> launcher refuses to start (no silent default)" 1 "channel='beta'.*use stable or canary" '"name":"stub"|npx '
printf 'ch-mcp.channel=canary\nch-mcp.channel=stable\n' > "$CP"; launch
expect "H5b duplicate channel lines -> launcher refuses"                   1 'set more than once' '"name":"stub"|npx '
# checker
printf '{"mcpServers":{"ch":{"type":"stdio","command":"%s/ch-mcp.sh","args":["s"]}}}\n' "$HL" > "$T/chclaude.json"
printf '#!/bin/sh\n[ "$3" = version ] && echo 0.0.1; [ "$3" = gitHead ] && echo "$FAKE_GH"; exit 0\n' > "$T/chnpm"; chmod +x "$T/chnpm"
GH0="$(git -C "$CM" rev-list --max-parents=0 HEAD)"
HX=(MCP_LIB_DIR="$HL" MCP_REGISTERED_LIB="$HL" MCP_CLAUDE_JSON="$T/chclaude.json" OPENBRAIN_VAULT=/nonexistent MCP_PS_FILE="$F/ps.txt"
    MCP_UPDATE_STATE="$T/chstate" MCP_CONFIG_FILE="$CP" MCP_NPM="$T/chnpm" FAKE_GH="$GH0" OPENBRAIN_UPDATE_SNOOZE="$T/chsnooze"
    MCP_CHECKOUT_BUILD_CMD="npm run build --silent && npm run test --if-present --silent")
printf 'ch-mcp.channel=canary\n' > "$CP"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H6 canary, fresh build -> CLEAN, checked as a checkout"            0 $'cov\tchannel\tch-mcp=canary' '^(mcp|cannot)|unpinned'
run "${HX[@]}" MCP_NO_FETCH=1 MCP_NETWORK=1
expect "H7 unreleased vs npm is INFO only (rc stays 0, no finding)"      0 $'^info\tch-mcp\tunreleased vs npm: [1-9][0-9]* commit' '^(mcp|cannot)'
push_a "$T1" "a: upstream moves after the canary build"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H8a origin moved, cached refs only (no fetch) -> not visible yet" 0 - $'ch-mcp\tsource-behind'
OUT="$(env "${HX[@]}" bash "$CU" --report 2>&1)"; RC=$?
expect "H8b --report/--full fetches -> source-behind"                      10 'ch-mcp +source-behind' -
OUT="$(env "${HX[@]}" bash "$CU" --check 2>&1)"; RC=$?
expect "H8c --check line counts findings only, never the unreleased info" 10 'MCP updates — 1 finding' 'unreleased'
runa "${HX[@]}" MCP_NO_FETCH=1
expect "H8d canary does NOT imply auto: no update line -> reported, never applied" 10 $'ch-mcp\tsource-behind' $'^act\t'
OUT="$(env "${HX[@]}" MCP_NO_FETCH=1 bash "$CU" --apply ch-mcp 2>&1)"; RC=$?
expect "H9 --apply on canary -> engine ff-pulls + rebuilds"                0 'ch-mcp: applied.*restart' -
[ "$(cat "$CM/packages/a/dist/.built-from")" = "$(git -C "$CM" rev-parse origin/main)" ] && ok "H9b marker == origin/main" || no "H9b"
printf '\n// wip\n' >> "$CM/packages/a/src/index.js"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H10 canary checkout dirty -> dirty-tree"                           10 $'ch-mcp\tdirty-tree' -
git -C "$CM" -c user.name=t -c user.email=t@t commit -qam "local wip"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H11 local commit on the package -> dist-stale + unpushed"         10 $'ch-mcp\tdist-stale' -
git -C "$CM" reset -q --hard origin/main
CE="$CM/packages/a/dist/index.js"; touch -t 202609241200 "$CM/packages/a/dist/.built-from"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 10 Thu Sep 24 11:00:00 2026     node %s\n' "$CE" > "$T/chps-old.txt"
run "${HX[@]}" MCP_NO_FETCH=1 MCP_PS_FILE="$T/chps-old.txt"
expect "H12 canary process older than the build -> stale-process"          10 $'ch-mcp\tstale-process.*predate' -
mkdir -p "$T/npxc/_npx/f00d/node_modules/@x/a" && printf '{"name":"@x/a","version":"0.0.1"}\n' > "$T/npxc/_npx/f00d/node_modules/@x/a/package.json"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 11 Thu Sep 24 13:00:00 2026     node %s/_npx/f00d/node_modules/.bin/a\n' "$T/npxc" > "$T/chps-npx.txt"
run "${HX[@]}" MCP_NO_FETCH=1 MCP_PS_FILE="$T/chps-npx.txt"
expect "H13 switched to canary, a session still runs npx -> stale-process" 10 'still on the stable channel' -
printf 'ch-mcp.channel=stable\n' > "$CP"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 12 Thu Sep 24 13:00:00 2026     node %s\n' "$CE" > "$T/chps-can.txt"
run "${HX[@]}" MCP_NO_FETCH=1 MCP_PS_FILE="$T/chps-can.txt"
expect "H14 switched to stable, a session still runs canary -> stale-process" 10 'still on the canary channel' -
run "${HX[@]}" MCP_NO_FETCH=1
expect "H15 stable unchanged: npm checks (unpinned under ask), no checkout checks" 10 $'ch-mcp\tunpinned' $'ch-mcp\t(dist-stale|dirty-tree|source-behind|unproven-build)|^info'
printf 'ch-mcp.channel=beta\n' > "$CP"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H16 invalid channel -> CANNOT-CHECK (rc 20), never defaulted"      20 "cannot.ch-mcp.channel='beta'" $'ch-mcp\tunpinned'
printf 'ch-mcp.channel=canary\nch-mcp.chanel=stable\nnope-mcp.channel=canary\n' > "$CP"
run "${HX[@]}" MCP_NO_FETCH=1
expect "H17 typo'd key in the policy file -> bad-policy"                   10 'bad-policy.*ch-mcp.chanel: unknown setting' -
expect "H17b ...and a channel for a launcher that does not exist"          10 'bad-policy.*nope-mcp.channel: no launcher' -
printf 'channel=canary\nch-mcp.update=auto\n' > "$CP"
( export MCP_CONFIG_FILE="$CP"; . "$VLIB/_mcp-decl.sh"; [ "$(mcp_update_mode "$HL/ch-mcp.sh")|$(mcp_channel "$HL/ch-mcp.sh")" = "auto|canary" ] ) \
  && ok "H18 one grammar: update + channel lines parsed from the same file" || no "H18 grammar"
printf 'ch-mcp.channel=canary\n' > "$CP"; ch_launcher " "
run "${HX[@]}" MCP_NO_FETCH=1
expect "H19 canary on a declaration without url= -> CANNOT-CHECK"          20 'canary needs src= url= sub=' -
ch_launcher

echo "== I. mcp-config resolution (root=, owner=, .url=, .fork=, .dir=, .branch=; mcp_shape; URL normalization; ensure_mcp_server named form)"
I="$T/i"; mkdir -p "$I/lib" "$I/fakehome" "$I/root1" "$I/root2" "$I/onedir"
cp "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$I/lib/"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=z-mcp sub=. url=https://github.com/upstream-owner/z-mcp.git\nexit 0\n' > "$I/lib/z-mcp.sh"
IX=(HOME="$I/fakehome" MCP_LIB_DIR="$I/lib" I="$I")
isrc(){ env "${IX[@]}" MCP_CONFIG_FILE="${1:-$I/nope}" bash -c '. "$I/lib/_mcp-decl.sh"; '"$2"''; }
OUT="$(isrc "" '_mcp_url_eq https://github.com/o/r.git/ git@github.com:o/r.git && echo EQ')"
case "$OUT" in EQ) ok "I0c URL with .git/ trailing slash equals the ssh form" ;; *) no "I0c URL with .git/ trailing slash equals the ssh form" ;; esac
OUT="$(isrc "" '_mcp_url_eq https://github.com/o/r.git/ https://github.com/o/other.git || echo NE')"
case "$OUT" in NE) ok "I0d different repos stay unequal after normalization (break-it direction)" ;; *) no "I0d different repos stay unequal" ;; esac
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=zs sub=./packages/p/ url=https://github.com/up/zs.git\nexit 0\n' > "$I/lib/zs-mcp.sh"
OUT="$(isrc "" 'mcp_entry "$I/lib/zs-mcp.sh"')"
case "$OUT" in */zs/packages/p/dist/index.js) ok "I0e sub= with ./ and trailing / normalizes to one clean entry path" ;; *) no "I0e sub= normalizes (got: $OUT)" ;; esac
case "/${OUT#*/zs/}" in *//*|*/./*) no "I0f entry path has no // or /./ (break-it direction)" ;; *) ok "I0f entry path has no // or /./ (break-it direction)" ;; esac
rm -f "$I/lib/zs-mcp.sh"
printf 'channel=stable\n' > "$I/lintok"; OUT="$(isrc "$I/lintok" 'mcp_policy_lint "$I/lib"')"
printf 'channel=canary\n' > "$I/lintok"; OUT="$OUT$(isrc "$I/lintok" 'mcp_policy_lint "$I/lib"')"
if [ -z "$OUT" ]; then ok "I0 machine-default channel=stable|canary lints clean"; else no "I0 machine-default channel= lints clean"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
printf 'channel=sometimes\n' > "$I/lintbad"; OUT="$(isrc "$I/lintbad" 'mcp_policy_lint "$I/lib"')"
case "$OUT" in *channel*sometimes*) ok "I0b invalid machine-default channel= is flagged (break-it direction)" ;; *) no "I0b invalid machine-default channel= is flagged"; printf '%s\n' "$OUT" | sed 's/^/        /' ;; esac
: > "$I/cfg"
printf '%s\n' "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir' 2>&1)" | grep -q "$I/fakehome/Code/z-mcp" \
  && ok "I1 no root= -> default ~/Code, relative dir= rooted under it" || no "I1 default root: $(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
printf 'root=%s\n' "$I/root1" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" = "$I/root1/z-mcp" ] \
  && ok "I2 root= (absolute) relocates a relative dir=" || no "I2 root="
printf 'root=relative/path\n' > "$I/cfg"
case "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" in INVALID:*absolute*) ok "I3 relative root= is invalid, never passed through" ;; *) no "I3 relative root=" ;; esac
printf 'root=%s\nroot=%s\n' "$I/root1" "$I/root2" > "$I/cfg"
case "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" in INVALID:*"more than once"*) ok "I3b duplicate root= is invalid, never passed through" ;; *) no "I3b duplicate root=" ;; esac
printf 'owner=myfork\n' > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" url')" = "https://github.com/myfork/z-mcp.git" ] \
  && ok "I4 owner= rewrites the github.com owner segment" || no "I4 owner rewrite"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=w-mcp url=https://example.com/not-github/w.git\nexit 0\n' > "$I/lib/w-mcp.sh"
printf 'owner=myfork\n' > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/w-mcp.sh" url')" = "https://example.com/not-github/w.git" ] \
  && ok "I4b owner= leaves a non-github.com URL unrewritten" || no "I4b owner non-github"
printf '%s.url=%s\nowner=ignored\n' z-mcp "https://github.com/direct-owner/z-mcp.git" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" url')" = "https://github.com/direct-owner/z-mcp.git" ] \
  && ok "I5 per-MCP .url= wins outright over owner=" || no "I5 .url= override"
printf '%s.fork=%s\n' z-mcp "git@github.com:myuser/z-mcp.git" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_shape "$I/lib/z-mcp.sh"')" = fork ] \
  && ok "I6 resolved .fork= differing from origin -> effective shape fork" || no "I6 fork upgrade"
printf '%s.fork=%s\n' z-mcp "https://github.com/upstream-owner/z-mcp" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_shape "$I/lib/z-mcp.sh"')" = checkout ] \
  && ok "I7 .fork= equal to origin (ssh vs https, .git vs none) -> checkout, not an error" || no "I7 fork==origin"
[ "$(isrc "$I/cfg" 'fork_is_redundant "$I/lib/z-mcp.sh" && echo yes')" = yes ] \
  && ok "I7b ...and is reported as a redundant .fork= line" || no "I7b redundant"
printf '%s.dir=%s\n' z-mcp "$I/onedir" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" = "$I/onedir" ] \
  && ok "I8 per-MCP .dir= (absolute) is a one-off override" || no "I8 .dir= override"
printf '%s.dir=relative/nope\n' z-mcp > "$I/cfg"
case "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" in INVALID:*absolute*) ok "I8b a relative .dir= override is invalid, never passed through (break-it direction)" ;; *) no "I8b relative .dir=" ;; esac
printf '%s.branch=develop\n' z-mcp > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" branch')" = develop ] \
  && ok "I9 <l>.branch= overrides the declared default" || no "I9 branch override"
: > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" branch')" = main ] \
  && ok "I9b ...absent -> declared default (main)" || no "I9b branch default"
: > "$I/cfg"
mkdir -p "$I/root1/z-mcp/dist"
printf '#!/bin/sh\nexit 0\n' > "$I/root1/z-mcp/dist/index.js"; printf '%040d\n' 0 > "$I/root1/z-mcp/dist/.built-from"   # "built" = entry + stamp
printf 'root=%s\n' "$I/root1" > "$I/cfg"
env "${IX[@]}" MCP_CONFIG_FILE="$I/cfg" bash -c '. "'"$I"'/lib/_mcp-decl.sh"; ensure_mcp_server z 2>&1' >/dev/null 2>&1
[ $? -eq 0 ] && ok "I10 ensure_mcp_server named form strips a trailing -mcp ('z' == 'z-mcp')" || no "I10 name strip"
OUT="$(env "${IX[@]}" MCP_CONFIG_FILE="$I/cfg" bash -c '. "'"$I"'/lib/_mcp-decl.sh"; ensure_mcp_server "Bad Name!" 2>&1')"; RC=$?
[ "$RC" != 0 ] && printf '%s\n' "$OUT" | grep -q 'invalid name' \
  && ok "I11 ensure_mcp_server rejects a name outside ^[a-z0-9-]+\$" || no "I11 invalid name: $OUT"
[ "$(isrc "$I/cfg" '_mcp_url_norm git@github.com:o/r.git')" = "$(isrc "$I/cfg" '_mcp_url_norm https://github.com/o/r')" ] \
  && ok "I12 URL normalization: ssh == https (with/without .git)" || no "I12 url norm"
printf '%s.dir=%s/\n' z-mcp "$I/onedir" > "$I/cfg"
withslash="$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
printf '%s.dir=%s\n' z-mcp "$I/onedir" > "$I/cfg"
noslash="$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
[ "$withslash" = "$noslash" ] && [ "$withslash" = "$I/onedir" ] \
  && ok "I13 a trailing slash on .dir= resolves to the same path" || no "I13 trailing slash: with=$withslash without=$noslash"
printf 'root=%s/\n' "$I/root1" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" = "$I/root1/z-mcp" ] \
  && ok "I13b a trailing slash on root= resolves the same as without" || no "I13b root trailing slash"
lockpath="${withslash}.openbrain-build.lock"
[ "$lockpath" = "$I/onedir.openbrain-build.lock" ] \
  && ok "I13c the build lock lands BESIDE the checkout (sibling), never inside it" || no "I13c lock path: $lockpath"
printf 'root = %s\n' "$I/root1" > "$I/cfg"; m8a="$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
printf 'z-mcp.update=\n' > "$I/cfg";        m8b="$(isrc "$I/cfg" 'mcp_update_mode "$I/lib/z-mcp.sh"')"
printf 'channel=\n' > "$I/cfg";             m8c="$(isrc "$I/cfg" 'mcp_channel "$I/lib/z-mcp.sh"')"
m8=""; case "$m8a" in INVALID:*malformed*) ;; *) m8="$m8 root=[$m8a]" ;; esac
case "$m8b" in INVALID:*) ;; *) m8="$m8 update=[$m8b]" ;; esac
case "$m8c" in INVALID:*) ;; *) m8="$m8 channel=[$m8c]" ;; esac
[ -z "$m8" ] && ok "I14 'root = /x', empty update=, empty channel= -> INVALID, never a silent default" || no "I14 silently defaulted:$m8"
# an inline comment after whitespace is not part of the value; a ':' separator is malformed, never skipped
printf 'root=%s   # where my MCPs live\n' "$I/root1" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" = "$I/root1/z-mcp" ] \
  && ok "I15 'root=/x   # comment' resolves to /x (the comment is not part of the path)" || no "I15 inline comment on root=: $(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
printf 'z-mcp.dir=%s\t# one-off\n' "$I/onedir" > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" = "$I/onedir" ] \
  && ok "I15b '<l>.dir=/x<TAB># comment' resolves to /x" || no "I15b inline comment on .dir=: $(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')"
printf 'z-mcp.url=https://github.com/o/z-mcp.git#frag\n' > "$I/cfg"
[ "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" url')" = "https://github.com/o/z-mcp.git#frag" ] \
  && ok "I15c a # with no whitespace before it stays in the value (break-it direction)" || no "I15c # inside a value was stripped"
printf 'root: %s\n' "$I/root2" > "$I/cfg"
case "$(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" in INVALID:*malformed*) ok "I16 'root: /x' -> INVALID (malformed), never skipped to the default root" ;; *) no "I16 'root: /x' resolved to: $(isrc "$I/cfg" 'mcp_get "$I/lib/z-mcp.sh" dir')" ;; esac
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=npm pkg=@x/zn\nexit 0\n' > "$I/lib/zn-mcp.sh"
printf 'z-mcp.update=sometimes\nzn-mcp.channel=beta\nchannel=stable\nchannel=canary\n' > "$I/cfg"
OUT="$(isrc "$I/cfg" 'mcp_policy_lint "$I/lib"')"
l17=""; printf '%s\n' "$OUT" | grep -q "z-mcp.update:.*sometimes" || l17="$l17 update"
printf '%s\n' "$OUT" | grep -q "zn-mcp.channel:.*beta" || l17="$l17 .channel"
printf '%s\n' "$OUT" | grep -q "channel: channel set more than once" || l17="$l17 dup-channel"
[ -z "$l17" ] && ok "I17 lint flags an invalid .update= value, an invalid .channel= value, and a duplicate channel=" || { no "I17 lint missed:$l17"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
printf 'z-mcp.update=auto  # applied unattended\nzn-mcp.channel=stable\nchannel=canary # default\n' > "$I/cfg"
OUT="$(isrc "$I/cfg" 'mcp_policy_lint "$I/lib"')"
[ -z "$OUT" ] && ok "I17b valid values (with inline comments) lint clean (false-positive direction)" || { no "I17b valid values flagged"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
rm -f "$I/lib/zn-mcp.sh"

echo "== J. build lock (age-only staleness; a fresh lock is honored regardless of holder liveness; clone never nests onto an existing target)"
J="$T/j"; mkdir -p "$J/lib" "$J/fakehome"
cp "$VLIB/_mcp-decl.sh" "$J/lib/"
JX=(HOME="$J/fakehome")
mkdir -p "$J/ckt.openbrain-build.lock"
env "${JX[@]}" bash -c '. "'"$J"'/lib/_mcp-decl.sh"; _mcp_lock_stale "'"$J"'/ckt.openbrain-build.lock"'
[ $? -eq 1 ] && ok "J1 a fresh lock is not stale" || no "J1 fresh not stale"
touch -t "$(date -v-6M +%Y%m%d%H%M.%S 2>/dev/null || date -d '6 minutes ago' +%Y%m%d%H%M.%S)" "$J/ckt.openbrain-build.lock"
env "${JX[@]}" bash -c '. "'"$J"'/lib/_mcp-decl.sh"; _mcp_lock_stale "'"$J"'/ckt.openbrain-build.lock"'
[ $? -eq 0 ] && ok "J2 a lock older than the stale window (\$MCP_LOCK_STALE_MIN=5 min) is stale" || no "J2 aged stale"
rm -rf "$J/ckt.openbrain-build.lock"
# J3: a concurrent SECOND caller actually waits for a lock within the stale window — age-only
# means this holds regardless of whether the holder process itself is still alive (a dead
# parent can still have a live npm child writing the checkout; PID-liveness was reverted for
# exactly this reason) — then proceeds once the lock is released.
git clone -q --bare "$T/forkish.git" "$J/jorigin.git" 2>/dev/null || git clone -q --bare "$F/origin" "$J/jorigin.git"
JH="$J/fakehome"; mkdir -p "$JH/.config/openbrain/lib"; : > "$JH/.config/openbrain/.env"
cp "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$JH/.config/openbrain/lib/"
cat > "$JH/.config/openbrain/lib/j-mcp.sh" <<EOF
#!/usr/bin/env bash
# openbrain-mcp: shape=checkout dir=$J/jckt url=$J/jorigin.git
set -euo pipefail
source "\$(dirname "\${BASH_SOURCE[0]}")/_common.sh"
ensure_mcp_server
exec node "\$(declared_entry)" --help
EOF
chmod 755 "$JH/.config/openbrain/lib/j-mcp.sh"
mkdir -p "$J/jckt"   # pre-create the dir so the lock path ($dir.openbrain-build.lock) is well-formed
( mkdir "$J/jckt.openbrain-build.lock"
  sleep 3; rm -rf "$J/jckt.openbrain-build.lock" ) &
holder=$!
sleep 0.4   # let the background holder actually acquire the lock first
rmdir "$J/jckt" 2>/dev/null || true   # empty dir was only a placeholder for the lock path; the real build needs it absent to clone
start=$(date +%s)
OUT="$(HOME="$JH" MCP_BUILD_CMD='npm run build --silent' bash "$JH/.config/openbrain/lib/j-mcp.sh" 2>&1)"; RC=$?
elapsed=$(( $(date +%s) - start ))
wait "$holder" 2>/dev/null || true
[ "$RC" = 0 ] && [ "$elapsed" -ge 2 ] && ok "J3 second caller waited for the fresh lock (${elapsed}s) then built" \
  || no "J3 lock wait (rc=$RC elapsed=${elapsed}s): $OUT"
# J4: mv onto an already-existing target discards the temp clone instead of nesting into it —
# the race where an age-stale lock lets a second caller in just as the first finishes.
mkdir -p "$J/preexisting"; : > "$J/preexisting/marker"
mkdir -p "$J/clonesrc"; git -C "$J/clonesrc" init -q -b main
git -C "$J/clonesrc" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
env "${JX[@]}" bash -c '. "'"$J"'/lib/_mcp-decl.sh"; _mcp_clone "'"$J"'/clonesrc" "'"$J"'/preexisting"'
if [ -f "$J/preexisting/marker" ] && [ ! -d "$J/preexisting/.git" ] && [ -z "$(ls -d "$J"/preexisting.openbrain-clone-tmp* 2>/dev/null)" ]; then
  ok "J4 mv onto an existing target discards the temp clone instead of nesting"
else
  no "J4 nested clone (marker=$([ -f "$J/preexisting/marker" ] && echo present || echo GONE), .git=$([ -d "$J/preexisting/.git" ] && echo present || echo absent))"
fi

# J5: several waiters starting together on one stale lock (e.g. one launcher per account of the
# same MCP after a crash) -> exactly one holds it at a time. Each holder records itself, waits,
# counts the holders present, then releases; any count above 1 is two concurrent holders.
JB="$J/jb"; mkdir -p "$JB/seen"
j5max=0
for trial in 1 2 3 4; do
  rm -rf "$JB/ckt.openbrain-build.lock" "$JB/ckt.openbrain-build.lock.break" "$JB/holders"; mkdir -p "$JB/ckt.openbrain-build.lock" "$JB/holders"
  touch -t "$(date -v-6M +%Y%m%d%H%M.%S 2>/dev/null || date -d '6 minutes ago' +%Y%m%d%H%M.%S)" "$JB/ckt.openbrain-build.lock"
  for w in 1 2 3 4 5 6 7 8; do
    env "${JX[@]}" JB="$JB" W="$trial.$w" bash -c '. "'"$J"'/lib/_mcp-decl.sh"
      _mcp_lock_acquire "$JB/ckt" 30 || exit 1
      : > "$JB/holders/$W"; sleep 0.3; ls "$JB/holders" | wc -l | tr -d " " > "$JB/seen/$W"; rm -f "$JB/holders/$W"
      _mcp_lock_release' &
  done
  wait
done
for f in "$JB"/seen/*; do n="$(cat "$f")"; [ "$n" -gt "$j5max" ] && j5max="$n"; done
nseen="$(ls "$JB/seen" | wc -l | tr -d ' ')"
[ "$nseen" = 32 ] && [ "$j5max" = 1 ] && ok "J5 8 waiters x 4 trials on a stale lock -> never two holders at once (all 32 got it)" \
  || no "J5 concurrent holders on a broken stale lock (max seen together: $j5max; $nseen/32 acquired)"

echo "== K. npm stable src= resolution (publish-lag) goes through mcp_get, not a raw decl_get"
K="$T/k"; mkdir -p "$K/lib" "$K/kroot"
cp "$VLIB/_mcp-decl.sh" "$K/lib/"
git clone -q "$T/forkish.git" "$K/kroot/k-mcp-src" 2>/dev/null || git clone -q "$F/origin" "$K/kroot/k-mcp-src"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=npm pkg=@x/k src=k-mcp-src\nexit 0\n' > "$K/lib/k-mcp.sh"
printf '{"mcpServers":{"k":{"type":"stdio","command":"%s/lib/k-mcp.sh","args":[]}}}\n' "$K" > "$K/claude.json"
git -C "$K/kroot/k-mcp-src" rev-parse HEAD > "$K/publishedhead"   # FIXED at publish time — the stub must not recompute HEAD live, or every edit would look "already published"
printf '#!/bin/sh\n[ "$3" = version ] && echo 0.0.1; [ "$3" = gitHead ] && cat "%s/publishedhead"; exit 0\n' "$K" > "$K/npm"; chmod +x "$K/npm"
printf 'root=%s\n' "$K/kroot" > "$K/policy"
KX=(MCP_LIB_DIR="$K/lib" MCP_REGISTERED_LIB="$K/lib" MCP_CLAUDE_JSON="$K/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NPM="$K/npm"
    MCP_UPDATE_STATE="$K/state" MCP_CONFIG_FILE="$K/policy" MCP_NETWORK=1 MCP_PS_FILE="$F/ps.txt")
run "${KX[@]}"
expect "K1 relative src= resolves under root= -> real checkout found, not consume-only" 10 $'k-mcp\tunpinned' $'consume-only|^cannot'
echo '// local edit' >> "$K/kroot/k-mcp-src/package.json"
git -C "$K/kroot/k-mcp-src" -c user.name=t -c user.email=t@t commit -qam "unreleased change"
run "${KX[@]}"
expect "K2 an unreleased change under src= -> publish-lag (proves it's really reading the checkout)" 10 $'k-mcp\tpublish-lag' -
git -C "$K/kroot/k-mcp-src" reset -q --hard HEAD^
rm -rf "$K/kroot/k-mcp-src"
run "${KX[@]}"
expect "K3 false-negative direction: remove the checkout -> consume-only, never a silent clean" 10 $'cov\tconsume-only\tk-mcp' $'k-mcp\tpublish-lag'

echo "== M. fork-remote mismatch (check_fork; report-only — never silently re-pointed)"
M="$T/m"; mkdir -p "$M/lib" "$M/mroot/m-mcp"
cp "$VLIB/_mcp-decl.sh" "$M/lib/"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=m-mcp url=https://github.com/upstream/m-mcp.git\nexit 0\n' > "$M/lib/m-mcp.sh"
git -C "$M/mroot/m-mcp" init -q -b main
git -C "$M/mroot/m-mcp" remote add origin "https://github.com/upstream/m-mcp.git"
git -C "$M/mroot/m-mcp" remote add fork "https://github.com/wrong/m-mcp.git"
printf '{"mcpServers":{"m":{"type":"stdio","command":"%s/lib/m-mcp.sh","args":[]}}}\n' "$M" > "$M/claude.json"
printf 'root=%s\nm-mcp.fork=https://github.com/right/m-mcp.git\n' "$M/mroot" > "$M/policy"
MX=(MCP_LIB_DIR="$M/lib" MCP_REGISTERED_LIB="$M/lib" MCP_CLAUDE_JSON="$M/claude.json" OPENBRAIN_VAULT=/nonexistent
    MCP_UPDATE_STATE="$M/state" MCP_CONFIG_FILE="$M/policy" MCP_PS_FILE="$F/ps.txt")
run "${MX[@]}"
expect "M1 fork remote points elsewhere than resolved .fork= -> fork-mismatch (report-only)" 10 $'m-mcp\tfork-mismatch.*remote set-url fork' -
git -C "$M/mroot/m-mcp" remote set-url fork "https://github.com/right/m-mcp.git"
run "${MX[@]}"
expect "M2 fork remote matches resolved .fork= -> no fork-mismatch (clean on that axis)" 10 - $'m-mcp\tfork-mismatch'
git -C "$M/mroot/m-mcp" remote set-url origin "https://github.com/someone/m-mcp.git"; run "${MX[@]}"
expect "M3 origin-mismatch remedy also offers <l>.url= / owner= for an intentional origin" 10 $'m-mcp\torigin-mismatch.*set-url origin.*m-mcp\\.url= \\(or owner=\\)' -
git -C "$M/mroot/m-mcp" remote remove origin; run "${MX[@]}"
expect "M4 an unreadable origin -> CANNOT-CHECK carrying git's own error" 20 $'cannot\tm-mcp\tgit remote get-url origin failed in .*: .+' -

echo "== U. build and apply robustness"
U="$T/u"; mkdir -p "$U/lib"
cp "$VLIB/_mcp-decl.sh" "$U/lib/"
git clone -q "$F/origin" "$U/work"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s sub=packages/a url=%s\nexit 0\n' "$U/work" "$F/origin" > "$U/lib/u-mcp.sh"
printf '{"mcpServers":{"u":{"type":"stdio","command":"%s/lib/u-mcp.sh","args":[]}}}\n' "$U" > "$U/claude.json"
: > "$U/cfg"
UX=(MCP_LIB_DIR="$U/lib" MCP_REGISTERED_LIB="$U/lib" MCP_CLAUDE_JSON="$U/claude.json" OPENBRAIN_VAULT=/nonexistent
    MCP_NO_FETCH=1 MCP_PS_FILE="$F/ps.txt" OPENBRAIN_UPDATE_SNOOZE="$U/snooze" MCP_UPDATE_STATE="$U/state" MCP_CONFIG_FILE="$U/cfg"
    MCP_CHECKOUT_BUILD_CMD="npm run build --silent && npm run test --if-present --silent")
UD="$U/work/packages/a"; umark(){ cat "$UD/dist/.built-from" 2>/dev/null; }
OUT="$(env "${UX[@]}" bash "$CU" --apply u-mcp 2>&1)"; RC=$?
expect "U0 fixture: first build"                                       0 'applied' -
# --- dist/ stranded in .dist.bak by a killed build
mv "$UD/dist" "$UD/.dist.bak"
run "${UX[@]}"
expect "RC1 the checker reports a stranded .dist.bak as itself, not as uncommitted work" 10 $'u-mcp\tstranded-build\t--apply u-mcp' $'u-mcp\tdirty-tree'
OUT="$(env "${UX[@]}" bash "$CU" --apply u-mcp 2>&1)"; RC=$?
expect "U3a .dist.bak left by a killed build -> next apply restores it and rebuilds (no dirty-tree refusal)" 0 'applied' 'uncommitted changes'
[ ! -e "$UD/.dist.bak" ] && [ -f "$UD/dist/index.js" ] && ok "U3b ...no .dist.bak left, dist/ present" || no "U3b .dist.bak=$([ -e "$UD/.dist.bak" ] && echo present || echo absent)"
ub="$(umark)"
OUT="$(MCP_SKIP_FETCH=1 MCP_CHECKOUT_BUILD_CMD='kill -TERM $$; sleep 1' bash "$ENGINE" --checkout u-mcp "$U/work" packages/a main 2>&1)"; RC=$?
[ "$RC" != 0 ] && [ -f "$UD/dist/index.js" ] && [ ! -e "$UD/.dist.bak" ] && [ "$(umark)" = "$ub" ] \
  && ok "U3c TERM mid-build -> the previous dist/ is restored before exit" \
  || no "U3c TERM mid-build (rc=$RC dist=$([ -f "$UD/dist/index.js" ] && echo present || echo ABSENT) bak=$([ -e "$UD/.dist.bak" ] && echo LEFT || echo none))"
# --- --apply takes the build lock, and clones atomically
mkdir "$U/work.openbrain-build.lock"
OUT="$(env "${UX[@]}" MCP_LOCK_WAIT=2 bash "$CU" --apply u-mcp 2>&1)"; RC=$?
expect "U6a --apply honours a fresh build lock another build holds" 1 'another build holds it' 'u-mcp: applied'
rmdir "$U/work.openbrain-build.lock"
mkdir -p "$U/shim"; realgit="$(command -v git)"
cat > "$U/shim/git" <<EOF
#!/bin/sh
# a clone killed part-way: leaves a partial target behind and fails
if [ "\$1" = clone ]; then for a; do last="\$a"; done; mkdir -p "\$last" && : > "\$last/PARTIAL"; exit 137; fi
exec "$realgit" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$U/shim/gh"; chmod +x "$U/shim/git" "$U/shim/gh"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s sub=packages/a url=%s\nexit 0\n' "$U/fresh" "$F/origin" > "$U/lib/v-mcp.sh"
OUT="$(env "${UX[@]}" PATH="$U/shim:$PATH" bash "$CU" --apply v-mcp 2>&1)"; RC=$?
[ "$RC" != 0 ] && [ ! -e "$U/fresh" ] && ok "U6b a killed clone during --apply leaves no partial checkout behind" \
  || no "U6b partial checkout left at $U/fresh (rc=$RC)"
rm -f "$U/lib/v-mcp.sh"
# --- a symlinked lib path must not change what counts as "runs through a launcher"
mkdir -p "$T/reg/vault"; ln -s "$U/lib" "$T/reg/liblink"
run "${UX[@]}" MCP_REGISTERED_LIB="$T/reg/liblink"
expect "U12 registry filter compares realpaths (symlinked lib path still resolves)" 0 'checked.1 program' 'undeclared-server|bypasses-launcher'
# --- the SKILL's coverage claim and the checker's behaviour agree: ~/.claude.json only
printf '{"mcpServers":{"zz":{"command":"/usr/bin/true","args":[]}}}\n' > "$T/reg/vault/.mcp.json"
run "${UX[@]}" OPENBRAIN_VAULT="$T/reg/vault"
SK="$VAULT/.claude/skills/brain-update-check/SKILL.md"
if grep -q 'registered in `~/.claude.json`' "$SK" && ! grep -q 'registered with Claude Code' "$SK" \
   && printf '%s\n' "$OUT" | grep -q $'cov\tregistered\t1 stdio server(s) — from '"$U"'/claude.json' \
   && ! printf '%s\n' "$OUT" | grep -q 'zz'; then
  ok "U11 SKILL claims ~/.claude.json only, and a project .mcp.json is indeed not read"
else no "U11 SKILL claim vs checker scope"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
# --- --snooze never silences CANNOT-CHECK (and still silences findings)
OUT="$(env "${UX[@]}" MCP_PS_FILE="$U/no-ps" bash "$CU" --snooze 2>&1)"
OUT="$(env "${UX[@]}" MCP_PS_FILE="$U/no-ps" bash "$CU" --check 2>&1)"; RC=$?
expect "U9a snoozed CANNOT-CHECK still reports"                  20 '1 cannot-check' -
printf 'x\n' >> "$UD/src/index.js"
OUT="$(env "${UX[@]}" bash "$CU" --snooze 2>&1)"; OUT="$(env "${UX[@]}" bash "$CU" --check 2>&1)"; RC=$?
expect "U9b snoozed FINDINGS stay quiet (false-positive direction)"     0 - 'MCP updates'
git -C "$U/work" checkout -q -- packages/a/src/index.js; rm -f "$U/snooze"
# --- ps start times in another locale
UE="$UD/dist/index.js"
printf '  1 Thu Jan  1 00:00:00 2026     /sbin/launchd\n 10 So. 11 Okt. 01:01:50 2026     node %s\n' "$UE" > "$U/ps-de.txt"
run "${UX[@]}" MCP_PS_FILE="$U/ps-de.txt"
expect "U8a a ps line in another locale -> CANNOT-CHECK, never '0 stale'" 20 'unrecognised format' -
if LC_ALL=de_DE.UTF-8 ps -o lstart= -p $$ 2>/dev/null | grep -q 'Okt\|So\.\|Mo\.\|Di\.\|Mi\.\|Do\.\|Fr\.\|Sa\.'; then
  sleep 30 | node "$UE" >/dev/null 2>&1 & upid=$!
  sleep 1
  OUT="$(env "${UX[@]}" MCP_PS_FILE= LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 bash "$CU" --raw 2>&1)"; RC=$?
  kill "$upid" 2>/dev/null; wait "$upid" 2>/dev/null
  expect "U8b live ps under de_DE: the running server is still seen (ps runs under LC_ALL=C)" "$RC" $'procs\tu-mcp: 1 running' 'unrecognised'
else
  skip "U8b" "no de_DE locale on this machine"
fi
# --- the ENGINE owns the build lock for its whole run
uh="$(git -C "$U/work" rev-parse HEAD)"
( MCP_SKIP_FETCH=1 MCP_CHECKOUT_BUILD_CMD='sleep 3 && npm run build --silent' bash "$ENGINE" --checkout u-mcp "$U/work" packages/a main > "$U/engA.out" 2>&1
  echo "rc=$?" >> "$U/engA.out" ) & apid=$!
sleep 1
OUT="$(MCP_SKIP_FETCH=1 MCP_CHECKOUT_BUILD_CMD='sleep 3; exit 1' bash "$ENGINE" --checkout u-mcp "$U/work" packages/a main 2>&1)"; RC=$?
wait "$apid"
if grep -q '^rc=0$' "$U/engA.out" && ! grep -q 'restored the previous' "$U/engA.out" && [ -f "$UE" ] && [ ! -e "$UD/.dist.bak" ] && [ "$(umark)" = "$uh" ]; then
  ok "RA1 slow build A + slow failing build B 1s later: B waits for A's lock; dist/ survives with A's build"
else no "RA1 concurrent engines (dist=$([ -f "$UE" ] && echo present || echo ABSENT) bak=$([ -e "$UD/.dist.bak" ] && echo LEFT || echo none) marker=$(umark))"; sed 's/^/        A: /' "$U/engA.out"; printf '%s\n' "$OUT" | sed 's/^/        B: /'; fi
# A, launcher side: a launcher killed mid-build must not hand the lock to a relaunch while
# its engine still builds — the relaunch waits for that build and runs it.
mklauncher "$H/.config/openbrain/lib/ul-mcp.sh" "# openbrain-mcp: shape=checkout dir=$U/work sub=packages/a url=$F/origin"
rm -rf "${UD:?}/dist"
( HOME="$H" MCP_CHECKOUT_BUILD_CMD='sleep 3 && npm run build --silent' exec bash "$H/.config/openbrain/lib/ul-mcp.sh" > "$U/launchA.out" 2>&1 ) & lpid=$!
sleep 1; kill -TERM "$lpid" 2>/dev/null
OUT="$(HOME="$H" MCP_CHECKOUT_BUILD_CMD='exit 1' bash "$H/.config/openbrain/lib/ul-mcp.sh" 2>&1)"; RC=$?
wait "$lpid" 2>/dev/null; sleep 1
expect "RA2 relaunch after a killed launcher defers to the live build instead of racing it" 0 'Usage: stub' 'build failed'
[ -f "$UE" ] && [ ! -e "$UD/.dist.bak" ] && [ "$(umark)" = "$uh" ] && ok "RA2b ...dist/ is the live build's, no .dist.bak left" || no "RA2b dist after the race (marker=$(umark))"
rm -f "$H/.config/openbrain/lib/ul-mcp.sh"
# --- a .dist.bak under a live (fresh) build lock is a build in progress, not stranded
mv "$UD/dist" "$UD/.dist.bak"; mkdir "$U/work.openbrain-build.lock"
run "${UX[@]}"
expect "S3a .dist.bak while the build lock is fresh -> info 'build in progress', not stranded-build" "$RC" $'info\tu-mcp\tbuild in progress' $'u-mcp\tstranded-build'
rmdir "$U/work.openbrain-build.lock"; run "${UX[@]}"
expect "S3b ...no lock -> stranded-build (false-negative direction)"   10 $'u-mcp\tstranded-build' -
mv "$UD/.dist.bak" "$UD/dist"
# --- snooze ignores CANNOT-CHECK lines, so snoozed findings stay snoozed when one clears
printf 'x\n' >> "$UD/src/index.js"
OUT="$(env "${UX[@]}" MCP_PS_FILE="$U/no-ps" bash "$CU" --snooze 2>&1)"
OUT="$(env "${UX[@]}" bash "$CU" --check 2>&1)"; RC=$?
expect "RE1 snoozed findings stay snoozed after a CANNOT-CHECK clears" 0 - 'MCP updates'
git -C "$U/work" checkout -q -- packages/a/src/index.js; rm -f "$U/snooze"
# --- an installed launcher that predates the vault's declared one -> the remedy is a redeploy
run "${REAL[@]}" "${HERM[@]}" MCP_LIB_DIR="$OLD_LIB" MCP_REGISTERED_LIB="$LIVE_LIB"
expect "U10 undeclared installed copy of a declared tracked launcher -> redeploy, not a hand edit" 20 $'undeclared\t!redeploy.*reconcile-runtime\\.sh --apply' "add one '# openbrain-mcp: shape=\\.\\.\\.' line to $OLD_LIB"

echo "== N. fork shape through check-updates (step-6 command, unused keys, force-push)"
N="$T/nf"; mkdir -p "$N/lib"; cp "$VLIB/_mcp-decl.sh" "$N/lib/"
git init -q -b main "$N/up"; printf '{"name":"g","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$N/up/package.json"
printf 'console.log(1)\n' > "$N/up/src.js"; printf 'dist/\n' > "$N/up/.gitignore"; commit "$N/up" init
git clone -q --bare "$N/up" "$N/origin.git"; git clone -q --bare "$N/up" "$N/fork.git"
git clone -q "$N/origin.git" "$N/home"; git -C "$N/home" remote add fork "file://$N/fork.git"; git -C "$N/home" fetch -q fork
nf_launcher(){ printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s%s url=%s\nexit 0\n' "$N/home" "${1:-}" "$N/origin.git" > "$N/lib/nf-mcp.sh"; }
nf_launcher
printf 'nf-mcp.fork=file://%s\n' "$N/fork.git" > "$N/cfg"
printf '{"mcpServers":{"nf":{"type":"stdio","command":"%s/lib/nf-mcp.sh","args":[]}}}\n' "$N" > "$N/claude.json"
NFX=(MCP_LIB_DIR="$N/lib" MCP_REGISTERED_LIB="$N/lib" MCP_CLAUDE_JSON="$N/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NO_FETCH=1 MCP_SKIP_FETCH=1
     MCP_PS_FILE="$F/ps.txt" MCP_UPDATE_STATE="$N/state" MCP_CONFIG_FILE="$N/cfg" MCP_BUILD_CMD='npm run build --silent')
# push-mcp-change step 6, extracted and run exactly as the skill writes it
P6="$VAULT/.claude/skills/push-mcp-change/SKILL.md"
step6="$(awk '/^6\. /{f=1} f && /^   bash /{sub(/^   /,""); print; exit}' "$P6")"
[ -n "$step6" ] || { echo "FIXTURE BUG: no bash command found under push-mcp-change step 6" >&2; exit 90; }
OUT="$(cd "$VAULT" && env "${NFX[@]}" bash -c "${step6//<name>/nf-mcp}" 2>&1)"; RC=$?
expect "U1a push-mcp-change step 6, run as written, builds the fork's local-build" 0 'applied' 'launcher not found'
[ "$(git -C "$N/home" symbolic-ref -q --short HEAD)" = local-build ] && ok "U1b ...on local-build" || no "U1b not on local-build"
awk '/^1\. /{f=1} /^2\. /{f=0} f' "$P6" | grep -q '\.fork=' && ok "U1c step 1 has you set <name>.fork= (without it the effective shape is checkout)" || no "U1c step 1 never sets .fork="
run "${NFX[@]}"
expect "U1d fork fixture CLEAN after the build"                          0 'checked.1 program' '^(mcp|cannot)'
printf '[user]\n\tname = t\n\temail = t@t\n' > "$N/gitconfig"   # hermetic: a global fetch.prune=true would mask N3
NREP=(MCP_NO_FETCH=0 GIT_CONFIG_GLOBAL="$N/gitconfig")
git clone -q "$N/fork.git" "$N/fw"; git -C "$N/fw" checkout -q -b feat/new; printf 'n\n' > "$N/fw/new.txt"; commit "$N/fw" feat-new
git -C "$N/fw" push -q origin feat/new
OUT="$(env "${NFX[@]}" "${NREP[@]}" bash "$CU" --report 2>&1)"; RC=$?
expect "N1 a new fork/feat/* tip not in local-build -> --report source-behind, never CLEAN" 10 'nf-mcp +source-behind.*fork/feat/new' -
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; run "${NFX[@]}"
expect "N1b ...--apply merges it -> CLEAN again"                          0 'checked.1 program' '^(mcp|cannot)'
git -C "$N/home" switch -q -c handwork; run "${NFX[@]}"
expect "N2 fork checkout switched off local-build (old stamp left in place) -> off-branch, never CLEAN" 10 $'nf-mcp\toff-branch.*switch local-build' -
git -C "$N/home" switch -q local-build
git -C "$N/fw" checkout -q -b wip/x origin/main; printf 'w\n' > "$N/fw/w.txt"; commit "$N/fw" wip; git -C "$N/fw" push -q origin wip/x
GIT_CONFIG_GLOBAL="$N/gitconfig" git -C "$N/home" fetch -q fork; run "${NFX[@]}"
expect "N3a a non-feat branch on the fork -> unenrolled"                  10 $'nf-mcp\tunenrolled' -
git -C "$N/fw" push -q origin --delete wip/x
OUT="$(env "${NFX[@]}" "${NREP[@]}" bash "$CU" --report 2>&1)"; RC=$?
expect "N3b ...deleted on the fork -> --report's fetch prunes it (no stale unenrolled)" 0 'RESULT: CLEAN' 'unenrolled'
# A feat/* deleted on the fork without being merged upstream must not stay in local-build silently.
# False-positive direction first: a feat merged upstream (then deleted) plus a live merged feat -> CLEAN.
git -C "$N/fw" checkout -q -b feat/up origin/main; printf 'u\n' > "$N/fw/up.txt"; commit "$N/fw" feat-up
git -C "$N/fw" push -q origin feat/up; git -C "$N/fw" push -q "$N/origin.git" feat/up:main
git -C "$N/home" fetch -q origin; git -C "$N/home" fetch -q --prune fork
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"
git -C "$N/fw" push -q origin --delete feat/up; git -C "$N/home" fetch -q --prune fork; run "${NFX[@]}"
expect "N4a healthy fork (live feat merged in; a feat merged upstream, then deleted) -> CLEAN" 0 'checked.1 program' '^(mcp|cannot)'
git -C "$N/fw" push -q origin --delete feat/new; git -C "$N/home" fetch -q --prune fork; run "${NFX[@]}"
expect "N4b feat/* deleted on the fork, never merged upstream, still in local-build -> source-behind" 10 $'nf-mcp\tsource-behind.*neither origin/main nor any live' -
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; run "${NFX[@]}"
expect "N4c ...--apply rebuilds without it -> CLEAN"                       0 'checked.1 program' '^(mcp|cannot)'
mv "$N/home/dist" "$N/home/.dist.bak"; run "${NFX[@]}"; mv "$N/home/.dist.bak" "$N/home/dist"
expect "RC2 fork: a stranded .dist.bak is stranded-build, not dirty-tree" 10 $'nf-mcp\tstranded-build' $'nf-mcp\tdirty-tree'
mkdir -p "$N/shim"
cat > "$N/shim/git" <<EOF
#!/bin/sh
case "\$*" in *"remote get-url fork"*) echo "simulated failure" >&2; exit 2 ;; esac
exec "$realgit" "\$@"
EOF
chmod +x "$N/shim/git"
nfb="$(cat "$N/home/dist/.built-from")"; rm "$N/home/dist/.built-from"; run "${NFX[@]}"
expect "S2c fork: a dist/ with no .built-from -> unproven-build, not dist-stale" 10 $'nf-mcp\tunproven-build' $'nf-mcp\tdist-stale'
printf '%s\n' "$nfb" > "$N/home/dist/.built-from"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s branch=next url=%s\nexit 0\n' "$N/home" "$N/origin.git" > "$N/lib/nf-mcp.sh"
printf 'nf-mcp.fork=file://%s\nnf-mcp.branch=\n' "$N/fork.git" > "$N/cfg"
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "S7 an EMPTY <l>.branch= falls back to the declaration -> the STOP names the declaration" 1 'STOP — branch=next on nf-mcp\.sh' 'nf-mcp\.branch=next in'
nf_launcher; printf 'nf-mcp.fork=file://%s\n' "$N/fork.git" > "$N/cfg"
run "${NFX[@]}" PATH="$N/shim:$PATH"
expect "RE2 a failing 'git remote get-url fork' -> CANNOT-CHECK, never a silent match" 20 'get-url fork failed' -
# keys the fork engine cannot honour are a STOP naming the key
printf 'nf-mcp.fork=file://%s\nnf-mcp.branch=next\n' "$N/fork.git" > "$N/cfg"
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "U15a <l>.branch= on a fork -> STOP naming the key, never a silent build on main" 1 'STOP — nf-mcp\.branch=next' 'nf-mcp: applied'
run "${NFX[@]}"
expect "U15b ...the checker reports it (unsupported-key)"         10 $'nf-mcp\tunsupported-key' -
printf 'nf-mcp.fork=file://%s\n' "$N/fork.git" > "$N/cfg"; nf_launcher " sub=pkg"
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "U15c sub= on a fork -> STOP naming the key"               1 'STOP — sub=pkg' 'nf-mcp: applied'
nf_launcher " entry=build/main.js"
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "U15d entry= on a fork -> STOP naming the key"             1 'STOP — entry=build/main\.js' 'nf-mcp: applied'
nf_launcher
# an invalid .fork= is named as such, not as "stable"
printf 'nf-mcp.fork=notaurl\n' > "$N/cfg"
OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "U19 --apply with an invalid .fork= names the real reason" 1 'fork must be a URL' '— stable'
printf 'nf-mcp.fork=file://%s\n' "$N/fork.git" > "$N/cfg"
# upstream force-push (no shared history) must read source-behind, never CLEAN
git -C "$N/up" checkout -q --orphan rewritten; printf 'console.log(2)\n' > "$N/up/src.js"; commit "$N/up" rewritten
git -C "$N/up" push -q -f "$N/origin.git" rewritten:main; git -C "$N/home" fetch -q -f origin
run "${NFX[@]}"
expect "U7 upstream force-push -> source-behind, never CLEAN"     10 $'nf-mcp\tsource-behind' -
expect "U7b ...the rewritten-away commit names both causes and both remedies (move, or reset local-build)" 10 $'nf-mcp\tunpushed\t.*switch -C local-build origin/main.*upstream rewrote main' -
u7fix="$(printf '%s\n' "$OUT" | grep $'^mcp\tnf-mcp\tunpushed' | grep -o 'git -C [^ ]* switch -C local-build origin/main')"
[ -n "$u7fix" ] || { echo "FIXTURE BUG: no reset remedy in the unpushed line" >&2; exit 90; }
eval "$u7fix" >/dev/null 2>&1; OUT="$(env "${NFX[@]}" bash "$CU" --apply nf-mcp 2>&1)"; RC=$?
expect "U7c ...the reset remedy, then --apply, rebuilds"           0 'nf-mcp: applied' -
run "${NFX[@]}"
expect "U7d ...and the checker is CLEAN after it"                  0 'checked.1 program' '^(mcp|cannot)'

# Adding <l>.fork= to an existing plain checkout (push-mcp-change step 1): --apply adds the fork
# remote and builds local-build, instead of dying "no fork remote".
EF="$T/ef"; mkdir -p "$EF/lib"; cp "$VLIB/_mcp-decl.sh" "$EF/lib/"
git init -q -b main "$EF/up"; printf '{"name":"ef","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$EF/up/package.json"
printf 'console.log(1)\n' > "$EF/up/src.js"; printf 'dist/\n' > "$EF/up/.gitignore"; commit "$EF/up" init
git clone -q --bare "$EF/up" "$EF/origin.git"; git clone -q --bare "$EF/up" "$EF/fork.git"; git clone -q "$EF/origin.git" "$EF/home"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s url=%s\nexit 0\n' "$EF/home" "$EF/origin.git" > "$EF/lib/ef-mcp.sh"
printf 'ef-mcp.fork=file://%s\n' "$EF/fork.git" > "$EF/cfg"
printf '{"mcpServers":{"ef":{"type":"stdio","command":"%s/lib/ef-mcp.sh","args":[]}}}\n' "$EF" > "$EF/claude.json"
EFX=(MCP_LIB_DIR="$EF/lib" MCP_REGISTERED_LIB="$EF/lib" MCP_CLAUDE_JSON="$EF/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NO_FETCH=1
     MCP_PS_FILE="$F/ps.txt" MCP_UPDATE_STATE="$EF/state" MCP_CONFIG_FILE="$EF/cfg" MCP_BUILD_CMD='npm run build --silent')
run "${EFX[@]}"
expect "N5a .fork= added to a plain checkout -> shape-mismatch whose remedy is --apply" 10 $'ef-mcp\tshape-mismatch\t--apply ef-mcp' -
OUT="$(env "${EFX[@]}" bash "$CU" --apply ef-mcp 2>&1)"; RC=$?
expect "N5b ...--apply adds the fork remote and builds local-build" 0 'ef-mcp: applied' 'no .fork. remote'
[ "$(git -C "$EF/home" remote get-url fork 2>&1)" = "file://$EF/fork.git" ] && [ "$(git -C "$EF/home" symbolic-ref -q --short HEAD)" = local-build ] \
  && ok "N5c ...the fork remote is the configured .fork= and HEAD is local-build" || no "N5c fork remote/branch after --apply"
# A commit made directly on local-build: the engine refuses to drop it, so the checker must not
# offer --apply (under auto that fails on every run) — it names the move instead, and auto holds.
printf 'console.log(2)\n' > "$EF/home/src.js"; commit "$EF/home" "hand edit on local-build"
run "${EFX[@]}"
expect "N6a hand commit on local-build -> unpushed (move it to fork/feat/*), not source-behind/--apply" 10 $'ef-mcp\tunpushed\t!move them to fork/feat/' $'ef-mcp\tsource-behind'
printf 'ef-mcp.fork=file://%s\nef-mcp.update=auto\n' "$EF/fork.git" > "$EF/cfg"; runa "${EFX[@]}"
expect "N6b ...auto holds it (never a failed apply every run)" 10 $'act\tef-mcp\theld' $'act\tef-mcp\tfailed'
# entry= outside dist/ never builds or stamps: the declaration is flagged
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s entry=build/index.js url=%s\nexit 0\n' "$EF/eb" "$EF/origin.git" > "$EF/lib/eb-mcp.sh"
run "${EFX[@]}"
expect "N7 entry= outside dist/ -> bad-declaration naming the rule" 10 $'eb-mcp\tbad-declaration.*entry must be under dist/' -
rm -f "$EF/lib/eb-mcp.sh"
# with auto, a bad-declaration is held, never applied (and failed) on every --full
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s entry=build/index.js url=%s\nexit 0\n' "$EF/eb" "$EF/origin.git" > "$EF/lib/eb-mcp.sh"
printf '{"mcpServers":{"ef":{"type":"stdio","command":"%s/lib/ef-mcp.sh","args":[]},"eb":{"type":"stdio","command":"%s/lib/eb-mcp.sh","args":[]}}}\n' "$EF" "$EF" > "$EF/claude.json"
printf 'eb-mcp.update=auto\n' > "$EF/cfg"; runa "${EFX[@]}"
expect "N7b auto + bad-declaration -> held, not applied" 10 $'act\teb-mcp\theld' $'act\teb-mcp\t(applied|failed)'
rm -f "$EF/lib/eb-mcp.sh"; printf '{"mcpServers":{"ef":{"type":"stdio","command":"%s/lib/ef-mcp.sh","args":[]}}}\n' "$EF" > "$EF/claude.json"
# a tracked shape=fork with no <l>.fork=: --apply cannot add a fork remote, so it is never offered
git clone -q "$EF/origin.git" "$EF/tf"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$EF/tf" "$EF/origin.git" > "$EF/lib/tf-mcp.sh"
printf '{"mcpServers":{"tf":{"type":"stdio","command":"%s/lib/tf-mcp.sh","args":[]}}}\n' "$EF" > "$EF/tfclaude.json"
: > "$EF/cfg"; run "${EFX[@]}" MCP_CLAUDE_JSON="$EF/tfclaude.json"
expect "N8 tracked shape=fork, no .fork=, no fork remote -> shape-mismatch without an --apply promise" 10 $'tf-mcp\tshape-mismatch\t!.*add the remote' $'tf-mcp\tshape-mismatch\t--apply'
rm -f "$EF/lib/tf-mcp.sh"

# README's revert procedure, run as written: revert to an earlier commit, then go forward again.
RV="$T/rv"; mkdir -p "$RV/lib"; cp "$VLIB/_mcp-decl.sh" "$RV/lib/"; git init -q -b main "$RV/seed"
printf '{"name":"rv","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$RV/seed/package.json"
printf '{"name":"rv","version":"0.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"rv","version":"0.0.0"}}}\n' > "$RV/seed/package-lock.json"
printf 'console.log("v1")\n' > "$RV/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$RV/seed/.gitignore"; commit "$RV/seed" v1
git clone -q --bare "$RV/seed" "$RV/origin.git"; git clone -q "$RV/origin.git" "$RV/work"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s url=%s\nexit 0\n' "$RV/work" "$RV/origin.git" > "$RV/lib/rv-mcp.sh"
printf '{"mcpServers":{"rv":{"type":"stdio","command":"%s/lib/rv-mcp.sh","args":[]}}}\n' "$RV" > "$RV/claude.json"
RVX=(MCP_LIB_DIR="$RV/lib" MCP_REGISTERED_LIB="$RV/lib" MCP_CLAUDE_JSON="$RV/claude.json" OPENBRAIN_VAULT=/nonexistent MCP_NO_FETCH=1
     MCP_PS_FILE="$F/ps.txt" MCP_UPDATE_STATE="$RV/state" MCP_CONFIG_FILE="$RV/cfg")
: > "$RV/cfg"; env "${RVX[@]}" bash "$CU" --apply rv-mcp >/dev/null 2>&1; v1="$(git -C "$RV/work" rev-parse HEAD)"
printf 'console.log("v2")\n' > "$RV/seed/src.js"; commit "$RV/seed" v2; git -C "$RV/seed" push -q "$RV/origin.git" main
git -C "$RV/work" fetch -q origin; env "${RVX[@]}" bash "$CU" --apply rv-mcp >/dev/null 2>&1
revert_line="$(grep 'To revert a server' "$VAULT/README.md")"
revert_cmd="$(printf '%s\n' "$revert_line" | grep -o '`git checkout <sha>[^`]*`' | tr -d '`')"
[ -n "$revert_cmd" ] || { echo "FIXTURE BUG: no revert command in README.md" >&2; exit 90; }
( cd "$RV/work" && eval "${revert_cmd//<sha>/$v1}" ) >/dev/null 2>&1
run "${RVX[@]}"
expect "RV1 after README's revert: the checker reports off-branch (what README says), and the dist runs v1" 10 $'rv-mcp\toff-branch' -
[ "$(node "$RV/work/dist/index.js")" = v1 ] || no "RV1b reverted dist is not v1"
printf '%s\n' "$revert_line" | grep -q '`off-branch`' && ok "RV1c README names off-branch as what the checker shows" || no "RV1c README names a different class"
fwd="$(printf '%s\n' "$revert_line" | grep -o '`git switch <branch>`' | tr -d '`')"
[ -z "$fwd" ] || ( cd "$RV/work" && eval "${fwd//<branch>/main}" ) >/dev/null 2>&1
OUT="$(env "${RVX[@]}" bash "$CU" --apply rv-mcp 2>&1)"; RC=$?
expect "RV2 README's way forward (switch back, then --apply) rebuilds the tracked branch" 0 'rv-mcp: applied' 'not on main'
[ "$(node "$RV/work/dist/index.js")" = v2 ] && ok "RV2b ...and the dist runs v2 again" || no "RV2b dist after going forward: $(node "$RV/work/dist/index.js" 2>&1)"

echo "== W. launcher paths: first-clone branch, npm args, lifecycle scripts"
# the first clone checks out the branch the build tracks
git -C "$F/other" push -q origin main:dev
mklauncher "$H/.config/openbrain/lib/cb-mcp.sh" "# openbrain-mcp: shape=checkout dir=$T/lazy-br sub=packages/a url=$F/origin"
printf 'cb-mcp.branch=dev\n' > "$H/.config/openbrain/mcp-config"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/cb-mcp.sh" 2>&1)"; RC=$?
expect "U16 first launch with .branch=dev clones dev and builds"  0 'Usage: stub' 'not on dev'
rm -f "$H/.config/openbrain/mcp-config"
# exec_declared_npm passes the launcher's arguments through
cat > "$H/.config/openbrain/lib/n2-mcp.sh" <<'EOF'
#!/usr/bin/env bash
# openbrain-mcp: shape=npm pkg=@x/n2
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
exec_declared_npm --slug "$1"
EOF
printf '1.0.0\n' > "$H/.config/openbrain/mcp-updates/n2-mcp.applied"
OUT="$(HOME="$H" PATH="$T/fakebin:$PATH" bash "$H/.config/openbrain/lib/n2-mcp.sh" acct-1 2>&1)"; RC=$?
expect "U17 exec_declared_npm passes its arguments to the server" 0 'npx --yes @x/n2@1\.0\.0 --slug acct-1$' -
# dependency install never runs package lifecycle scripts (both engine modes, default commands)
LC="$T/lc"; mkdir -p "$LC/lib"; cp "$VLIB/_mcp-decl.sh" "$LC/lib/"; git init -q -b main "$LC/seed"
printf '{"name":"lc","version":"0.0.0","scripts":{"postinstall":"touch LIFECYCLE_RAN","prepare":"touch PREPARE_RAN","build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$LC/seed/package.json"
printf '{"name":"lc","version":"0.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"lc","version":"0.0.0","hasInstallScript":true}}}\n' > "$LC/seed/package-lock.json"
printf 'console.log(1)\n' > "$LC/seed/src.js"; printf 'dist/\nnode_modules/\nLIFECYCLE_RAN\nPREPARE_RAN\n' > "$LC/seed/.gitignore"; commit "$LC/seed" init
git clone -q --bare "$LC/seed" "$LC/origin.git"; git clone -q "$LC/origin.git" "$LC/ck"
OUT="$(MCP_SKIP_FETCH=1 bash "$ENGINE" --checkout lc-mcp "$LC/ck" . main 2>&1)"; RC=$?
expect "U18a checkout engine, default install command, builds"   0 'OK — built' -
[ ! -e "$LC/ck/LIFECYCLE_RAN" ] && [ ! -e "$LC/ck/PREPARE_RAN" ] && ok "U18b ...no lifecycle script ran (npm ci --ignore-scripts)" || no "U18b a lifecycle script ran during the checkout install"
git clone -q --bare "$LC/seed" "$LC/fork.git"; git clone -q "$LC/origin.git" "$LC/fk"; git -C "$LC/fk" remote add fork "$LC/fork.git"; git -C "$LC/fk" fetch -q fork
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$LC/fk" "$LC/origin.git" > "$LC/lib/lf-mcp.sh"
OUT="$(MCP_SKIP_FETCH=1 MCP_CONFIG_FILE="$LC/nocfg" bash "$ENGINE" "$LC/lib/lf-mcp.sh" 2>&1)"; RC=$?
expect "U18c fork engine, default build command, builds"         0 'OK — built' -
[ ! -e "$LC/fk/LIFECYCLE_RAN" ] && [ ! -e "$LC/fk/PREPARE_RAN" ] && ok "U18d ...no lifecycle script ran (fork path)" || no "U18d a lifecycle script ran during the fork install"
# fork mode builds, then tests (the same order as --checkout): a test that needs dist/ passes
BT="$T/bt"; mkdir -p "$BT/lib"; git init -q -b main "$BT/seed"
printf '{"name":"bt","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js","test":"test -f dist/index.js"}}\n' > "$BT/seed/package.json"
printf '{"name":"bt","version":"0.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"bt","version":"0.0.0"}}}\n' > "$BT/seed/package-lock.json"
printf 'console.log(1)\n' > "$BT/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$BT/seed/.gitignore"; commit "$BT/seed" init
git clone -q --bare "$BT/seed" "$BT/origin.git"; git clone -q --bare "$BT/seed" "$BT/fork.git"
git clone -q "$BT/origin.git" "$BT/fk"; git -C "$BT/fk" remote add fork "$BT/fork.git"; git -C "$BT/fk" fetch -q fork
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=fork dir=%s url=%s\nexit 0\n' "$BT/fk" "$BT/origin.git" > "$BT/lib/bt-mcp.sh"
OUT="$(MCP_SKIP_FETCH=1 MCP_CONFIG_FILE="$BT/nocfg" bash "$ENGINE" "$BT/lib/bt-mcp.sh" 2>&1)"; RC=$?
expect "U20 fork engine, default command: build before test (a test that needs dist/ passes)" 0 'OK — built' -
# a checkout's declared entry= is the file the engine smoke-checks (passed by its callers)
EN="$T/en"; mkdir -p "$EN/lib"; git init -q -b main "$EN/seed"
printf '{"name":"en","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/server.js"}}\n' > "$EN/seed/package.json"
printf 'console.log(1)\n' > "$EN/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$EN/seed/.gitignore"; commit "$EN/seed" init
git clone -q --bare "$EN/seed" "$EN/origin.git"; git clone -q "$EN/origin.git" "$EN/work"
printf '#!/usr/bin/env bash\n# openbrain-mcp: shape=checkout dir=%s entry=dist/server.js url=%s\nexit 0\n' "$EN/work" "$EN/origin.git" > "$EN/lib/en-mcp.sh"
OUT="$(env MCP_LIB_DIR="$EN/lib" MCP_UPDATE_STATE="$EN/state" MCP_CONFIG_FILE="$EN/nocfg" MCP_CHECKOUT_BUILD_CMD='npm run build --silent' bash "$CU" --apply en-mcp 2>&1)"; RC=$?
expect "U21 checkout with entry=dist/server.js -> --apply builds (the smoke check parses the declared entry)" 0 'en-mcp: applied' 'smoke-test failed'

echo "== S. build safety: stamp-time mixed check, unstamped dist runs as-is, launch vs a running build, lockfile skip, clone-temp cleanup"
SX="$T/sx"; mkdir -p "$SX"; git init -q -b main "$SX/seed"
printf '{"name":"sx","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js && cp a.js dist/a.js"}}\n' > "$SX/seed/package.json"
printf 'console.log(1)\n' > "$SX/seed/src.js"; printf '// v1\n' > "$SX/seed/a.js"; printf 'dist/\nnode_modules/\n' > "$SX/seed/.gitignore"; commit "$SX/seed" c1
git clone -q --bare "$SX/seed" "$SX/origin.git"; git clone -q "$SX/origin.git" "$SX/work"
sxb(){ MCP_SKIP_FETCH=1 bash "$ENGINE" --checkout sx-mcp "$SX/work" . main; }
OUT="$(MCP_CHECKOUT_BUILD_CMD='npm run build --silent' sxb 2>&1)"; RC=$?
expect "S0 fixture: first build stamped"                                  0 'OK — built' -
# same-second writes are never a false positive (simulate a 1-second-resolution filesystem:
# every output's mtime truncated to the current whole second, i.e. the marker's own second)
OUT="$(MCP_CHECKOUT_BUILD_CMD='npm run build --silent && touch -t "$(date +%Y%m%d%H%M.%S)" dist/index.js dist/a.js' sxb 2>&1)"; RC=$?
expect "S1a outputs stamped in the marker's own second -> no false 'mixed'" 0 'OK — built' 'NOT stamping'
# A runs a long build; its lock goes age-stale; B breaks it,
# "recovers" A's .dist.bak (the old v1 tree) underneath A and leaves; A then finishes into a
# mixed dist/ (a.js=v1, index.js=v2). A must fail loudly and must not stamp the new commit.
sleep 2
printf '// v2\n' > "$SX/work/a.js"; printf 'console.log(2)\n' > "$SX/work/src.js"; commit "$SX/work" c2; c2="$(git -C "$SX/work" rev-parse HEAD)"
( MCP_CHECKOUT_BUILD_CMD='mkdir -p dist && cp a.js dist/a.js && sleep 3 && cp src.js dist/index.js' sxb > "$SX/A.out" 2>&1; echo "rc=$?" >> "$SX/A.out" ) & sxa=$!
sleep 1; touch -t 202001010000 "$SX/work.openbrain-build.lock"
OUT="$(MCP_BUILD_ONLY_IF_MISSING="$SX/work/dist/index.js" sxb 2>&1)"; RC=$?
wait "$sxa"
if ! grep -q '^rc=0$' "$SX/A.out" && grep -q 'NOT stamping' "$SX/A.out" && [ "$(cat "$SX/work/dist/.built-from" 2>/dev/null)" != "$c2" ]; then
  ok "S1b lock broken under a long build -> A fails loudly and leaves dist/ unstamped (no .built-from claiming the new commit)"
else no "S1b mixed dist (a.js=$(cat "$SX/work/dist/a.js" 2>/dev/null) built-from=$(cat "$SX/work/dist/.built-from" 2>/dev/null) want-not=$c2)"; sed 's/^/        A: /' "$SX/A.out"; fi
# The same takeover while the NEW holder still holds the lock when the old one finishes: the
# old holder must fail (never "OK — built") and its exit must not remove the new holder's lock.
sleep 1
( MCP_CHECKOUT_BUILD_CMD='sleep 3 && npm run build --silent' sxb > "$SX/A2.out" 2>&1; echo "rc=$?" >> "$SX/A2.out" ) & sxa=$!
sleep 1; touch -t 202001010000 "$SX/work.openbrain-build.lock"
( MCP_CHECKOUT_BUILD_CMD='sleep 5 && npm run build --silent' sxb > "$SX/B2.out" 2>&1; echo "rc=$?" >> "$SX/B2.out" ) & sxb2=$!
wait "$sxa"; lk_after_a="$([ -d "$SX/work.openbrain-build.lock" ] && echo held || echo GONE)"
wait "$sxb2"
if ! grep -q '^rc=0$' "$SX/A2.out" && ! grep -q 'OK — built' "$SX/A2.out" && [ "$lk_after_a" = held ]; then
  ok "S1c lock taken over while the new holder still builds -> old holder fails (no 'OK — built'), new holder's lock survives its exit"
else no "S1c takeover (new holder's lock after the old exited: $lk_after_a)"; sed 's/^/        A: /' "$SX/A2.out"; sed 's/^/        B: /' "$SX/B2.out"; fi
# An unstamped dist/ (e.g. built before provenance stamps existed) on a dirty, off-main checkout:
# the launcher runs it and never calls the engine (here a failing stand-in); the checker reports it.
mklauncher "$H/.config/openbrain/lib/sx-mcp.sh" "# openbrain-mcp: shape=checkout dir=$SX/work url=$SX/origin.git"
rm -f "$SX/work/dist/.built-from"; : > "$SX/work/notes.txt"; git -C "$SX/work" switch -q -c side
printf '#!/bin/sh\n: > "%s/ENGINE_RAN"; exit 1\n' "$SX" > "$SX/fake-engine.sh"
OUT="$(HOME="$H" MCP_LOCAL_BUILD_SH="$SX/fake-engine.sh" bash "$H/.config/openbrain/lib/sx-mcp.sh" 2>&1)"; RC=$?
expect "S2a unstamped dist/ on a dirty, off-main checkout -> the launcher runs it (no rebuild, no refusal, no false 'missing')" 0 '^[12]$' 'auto-installing|missing|failed'
[ ! -e "$SX/ENGINE_RAN" ] && ok "S2b ...the build engine is never invoked over a dist/ whose entry exists" || no "S2b the launcher invoked the engine"
printf '{"mcpServers":{"sx":{"type":"stdio","command":"%s/sx-mcp.sh","args":[]}}}\n' "$H/.config/openbrain/lib" > "$SX/claude.json"
run MCP_LIB_DIR="$H/.config/openbrain/lib" MCP_REGISTERED_LIB="$H/.config/openbrain/lib" MCP_CLAUDE_JSON="$SX/claude.json" OPENBRAIN_VAULT=/nonexistent \
    MCP_NO_FETCH=1 MCP_PS_FILE="$F/ps.txt" MCP_UPDATE_STATE="$T/sxstate" MCP_CONFIG_FILE="$T/sxcfg"
expect "S2d ...and the checker still reports it (unproven-build)" 10 $'sx-mcp\tunproven-build' -
git -C "$SX/work" switch -q main; rm -f "$SX/work/notes.txt" "$H/.config/openbrain/lib/sx-mcp.sh"
# ...but a dist/ that a build is still testing, or that a killed build left behind, is not a
# finished build: the launcher waits for the build / restores the last-good dist/ first.
ML="$T/ml"; git init -q -b main "$ML/seed"
printf '{"name":"ml","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$ML/seed/package.json"
printf 'console.log("v1")\n' > "$ML/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$ML/seed/.gitignore"; commit "$ML/seed" v1
git clone -q --bare "$ML/seed" "$ML/origin.git"; git clone -q "$ML/origin.git" "$ML/work"
mlb(){ MCP_SKIP_FETCH=1 MCP_CHECKOUT_BUILD_CMD="$1" bash "$ENGINE" --checkout ml-mcp "$ML/work" . main; }
mlb 'npm run build --silent' >/dev/null 2>&1
mklauncher "$H/.config/openbrain/lib/ml-mcp.sh" "# openbrain-mcp: shape=checkout dir=$ML/work url=$ML/origin.git"
printf 'console.log("v2")\n' > "$ML/work/src.js"; commit "$ML/work" v2
( mlb 'npm run build --silent && sleep 4 && false' > "$ML/A.out" 2>&1 ) & mla=$!
sleep 2   # v2 is built and under test; v1 sits in .dist.bak
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/ml-mcp.sh" 2>&1)"; RC=$?; wait "$mla"
expect "S6a launch while an apply tests v2 (tests then fail) -> waits, runs the restored v1, never the untested v2" 0 '^v1$' '^v2$'
mv "$ML/work/dist" "$ML/work/.dist.bak"; mkdir "$ML/work/dist"; printf 'console.log("untested")\n' > "$ML/work/dist/index.js"; : > "$ML/work/notes.txt"
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/ml-mcp.sh" 2>&1)"; RC=$?
expect "S6b killed build's .dist.bak + untested dist/, dirty checkout -> launch restores the last-good and runs it" 0 '^v1$' 'untested|uncommitted'
[ ! -e "$ML/work/.dist.bak" ] && ok "S6c ...no .dist.bak left" || no "S6c .dist.bak still there"
rm -f "$ML/work/notes.txt" "$H/.config/openbrain/lib/ml-mcp.sh"
# A first build (no previous dist/) under test: its untested output must not run either.
FB="$T/fb"; git init -q -b main "$FB/seed"
printf '{"name":"fb","version":"0.0.0","scripts":{"build":"node build.js"}}\n' > "$FB/seed/package.json"
printf '{"name":"fb","version":"0.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fb","version":"0.0.0"}}}\n' > "$FB/seed/package-lock.json"
printf 'require("fs").mkdirSync("dist",{recursive:true}); require("fs").writeFileSync("dist/index.js", "console.log(" + JSON.stringify(process.env.BUILD_TAG || "tested") + ")\\n")\n' > "$FB/seed/build.js"
printf 'dist/\nnode_modules/\n' > "$FB/seed/.gitignore"; commit "$FB/seed" init
git clone -q --bare "$FB/seed" "$FB/origin.git"; git clone -q "$FB/origin.git" "$FB/work"
mklauncher "$H/.config/openbrain/lib/fb-mcp.sh" "# openbrain-mcp: shape=checkout dir=$FB/work url=$FB/origin.git"
( MCP_SKIP_FETCH=1 BUILD_TAG=untested MCP_CHECKOUT_BUILD_CMD='npm run build --silent && sleep 4 && false' bash "$ENGINE" --checkout fb-mcp "$FB/work" . main > "$FB/A.out" 2>&1 ) & fba=$!
sleep 2   # the first build's output exists and is under test
OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/fb-mcp.sh" 2>&1)"; RC=$?; wait "$fba"
expect "S9 launch during a FIRST build's test phase -> never runs the untested output" 0 '^tested$' 'untested'
grep -q 'no previous build to keep' "$FB/A.out" && ! grep -q 'last-good' "$FB/A.out" \
  && ok "S9b ...and the failed first build says there was nothing to keep (no 'last-good' claim)" || { no "S9b first-build failure message"; sed 's/^/        A: /' "$FB/A.out"; }
rm -f "$H/.config/openbrain/lib/fb-mcp.sh"
# A first build that fails the stamp-time mixed check (a build that preserves mtimes) leaves
# an unstamped dist/ and no .dist.bak: the first launch fails, later launches run it.
PM="$T/pm"; git init -q -b main "$PM/seed"
printf '{"name":"pm","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp -p src.js dist/index.js"}}\n' > "$PM/seed/package.json"
printf '{"name":"pm","version":"0.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"pm","version":"0.0.0"}}}\n' > "$PM/seed/package-lock.json"
printf 'console.log("ran")\n' > "$PM/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$PM/seed/.gitignore"; commit "$PM/seed" init
git clone -q --bare "$PM/seed" "$PM/origin.git"; git clone -q "$PM/origin.git" "$PM/work"; touch -t 202001010000 "$PM/work/src.js"
mklauncher "$H/.config/openbrain/lib/pm-mcp.sh" "# openbrain-mcp: shape=checkout dir=$PM/work url=$PM/origin.git"
s10=""; for i in 1 2 3; do o="$(HOME="$H" bash "$H/.config/openbrain/lib/pm-mcp.sh" 2>&1)"; case "$o" in *ran) s10="$s10 ran" ;; *) s10="$s10 fail" ;; esac; done
[ "$s10" = " fail ran ran" ] && [ ! -e "$PM/work/.dist.bak" ] \
  && ok "S10 first build fails the mixed check -> launches: fail ran ran, no .dist.bak left" || no "S10 launches:$s10 (.dist.bak $([ -e "$PM/work/.dist.bak" ] && echo LEFT || echo none))"
printf '{"mcpServers":{"pm":{"type":"stdio","command":"%s/pm-mcp.sh","args":[]}}}\n' "$H/.config/openbrain/lib" > "$PM/claude.json"
run MCP_LIB_DIR="$H/.config/openbrain/lib" MCP_REGISTERED_LIB="$H/.config/openbrain/lib" MCP_CLAUDE_JSON="$PM/claude.json" OPENBRAIN_VAULT=/nonexistent \
    MCP_NO_FETCH=1 MCP_PS_FILE="$F/ps.txt" MCP_UPDATE_STATE="$T/pmstate" MCP_CONFIG_FILE="$T/pmcfg"
expect "S10b ...and the checker reports it unproven-build (what the engine's message says)" 10 $'pm-mcp\tunproven-build' $'pm-mcp\tstranded-build'
rm -f "$H/.config/openbrain/lib/pm-mcp.sh"
# npm ci is skipped while node_modules matches the lockfile
git clone -q "$LC/origin.git" "$LC/sk"
lcb(){ OUT="$(MCP_SKIP_FETCH=1 bash "$ENGINE" --checkout lc-mcp "$LC/sk" . main 2>&1)"; RC=$?; }
lcb; expect "S4a first build runs npm ci"                          0 'OK — built' 'skipping npm ci'
lcb; expect "S4b lockfile unchanged -> npm ci skipped"           0 'skipping npm ci' -
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); open(p,"w").write(json.dumps(d, indent=4)+"\n")' "$LC/sk/package-lock.json"; commit "$LC/sk" relock
lcb; expect "S4c lockfile changed -> npm ci runs"                0 'OK — built' 'skipping npm ci'
rm "$LC/sk/node_modules/.openbrain-lockfile-hash"
lcb; expect "S4d marker missing -> npm ci runs"                  0 'OK — built' 'skipping npm ci'
rm -rf "${LC:?}/sk/node_modules"
lcb; expect "S4e node_modules missing -> npm ci runs"            0 'OK — built' 'skipping npm ci'
# a source with no package-lock.json: the install writes none, so the next build isn't refused as dirty
NL="$T/nl"; git init -q -b main "$NL/seed"
printf '{"name":"nl","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$NL/seed/package.json"
printf 'console.log(1)\n' > "$NL/seed/src.js"; printf 'dist/\nnode_modules/\n' > "$NL/seed/.gitignore"; commit "$NL/seed" init
git clone -q --bare "$NL/seed" "$NL/origin.git"; git clone -q "$NL/origin.git" "$NL/work"
nlb(){ OUT="$(MCP_SKIP_FETCH=1 bash "$ENGINE" --checkout nl-mcp "$NL/work" . main 2>&1)"; RC=$?; }
nlb; expect "S4f no lockfile: first build (npm install)"          0 'OK — built' -
[ -z "$(git -C "$NL/work" status --porcelain)" ] && ok "S4g ...leaves the checkout clean (no package-lock.json written)" || no "S4g checkout dirty after a no-lockfile install: $(git -C "$NL/work" status --porcelain | tr '\n' ' ')"
nlb; expect "S4h ...so the next build is not refused as dirty work" 0 'OK — built' 'uncommitted changes'
# orphaned clone temp dirs are cleaned (dead pid), a live one is left alone
if ! ps -p 99999 >/dev/null 2>&1; then
  mkdir -p "$T/ct.openbrain-clone-tmp.99999" "$T/ct.openbrain-clone-tmp.$$"
  mklauncher "$H/.config/openbrain/lib/ct-mcp.sh" "# openbrain-mcp: shape=checkout dir=$T/ct sub=packages/a url=$F/origin"
  OUT="$(HOME="$H" bash "$H/.config/openbrain/lib/ct-mcp.sh" 2>&1)"; RC=$?
  expect "S5a lazy clone still works"                            0 'Usage: stub' -
  [ ! -e "$T/ct.openbrain-clone-tmp.99999" ] && ok "S5b the dead pid's orphaned clone temp dir was removed" || no "S5b orphan left behind"
  [ -d "$T/ct.openbrain-clone-tmp.$$" ] && ok "S5c a live pid's clone temp dir survives" || no "S5c live temp dir removed"
  rm -rf "${T:?}/ct.openbrain-clone-tmp.$$"; rm -f "$H/.config/openbrain/lib/ct-mcp.sh"
else skip "S5" "pid 99999 exists on this machine"; fi

echo "== V. bootstrap/lib/validate.sh under /bin/bash (3.2) — hermetic runtime"
V="$T/val"; mkdir -p "$V/cfg/lib" "$V/cfg/tokens"
cp "$VLIB"/*-mcp.sh "$VLIB/_common.sh" "$VLIB/_mcp-decl.sh" "$VLIB/mcp-local-build.sh" "$V/cfg/lib/"; chmod 755 "$V/cfg/lib/"*
printf 'FATHOM_API_KEY=x\n' > "$V/cfg/.env"; chmod 600 "$V/cfg/.env"
printf 'root=%s\n' "$V/root" > "$V/cfg/mcp-config"
VX=(OPENBRAIN_CONFIG_DIR="$V/cfg" OPENBRAIN_LIB_DIR="$V/cfg/lib" OPENBRAIN_ENV_FILE="$V/cfg/.env" OPENBRAIN_TOKEN_DIR="$V/cfg/tokens")
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V1 the per-MCP check resolves the launcher (not '<x>.sh not installed')" "$RC" "fathom-mcp not built at $V/root/fathom-mcp" 'fathom-mcp\.sh not installed'
expect "V2 a configured MCP with no clone is never reported 'not needed'" "$RC" - 'fathom-mcp not needed'
rm "$V/cfg/lib/mcp-local-build.sh"
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V3 a missing installed mcp-local-build.sh is flagged"     "$RC" 'mcp-local-build\.sh not installed' -
cp "$VLIB/mcp-local-build.sh" "$V/cfg/lib/"; rm "$V/cfg/lib/_mcp-decl.sh"
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V4 a missing installed _mcp-decl.sh is flagged in the launcher list" "$RC" '_mcp-decl\.sh not installed — run' -
cp "$VLIB/_mcp-decl.sh" "$V/cfg/lib/"; mkdir -p "$V/root/fathom-mcp"; git -C "$V/root/fathom-mcp" init -q -b main
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V5 a clone whose origin cannot be read -> CANNOT-CHECK, never a silent skip" "$RC" 'CANNOT-CHECK: fathom-mcp origin not compared' -
git -C "$V/root/fathom-mcp" remote add origin "https://example.com/someone-else/fathom-mcp.git"
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V6 origin mismatch offers set-url OR the per-machine <l>.url= / owner= override" "$RC" 'set-url origin .*or, if that origin is intentional, set fathom-mcp\.url= \(or owner=\)' -
fu="$(grep -m1 '^# openbrain-mcp:' "$V/cfg/lib/fathom-mcp.sh" | tr ' ' '\n' | sed -n 's/^url=//p')"
git -C "$V/root/fathom-mcp" remote set-url origin "$fu"
printf 'root=%s\nfathom-mcp.fork=%s\n' "$V/root" "$fu" > "$V/cfg/mcp-config"
OUT="$(env "${VX[@]}" /bin/bash "$VAULT/bootstrap/lib/validate.sh" 2>&1)"; RC=$?
expect "V7 a .fork= equal to origin (re-parented, no fork remote) is not CANNOT-CHECK" "$RC" 'fathom-mcp not built' 'fathom-mcp fork remote not compared|fathom-mcp origin is'

echo; printf 'TOTAL: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
