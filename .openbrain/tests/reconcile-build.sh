#!/usr/bin/env bash
# Harness for reconcile-runtime.sh's build step (build_registered_sources):
# registered-launcher filter, subshell guard surviving a failing build, and
# "RESTART REQUIRED" printed before any build output. Hermetic: every runtime
# locus (CONFIG_DIR/LIB_DIR/ENV_FILE/CLAUDE_JSON/SETTINGS_FILE) is overridden
# to a temp dir — this NEVER reads or writes ~/.config/openbrain or the real
# ~/.claude.json. The only real thing it touches is a scratch git repo used as
# a stand-in "origin" for fathom-mcp (via a per-machine .url= override), so no
# network call is ever made.
set -uo pipefail
VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECONCILE="$VAULT/.openbrain/lib/reconcile-runtime.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-build-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
commit(){ git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }

# --- a tiny local "origin" for fathom-mcp, standing in for the real github URL ---
mkdir -p "$T/seed"; git -C "$T/seed" init -q -b main
printf '{"name":"fathom-mcp","version":"0.0.0","scripts":{"build":"mkdir -p dist && cp src.js dist/index.js"}}\n' > "$T/seed/package.json"
printf 'console.log(1)\n' > "$T/seed/src.js"
printf 'dist/\nnode_modules/\n' > "$T/seed/.gitignore"
commit "$T/seed" init
git clone -q --bare "$T/seed" "$T/origin.git"

setup_runtime(){  # fresh empty CONFIG_DIR/LIB_DIR/root every call — launcher_drift is forced every run
  rm -rf "$T/config" "$T/claude.json" "$T/settings.json" "$T/root"
  mkdir -p "$T/config"
  : > "$T/config/.env"; printf 'FATHOM_API_KEY=test123\n' >> "$T/config/.env"   # only fathom gets registered
  printf '{"mcpServers":{}}\n' > "$T/claude.json"
  printf '{}\n' > "$T/settings.json"
  printf 'root=%s\nfathom-mcp.url=file://%s\n' "$T/root" "$T/origin.git" > "$T/config/mcp-config"
}
ENV=(OPENBRAIN_CONFIG_DIR="$T/config" OPENBRAIN_LIB_DIR="$T/config/lib" OPENBRAIN_ENV_FILE="$T/config/.env"
     OPENBRAIN_CLAUDE_JSON="$T/claude.json" OPENBRAIN_SETTINGS_FILE="$T/settings.json" OPENBRAIN_TOKEN_DIR="$T/config/tokens"
     MCP_BUILD_CMD="npm run build --silent")

echo "== reconcile-runtime.sh --apply: registered-filter + RESTART-before-builds + a successful build"
setup_runtime
OUT="$(env "${ENV[@]}" bash "$RECONCILE" --apply 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
restart_line="$(printf '%s\n' "$OUT" | grep -n 'RESTART REQUIRED' | head -1 | cut -d: -f1)"
build_line="$(printf '%s\n' "$OUT" | grep -n 'auto-installing from declaration\|cloning file://' | head -1 | cut -d: -f1)"
if [ -n "$restart_line" ] && [ -n "$build_line" ] && [ "$restart_line" -lt "$build_line" ]; then
  ok "R1 RESTART REQUIRED printed before any build/clone output"
else
  no "R1 ordering (restart_line=$restart_line build_line=$build_line)"
fi
[ -f "$T/root/fathom-mcp/dist/index.js" ] && ok "R2 fathom-mcp (registered, checkout shape) actually got built" || no "R2 fathom not built"
r3=0; n3=0
for l in "$VAULT"/.openbrain/lib/*-mcp.sh; do
  other="$(basename "$l" .sh)"; [ "$other" = fathom-mcp ] && continue; n3=$((n3+1))
  [ -e "$T/root/$other" ] && { no "R3 $other should never be cloned — it isn't registered (no account configured)"; r3=1; break; }
done
[ "$n3" -gt 0 ] || no "R3 FIXTURE: no other launchers to check"
[ "$r3" = 1 ] || [ "$n3" -eq 0 ] || ok "R3 only the registered launcher (fathom) was built — the $n3 unregistered ones were never touched"

echo "== reconcile-runtime.sh --apply: a failing build is caught by the subshell guard, not fatal to the run"
setup_runtime
# Break the build: the seed's build script now fails.
git -C "$T/seed" show HEAD:package.json > /dev/null   # sanity: repo has history
( cd "$T/seed" && printf '{"name":"fathom-mcp","version":"0.0.0","scripts":{"build":"exit 1"}}\n' > package.json && git -c user.name=t -c user.email=t@t commit -qam "break the build" && git push -q "$T/origin.git" HEAD:main )
OUT2="$(env "${ENV[@]}" bash "$RECONCILE" --apply 2>&1)"; RC2=$?
printf '%s\n' "$OUT2" | sed 's/^/    /'
printf '%s\n' "$OUT2" | grep -qi 'ensure_mcp_server failed' \
  && ok "R4 failing build reported as a warning (subshell-caught)" || no "R4 no failure warning"
printf '%s\n' "$OUT2" | grep -q 'RESTART REQUIRED' \
  && ok "R5 the run still completed and printed RESTART REQUIRED despite the failed build" || no "R5 run aborted early"
# R6: the failure names a remedy this layer actually has (relaunch), not another tool's command.
if printf '%s\n' "$OUT2" | grep -q 'build failed (see above) — fix the cause, then relaunch' && ! printf '%s\n' "$OUT2" | grep -q 'check-updates'; then
  ok "R6 the build-failure message names a generic remedy (no check-updates.sh)"
else no "R6 build-failure remedy text"; fi

echo "== reconcile-runtime.sh --apply: an origin that cannot be read is CANNOT-CHECK, never skipped"
setup_runtime; mkdir -p "$T/root"
git clone -q "$T/origin.git" "$T/root/fathom-mcp"; git -C "$T/root/fathom-mcp" remote remove origin
mkdir -p "$T/root/fathom-mcp/dist"; cp "$T/root/fathom-mcp/src.js" "$T/root/fathom-mcp/dist/index.js"
git -C "$T/root/fathom-mcp" rev-parse HEAD > "$T/root/fathom-mcp/dist/.built-from"   # built + stamped: only the origin check is exercised
OUT4="$(env "${ENV[@]}" bash "$RECONCILE" --apply 2>&1)"
printf '%s\n' "$OUT4" | grep -q "fathom-mcp: CANNOT-CHECK origin" \
  && ok "R8 an unreadable origin is reported CANNOT-CHECK, not silently skipped" || { no "R8 unreadable origin skipped silently"; printf '%s\n' "$OUT4" | sed 's/^/        /'; }

echo "== reconcile-runtime.sh --apply: an origin mismatch offers the per-machine override, not only set-url"
setup_runtime; mkdir -p "$T/root"
git clone -q "$T/origin.git" "$T/root/fathom-mcp"; git -C "$T/root/fathom-mcp" remote set-url origin "https://example.com/someone-else/fathom-mcp.git"
mkdir -p "$T/root/fathom-mcp/dist"; cp "$T/root/fathom-mcp/src.js" "$T/root/fathom-mcp/dist/index.js"
git -C "$T/root/fathom-mcp" rev-parse HEAD > "$T/root/fathom-mcp/dist/.built-from"
OUT5="$(env "${ENV[@]}" bash "$RECONCILE" --apply 2>&1)"
printf '%s\n' "$OUT5" | grep -q "fathom-mcp: origin is .*set-url origin .*or, if that origin is intentional, set fathom-mcp.url= (or owner=) in $T/config/mcp-config" \
  && ok "R9 origin mismatch names both remedies: re-point, or set <l>.url= / owner= for an intentional origin" || { no "R9 origin-mismatch remedy"; printf '%s\n' "$OUT5" | grep -i origin | sed 's/^/        /'; }
printf '%s\n' "$OUT2" | grep -q 'no previous build to keep' && ! printf '%s\n' "$OUT2" | grep -q 'last-good build' \
  && ok "R10 a failed FIRST build says there was nothing to keep, not 'the last-good build'" || no "R10 first-build failure message claims a last-good build"

echo "== register-mcps.sh: a non-empty .openbrain/mcp/ gets a loud notice"
# A throwaway copy of the vault's bootstrap + .openbrain/lib, so .openbrain/mcp/ can be created
# without touching the real vault.
FV="$T/fv"; mkdir -p "$FV/.openbrain"; cp -R "$VAULT/bootstrap" "$FV/"; cp -R "$VAULT/.openbrain/lib" "$FV/.openbrain/"
setup_runtime
OUT3="$(env "${ENV[@]}" bash "$FV/bootstrap/lib/register-mcps.sh" 2>&1)"
printf '%s\n' "$OUT3" | grep -q 'no longer synced' && no "R7a notice printed with no .openbrain/mcp/ at all" || ok "R7a no notice without .openbrain/mcp/"
mkdir -p "$FV/.openbrain/mcp/custom-server"; : > "$FV/.openbrain/mcp/custom-server/package.json"
OUT3="$(env "${ENV[@]}" bash "$FV/bootstrap/lib/register-mcps.sh" 2>&1)"
printf '%s\n' "$OUT3" | grep -q '\.openbrain/mcp/ is not empty, but custom MCP server copies there are no longer synced or built' \
  && ok "R7b non-empty .openbrain/mcp/ -> loud notice" || { no "R7b no notice for a non-empty .openbrain/mcp/"; printf '%s\n' "$OUT3" | sed 's/^/        /'; }

echo; printf 'TOTAL: %s pass, %s fail\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
