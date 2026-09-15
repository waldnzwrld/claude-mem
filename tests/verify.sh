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
# Force a page toward eviction: set a low frecency checkpoint AND an old `seen`, so lazy
# decay (effective = frecency − days_since(seen)) computes effective ≤ 0. Under lazy decay a
# low frecency alone no longer evicts — staleness is elapsed time since `seen`.
frec() { "$OUTL" -w "$1" page prop set "$2" "frecency=$3" >/dev/null 2>&1
         "$OUTL" -w "$1" page prop set "$2" "seen=2000-01-01" >/dev/null 2>&1; }
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

echo "[10] body-bullet summary/updated are indexed (canonical leaf form)"
W="$(setup s10)"
"$OUTL" -w "$W" page create bullet-probe --title "Bullet probe" \
  --content '[{"text":"type:: knowledge"},{"text":"parent:: [[index]]"},{"text":"updated:: 2020-02-02"},{"text":"summary:: probe notes with quarterly cadence token"},{"text":"## Body"},{"text":"a durable body line"}]' >/dev/null 2>&1
"$MI" -w "$W" rebuild >/dev/null 2>&1
pcol() { sqlite3 "$1/.outl/index.sqlite" "SELECT $3 FROM pages WHERE slug='$2'"; }
check "summary captured from bullet" "$(pcol "$W" bullet-probe summary)" "probe notes with quarterly cadence token"
check "updated captured from bullet" "$(pcol "$W" bullet-probe updated)"  "2020-02-02"
FTS="$("$MI" -w "$W" search "quarterly" --no-graph --json 2>/dev/null | jq_py "any(r.get('slug')=='bullet-probe' for r in d['results'])")"
check "summary text reached FTS"     "$FTS" "True"

echo "[11] lazy decay (recent seen survives; checkpoint not rewritten; missing seen migrates)"
W="$(setup s11)"
TODAY="$(date +%F)"
"$OUTL" -w "$W" page prop set alpha-notes "frecency=2" >/dev/null 2>&1
"$OUTL" -w "$W" page prop set alpha-notes "seen=$TODAY" >/dev/null 2>&1
evicted_json "$W" >/dev/null
check "recent-seen low-frecency page survives" "$(here "$W" alpha-notes)" "yes"
check "checkpoint NOT rewritten by sweep (no daily -1)" "$(getf "$W" alpha-notes)" "2"
W="$(setup s11b)"   # misc has frecency but no seen in the fixture
"$OUTL" -w "$W" page prop set misc "frecency=3" >/dev/null 2>&1
evicted_json "$W" >/dev/null
check "missing-seen page survives (migrated, not evicted)" "$(here "$W" misc)" "yes"
check "missing-seen page got a seen stamp" "$(grep -c '^seen::' "$W/pages/misc.md")" "1"

echo "[12] tag facet layer (curated tags indexed, numeric filtered, doctor flags, search expands)"
W="$(setup s12)"
"$OUTL" -w "$W" page create taga --content \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[index]]"},{"text":"## B"},{"text":"frobnicator gadget notes #topic/zzz and PR #999"}]' >/dev/null 2>&1
"$OUTL" -w "$W" page create tagb --content \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[index]]"},{"text":"## B"},{"text":"entirely separate prose #topic/zzz"}]' >/dev/null 2>&1
"$MI" -w "$W" rebuild >/dev/null 2>&1
check "curated topic/zzz indexed on 2 pages" \
  "$(sqlite3 "$W/.outl/index.sqlite" "SELECT COUNT(*) FROM page_tags WHERE tag='topic/zzz'")" "2"
check "numeric #999 filtered from index" \
  "$(sqlite3 "$W/.outl/index.sqlite" "SELECT COUNT(*) FROM page_tags WHERE tag='999'")" "0"
check "doctor flags numeric tag on taga" \
  "$("$MI" -w "$W" doctor --json 2>/dev/null | jq_py "'taga' in d['polluting_tags']")" "True"
# 'frobnicator' FTS-hits only taga; tagb (no such word) must surface via shared-tag expansion
check "tag expansion surfaces co-tagged page (no FTS hit)" \
  "$("$MI" -w "$W" search "frobnicator" --json 2>/dev/null | jq_py "any(r['slug']=='tagb' and r['kind']=='tag' for r in d['results'])")" "True"

echo "[13] normalize: strips PR/issue #-number tags (smart), versioned + idempotent"
W="$(setup s13)"
"$OUTL" -w "$W" page create nrm --content \
  '[{"text":"type:: knowledge"},{"text":"parent:: [[index]]"},{"text":"## B"},{"text":"resolved PR #450 and closed #272 today #topic/keep"},{"text":"merged PR#273 while coding in C#9 style"}]' >/dev/null 2>&1
"$MI" -w "$W" rebuild >/dev/null 2>&1
check "status pending before" \
  "$("$MI" -w "$W" normalize --status --json 2>/dev/null | jq_py "d['pending']")" "True"
"$MI" -w "$W" normalize --apply >/dev/null 2>&1
BODY="$("$OUTL" -w "$W" export md nrm 2>/dev/null)"
case "$BODY" in *"PR 450"*)        ok  "labeled '#450' -> 'PR 450'" ;; *) bad "labeled strip ($BODY)" ;; esac
case "$BODY" in *"closed PR 272"*) ok  "bare '#272' -> 'PR 272'" ;;    *) bad "bare strip ($BODY)" ;; esac
case "$BODY" in *"PR 273"*)        ok  "glued 'PR#273' -> 'PR 273'" ;; *) bad "glued-label strip ($BODY)" ;; esac
case "$BODY" in *"#272"*|*"#273"*) bad "still carries a #number tag" ;; *) ok  "no #272/#273 tag remains" ;; esac
case "$BODY" in *"C#9"*)           ok  "non-label 'C#9' preserved" ;;  *) bad "C#9 was mangled ($BODY)" ;; esac
case "$BODY" in *"#topic/keep"*)   ok  "curated #topic/keep preserved" ;; *) bad "curated tag lost" ;; esac
"$MI" -w "$W" rebuild >/dev/null 2>&1
check "numeric tags gone from index" \
  "$(sqlite3 "$W/.outl/index.sqlite" "SELECT COUNT(*) FROM page_tags WHERE tag IN ('272','450')")" "0"
check "standard now up-to-date (idempotent)" \
  "$("$MI" -w "$W" normalize --status --json 2>/dev/null | jq_py "d['pending']")" "False"
check "re-apply is a no-op" \
  "$("$MI" -w "$W" normalize --apply --json 2>/dev/null | jq_py "d['count']")" "0"

echo
printf 'TOTAL: \033[32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
