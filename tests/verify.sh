#!/usr/bin/env bash
#
# verify.sh — reusable functional test for the memory maintenance code.
#
# Copies tests/fixture into a throwaway workspace PER SCENARIO (so tests are isolated and
# never mutate the committed fixture), then exercises each path against the CURRENT repo's
# memory-index and asserts the outcome. Run it on any branch to prove the code still works:
#
#   tests/verify.sh              # uses ./memory-index in the repo
#   MI=~/.local/bin/memory-index tests/verify.sh   # test the installed binary instead
#
# Exit status is non-zero if any assertion fails.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUTL="${OUTL_BIN:-/opt/homebrew/bin/outl}"
MI="${MI:-$REPO/memory-index}"
FX="$HERE/fixture"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

command -v "$OUTL" >/dev/null 2>&1 || { echo "outl not found ($OUTL)"; exit 1; }
[ -d "$FX" ] || { echo "fixture missing — run tests/build-fixture.sh first"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# fresh isolated workspace with a freshly built index
setup() {
  local w="$TMPROOT/$1"; rm -rf "$w"; cp -R "$FX/." "$w"
  "$MI" -w "$w" rebuild >/dev/null 2>&1
  printf '%s' "$w"
}
frec() { "$OUTL" -w "$1" page prop set "$2" "frecency=$3" >/dev/null 2>&1; }
gone() { [ -f "$1/pages/$2.md" ] && echo no || echo yes; }        # yes = file removed
here() { [ -f "$1/pages/$2.md" ] && echo yes || echo no; }        # yes = file present
getf() { grep -m1 '^frecency::' "$1/pages/$2.md" 2>/dev/null | sed 's/^frecency:: *//'; }
# yes = no surviving page references [[target]] in a ref token
noref(){ "$OUTL" -w "$1" page get "$2" --json 2>/dev/null | python3 -c "
import sys,json
o=json.load(sys.stdin).get('data',{}).get('outline',[])
def refs(ns):
    for n in ns:
        for t in n.get('tokens',[]):
            if t.get('kind')=='ref' and t.get('value')=='$3': print('HIT')
        refs(n.get('children',[]))
refs(o)" | grep -q HIT && echo no || echo yes; }
firstblock(){ "$OUTL" -w "$1" page get "$2" --json 2>/dev/null | python3 -c "
import sys,json,re
o=json.load(sys.stdin)['data']['outline']
def walk(ns):
    for n in ns:
        t=(n.get('text') or '').strip()
        if t and not re.match(r'^#{1,6}\s',t) and not re.match(r'^[A-Za-z_][\w-]*::\s',t):
            print(n['id']); return True
        if walk(n.get('children',[])): return True
    return False
walk(o)"; }
evicted_json(){ "$MI" -w "$1" maintain --json 2>/dev/null; }
jq_py(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "== memory-index: $MI =="

echo "[1] graph sanity (rebuild + edges)"
W="$(setup s1)"
POC=$(sqlite3 "$W/.outl/index.sqlite" "SELECT COUNT(*) FROM edges WHERE type='part-of'")
[ "$POC" -ge 8 ] && ok "part-of edges built ($POC)" || bad "part-of edges ($POC < 8)"

echo "[2] touch propagates up the parent chain (leaf -> moc -> root)"
W="$(setup s2)"
"$MI" -w "$W" touch alpha-notes >/dev/null 2>&1
check "leaf bumped"        "$(getf "$W" alpha-notes)"  "35"
check "parent moc bumped"  "$(getf "$W" proj-alpha)"   "35"
check "root index bumped"  "$(getf "$W" index)"        "45"

echo "[3] leaf eviction + reference scrub (parent survives)"
W="$(setup s3)"
frec "$W" alpha-stale 1
R="$(evicted_json "$W")"
check "alpha-stale evicted"      "$(printf '%s' "$R" | jq_py "'alpha-stale' in d['evicted_pages']")" "True"
check "leaf file removed"        "$(gone "$W" alpha-stale)" "yes"
check "parent proj-alpha survives" "$(here "$W" proj-alpha)" "yes"
check "TOC ref scrubbed (proj-alpha)" "$(noref "$W" proj-alpha alpha-stale)" "yes"
check "inline ref scrubbed (alpha-notes)" "$(noref "$W" alpha-notes alpha-stale)" "yes"
check "alpha-notes still present" "$(here "$W" alpha-notes)" "yes"

echo "[4] moc cascade (moc=0 -> whole subtree gone, rest survives)"
W="$(setup s4)"
frec "$W" proj-beta 1
R="$(evicted_json "$W")"
check "proj-beta evicted"  "$(gone "$W" proj-beta)"  "yes"
check "child beta-notes evicted" "$(gone "$W" beta-notes)" "yes"
check "unrelated proj-alpha survives" "$(here "$W" proj-alpha)" "yes"
check "root index survives" "$(here "$W" index)" "yes"

echo "[5] block (line) eviction (line gone, file lives)"
W="$(setup s5)"
BID="$(firstblock "$W" alpha-notes)"
python3 -c "
import json,os
p='$W/.frecency'; os.makedirs(p,exist_ok=True)
f=p+'/sections.json'
d=json.load(open(f)) if os.path.exists(f) else {}
d.setdefault('alpha-notes',{})['$BID']={'f':1,'seen':'2000-01-01'}
json.dump(d,open(f,'w'))"
R="$(evicted_json "$W")"
check "block evicted" "$(printf '%s' "$R" | jq_py "'alpha-notes:$BID' in d['evicted_blocks']")" "True"
check "leaf file survives" "$(here "$W" alpha-notes)" "yes"
"$OUTL" -w "$W" page get alpha-notes --json 2>/dev/null | grep -q "$BID" && bad "block still in page" || ok "block removed from page"

echo "[6] pins are NOT exempt (pin=true still evicts at 0)"
W="$(setup s6)"
frec "$W" pinned-note 1
evicted_json "$W" >/dev/null
check "pinned-note evicted" "$(gone "$W" pinned-note)" "yes"

echo "[7] split-on-growth detection (oversized leaf, dry-run)"
W="$(setup s7)"
SPLIT="$("$MI" -w "$W" maintain --dry-run --json 2>/dev/null | jq_py "[c['slug'] for c in d['split_candidates']]")"
case "$SPLIT" in *big-leaf*) ok "big-leaf flagged for split" ;; *) bad "big-leaf not in split_candidates ($SPLIT)" ;; esac

echo "[8] journal consolidation reap (marked journal deleted, pending detected)"
W="$(setup s8)"
jhere(){ [ -f "$1/journals/$2.md" ] && echo yes || echo no; }
check "aged journal present pre-reap" "$(jhere "$W" 2020-01-01)" "yes"
C="$("$MI" -w "$W" consolidate --reap --json 2>/dev/null)"
check "2020-01-01 reaped" "$(printf '%s' "$C" | jq_py "'2020-01-01' in d['reaped']")" "True"
check "reaped journal file gone" "$(jhere "$W" 2020-01-01)" "no"
check "pending backlog non-empty" "$(printf '%s' "$C" | jq_py "len(d['pending'])>0")" "True"

echo "[9] healthy graph evicts nothing"
W="$(setup s9)"
R="$(evicted_json "$W")"
check "no pages evicted" "$(printf '%s' "$R" | jq_py "len(d['evicted_pages'])")" "0"
check "no blocks evicted" "$(printf '%s' "$R" | jq_py "len(d['evicted_blocks'])")" "0"

echo
printf 'TOTAL: \033[32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
