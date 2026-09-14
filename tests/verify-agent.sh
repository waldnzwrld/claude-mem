#!/usr/bin/env bash
#
# verify-agent.sh — AGENT-IN-THE-LOOP proof.
#
# Unlike verify.sh (which drives memory-index directly), this points a REAL running Claude
# agent at an isolated copy of the fixture and proves the end-to-end runtime behaves as
# expected: the actual outl MCP tools, the actual PostToolUse hook, and the actual `claude -p`
# consolidation agent — all operating on the throwaway workspace, never on live memory.
#
# It is slower and consumes model quota (it launches Claude). Run it to prove behaviour on a
# branch; use verify.sh for the fast mechanical check.
#
#   tests/verify-agent.sh                 # both scenarios
#   SKIP_CONSOLIDATION=1 tests/verify-agent.sh   # only the cheap propagation scenario
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUTL="${OUTL_BIN:-/opt/homebrew/bin/outl}"
MI="${MI:-$REPO/memory-index}"
HOOK="$REPO/claude-memory-hook"
CONS="$REPO/memory-consolidate"
FX="$HERE/fixture"
TODAY="$(date +%F)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found"; exit 1; }
[ -d "$FX" ] || { echo "fixture missing — run tests/build-fixture.sh"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
gt()   { if [ "$2" -gt "$3" ] 2>/dev/null; then ok "$1 ($2 > $3)"; else bad "$1 (want >$3, got '$2')"; fi; }
# The agent could not actually run (usage/session/rate limit, overload, auth) — inconclusive,
# not a failure of the code under test. Detected from the agent's own output/log.
LIMIT_RE='session limit|usage limit|hit your .*limit|rate.?limit|Overloaded|insufficient|quota|Credit balance|not authenticated|Invalid API key'
blocked(){ for f in "$@"; do grep -qiE "$LIMIT_RE" "$f" 2>/dev/null && return 0; done; return 1; }

setup() {
  local w="$TMPROOT/$1"; rm -rf "$w"; cp -R "$FX/." "$w"
  "$MI" -w "$w" rebuild >/dev/null 2>&1
  printf '%s' "$TODAY" > "$w/.last-session-date"   # keep spawned SessionStart from sweeping the copy
  printf '%s' "$w"
}
getf(){ grep -m1 '^frecency::' "$1/pages/$2.md" 2>/dev/null | sed 's/^frecency:: *//'; }
jhere(){ [ -f "$1/journals/$2.md" ] && echo yes || echo no; }
pend(){ "$MI" -w "$1" consolidate --json 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin)['pending']))"; }

echo "== agent-in-the-loop (real claude runs against the fixture) =="

# ---------------------------------------------------------------------------------
# Scenario 1 — a live agent calling outl_page_get triggers touch + upward propagation.
# ---------------------------------------------------------------------------------
echo "[1] live agent: outl_page_get -> PostToolUse touch -> propagate up the chain"
W="$(setup ag1)"
check "baseline alpha-notes" "$(getf "$W" alpha-notes)" "30"
check "baseline proj-alpha"  "$(getf "$W" proj-alpha)"  "30"
check "baseline index"       "$(getf "$W" index)"       "40"

MCP="$TMPROOT/mcp1.json"
printf '{"mcpServers":{"outl":{"command":"%s","args":["mcp","serve","-w","%s"]}}}' "$OUTL" "$W" > "$MCP"
SET="$TMPROOT/set1.json"
printf '{"hooks":{"PostToolUse":[{"matcher":"mcp__outl__outl_page_get","hooks":[{"type":"command","command":"%s"}]}]}}' "$HOOK" > "$SET"

MEMORY_WS="$W" MEMORY_INDEX_BIN="$MI" OUTL_BIN="$OUTL" \
  claude -p 'Use the outl_page_get tool with slug "alpha-notes" to read that memory page. After it returns, reply with just: DONE.' \
    --model sonnet \
    --mcp-config "$MCP" --strict-mcp-config \
    --settings "$SET" \
    --allowedTools "mcp__outl__outl_page_get" \
    --dangerously-skip-permissions \
    >"$TMPROOT/ag1.out" 2>"$TMPROOT/ag1.err"
# the PostToolUse touch is fire-and-forget; wait for the propagated write to land
for _ in $(seq 1 60); do [ "$(getf "$W" alpha-notes)" != "30" ] && break; sleep 0.5; done

if [ "$(getf "$W" alpha-notes)" = "30" ] && blocked "$TMPROOT/ag1.err" "$TMPROOT/ag1.out"; then
  skip "live-agent scenario — Claude could not run (usage/rate limit or auth); inconclusive"
else
  gt "leaf touched by the agent's page_get" "$(getf "$W" alpha-notes)" 30
  gt "parent moc propagated"                "$(getf "$W" proj-alpha)"  30
  gt "root index propagated"                "$(getf "$W" index)"       40
fi

# ---------------------------------------------------------------------------------
# Scenario 2 — the real consolidation agent distills the pending journal and it is reaped.
# ---------------------------------------------------------------------------------
if [ -n "${SKIP_CONSOLIDATION:-}" ]; then
  echo "[2] consolidation agent — SKIPPED (SKIP_CONSOLIDATION set)"
else
  echo "[2] consolidation agent: claude -p distills 2020-01-04 -> marked -> reaped"
  W="$(setup ag2)"
  check "one pending aged journal before" "$(pend "$W")" "1"
  check "pending journal present before"  "$(jhere "$W" 2020-01-04)" "yes"

  MEMORY_WS="$W" MEMORY_INDEX_BIN="$MI" MEMORY_CONSOLIDATE_BIN="$CONS" OUTL_BIN="$OUTL" \
    MEMORY_MODEL="${MEMORY_MODEL:-claude-sonnet-5}" \
    bash "$CONS" >"$TMPROOT/ag2.out" 2>"$TMPROOT/ag2.err" || true

  # The distiller's own output goes to the workspace consolidate log. If Claude could not run
  # (quota/limit/auth), 2020-01-04 stays pending — report inconclusive, not a code failure.
  DLOG="$W/.consolidate.log"
  if [ "$(jhere "$W" 2020-01-04)" = "yes" ] && blocked "$DLOG" "$TMPROOT/ag2.err" "$TMPROOT/ag2.out"; then
    skip "consolidation scenario — Claude could not run (usage/rate limit or auth); inconclusive"
  else
    # Deterministic proof: 2020-01-04 is reaped ONLY after the distiller marks it consolidated::,
    # which the prompt instructs solely after the fact is written into a knowledge leaf.
    check "pending journal distilled + reaped" "$(jhere "$W" 2020-01-04)" "no"
    check "no pending journals remain"         "$(pend "$W")" "0"
  fi
fi

echo
printf 'TOTAL: \033[32m%d passed\033[0m, %d failed' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ', \033[33m%d skipped (agent could not run — inconclusive)\033[0m' "$SKIP"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31mFAILED\033[0m — agent logs copied to /tmp/ag*.out,/tmp/ag*.err\n'
  cp "$TMPROOT"/ag*.out "$TMPROOT"/ag*.err /tmp/ 2>/dev/null || true
  exit 1
fi
[ "$SKIP" -gt 0 ] && { printf 'Inconclusive: re-run when Claude quota is available.\n'; exit 2; }
printf 'All agent scenarios proven.\n'
