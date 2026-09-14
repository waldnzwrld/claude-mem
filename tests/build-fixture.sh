#!/usr/bin/env bash
#
# build-fixture.sh — (re)generate the reusable test workspace at tests/fixture.
#
# Builds a small, deterministic outl memory graph that exercises every path the
# maintenance code cares about: propagation, leaf eviction + reference scrub, moc
# cascade, block (line) eviction, pin decay, split-on-growth detection, and journal
# consolidation/reap. Run once and commit the result; verify.sh copies it per test.
#
# Block ids are outl ULIDs (non-deterministic), so the fixture pins STRUCTURE, not ids —
# verify.sh discovers ids at run time. The derived index (.outl/index.sqlite) and the
# section ledger (.frecency) are NOT committed; verify.sh rebuilds them on its copy.
#
# Usage: tests/build-fixture.sh   (from anywhere; paths are resolved from this script)
set -eu

OUTL="${OUTL_BIN:-/opt/homebrew/bin/outl}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixture"

command -v "$OUTL" >/dev/null 2>&1 || { echo "outl not found ($OUTL)"; exit 1; }

echo "Rebuilding fixture at $FX"
rm -rf "$FX"
mkdir -p "$FX"
"$OUTL" init "$FX" >/dev/null

# page <slug> <title> <json-forest> [frecency] [pin]
page() {
  "$OUTL" -w "$FX" page create "$1" --title "$2" --content "$3" >/dev/null
  [ -n "${4:-}" ] && "$OUTL" -w "$FX" page prop set "$1" "frecency=$4" >/dev/null
  [ "${5:-}" = "pin" ] && "$OUTL" -w "$FX" page prop set "$1" "pin=true" >/dev/null
  return 0
}

# ---- root + project mocs --------------------------------------------------------
page index "Memory index" \
  '[{"text":"type:: moc"},{"text":"## Projects"},{"text":"[[proj-alpha]] — alpha"},{"text":"[[proj-beta]] — beta"},{"text":"[[misc]] — misc"}]' 40

page proj-alpha "Project Alpha" \
  '[{"text":"type:: moc"},{"text":"parent:: [[index]]"},{"text":"## Children"},{"text":"[[alpha-notes]] — working notes"},{"text":"[[alpha-decisions]] — decisions"},{"text":"[[alpha-stale]] — a note that will age out"}]' 30

page proj-beta "Project Beta" \
  '[{"text":"type:: moc"},{"text":"parent:: [[index]]"},{"text":"## Children"},{"text":"[[beta-notes]] — beta notes"}]' 30

page misc "Misc" \
  '[{"text":"type:: moc"},{"text":"parent:: [[index]]"},{"text":"## Children"},{"text":"[[pinned-note]] — pinned"},{"text":"[[big-leaf]] — oversized"}]' 30

# ---- leaves ---------------------------------------------------------------------
# alpha-notes references alpha-stale INLINE (mid-sentence) so its scrub path is UPDATE,
# and proj-alpha's TOC bullet leads with the ref so ITS scrub path is DELETE.
page alpha-notes "Alpha notes" \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[proj-alpha]]"},{"text":"## Notes"},{"text":"first durable fact about alpha"},{"text":"second durable fact about alpha"},{"text":"a cross-reference to [[alpha-stale]] which may age out"},{"text":"related work lives in [[alpha-decisions]]"}]' 30

page alpha-decisions "Alpha decisions" \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[proj-alpha]]"},{"text":"## Decisions"},{"text":"decided to use approach X because Y"},{"text":"rejected approach Z"}]' 30

page alpha-stale "Alpha stale note" \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[proj-alpha]]"},{"text":"## Stale"},{"text":"an old note nobody reads anymore"}]' 30

page beta-notes "Beta notes" \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[proj-beta]]"},{"text":"## Notes"},{"text":"the only beta fact"}]' 30

page pinned-note "Pinned note" \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[misc]]"},{"text":"## Pinned"},{"text":"a pinned fact — pins are no longer exempt from decay"}]' 30 pin

# oversized leaf (> MEMORY_SPLIT_TOKENS, default 1800 tok ~= 7200 chars) for split detection
BIG="$(python3 -c "print('this is a long durable sentence about the big leaf topic number %d. ' * 130 % tuple(range(130)) if False else 'this is a long durable sentence padding the oversized leaf body so it exceeds the split token budget. '*90)")"
page big-leaf "Big leaf" \
  "[{\"text\":\"type:: knowledge\"},{\"text\":\"parent:: [[misc]]\"},{\"text\":\"## Body\"},{\"text\":\"$BIG\"}]" 30

# ---- journals (for consolidation / reap) ---------------------------------------
# Eight fixed past-dated journals. Retention keeps the 5 most recent by date; the oldest 4
# (2020-01-01..04) are "aged". 01-03 are pre-marked consolidated:: (reapable — proves the
# mechanical reap); 04 is left PENDING with a concrete durable fact, so the agent test has
# exactly ONE journal to distill (fast) and something real to write into [[alpha-decisions]].
for d in 01 02 03 04 05 06 07 08; do
  "$OUTL" -w "$FX" daily append --date "2020-01-$d" --text "## Focus" >/dev/null
  "$OUTL" -w "$FX" daily append --date "2020-01-$d" --text "worked on alpha on 2020-01-$d" >/dev/null
done
"$OUTL" -w "$FX" daily append --date 2020-01-04 \
  --text "Decision: adopted the retry-with-backoff pattern for alpha's API client — a durable design decision that belongs in [[alpha-decisions]]." >/dev/null
for d in 01 02 03; do
  "$OUTL" -w "$FX" page prop set "2020-01-$d" "consolidated=2020-02-01" >/dev/null
  "$OUTL" -w "$FX" page prop set "2020-01-$d" "distilled-into=none" >/dev/null
done

# ---- strip derived / runtime artifacts (outl rebuilds them on demand) -----------
rm -rf "$FX/.outl/index.sqlite" "$FX/.outl/index.sqlite-wal" "$FX/.outl/index.sqlite-shm" "$FX/.frecency"
find "$FX" \( -name '*.lock' -o -name '.lock-*' -o -name '*.idx' -o -name 'orphans.log' \) -delete 2>/dev/null || true

cat > "$FX/.gitignore" <<'EOF'
# Derived / runtime — rebuilt by outl or per test run, never committed.
.outl/index.sqlite
.outl/index.sqlite-wal
.outl/index.sqlite-shm
.frecency/
.last-session-date
.consolidate.log
.consolidate.lock.d/
.push-cache/
*.lock
.lock-*
*.idx
orphans.log
EOF

echo "Fixture built. Pages:"
"$OUTL" -w "$FX" page list 2>/dev/null | sed 's/^/  /'
