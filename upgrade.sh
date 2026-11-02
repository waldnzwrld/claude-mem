#!/usr/bin/env bash
#
# upgrade.sh — migrate a claude-mem install (workspace ~/.claude/memory, binaries
# claude-memory-hook / claude-memory-dump, omp extension claude-memory.ts) to
# llm-harness-memory (workspace ~/.llm-harness-memory, memory-hook / memory-dump,
# llm-harness-memory.ts), then reinstall for every harness that was wired.
#
#     ./upgrade.sh            # refuses while a session still serves the old workspace
#     ./upgrade.sh --force    # skip that check
#
# Steps, in order (each is a no-op when already done, so it is safe to re-run):
#   1. move ~/.claude/memory -> ~/.llm-harness-memory (a same-filesystem rename), and bind
#      the new root to the workspace's existing outl actor (see below)
#   2. rewrite the outl MCP server's --workspace path in ~/.claude.json (user and
#      project scopes) and in omp's mcp.json; rewrite workspace-scoped permission rules
#      in ~/.claude/settings.json and drop its claude-memory-hook hook entries
#   3. delete the old binaries and the old omp extension; strip the old
#      "## Persistent memory" section from ~/.claude/CLAUDE.md / ~/.omp/agent/AGENTS.md
#   4. run ./install.sh for the detected harnesses (new binaries, hooks, extension,
#      memory section, AGENTS.md, index rebuild against the new path)
#
# Why the actor binding: outl keys this machine's actor per (workspace id, root path) in
# $XDG_CONFIG_HOME/outl/actors/<workspace-id>.<sha256(realpath root)[:32]>. A moved root
# would otherwise mint a fresh actor whose replay of the op log does not see the old
# actor's per-page shards — deleted pages and reaped journals reappear. Pre-writing the
# binding with the old actor before outl first opens the new root keeps the graph intact.
#
# Close every Claude Code / omp session first: a live session's outl MCP server holds the
# old workspace open, and its hooks point at binaries this script deletes.
# OMP_AGENT_DIR overrides the omp agent dir, as in install.sh.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC/lib.sh"

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '3,9p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

OLD_WS="$HOME/.claude/memory"
NEW_WS="$HOME/.llm-harness-memory"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="$HOME/.claude.json"
BIN_DIR="$HOME/.local/bin"
OMP_DIR="${OMP_AGENT_DIR:-$HOME/.omp/agent}"
OLD_OMP_EXT="$OMP_DIR/extensions/claude-memory.ts"
NEW_OMP_EXT="$OMP_DIR/extensions/llm-harness-memory.ts"

die() { echo "✖ $*" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# ---- detect wired harnesses (old or new wiring) ------------------------------
harnesses=""
[ -f "$SETTINGS" ] && grep -q 'memory-hook' "$SETTINGS" && harnesses="claude"
if [ -e "$OLD_OMP_EXT" ] || [ -e "$NEW_OMP_EXT" ]; then
  harnesses="${harnesses:+$harnesses,}omp"
fi
[ -n "$harnesses" ] || [ -d "$OLD_WS" ] \
  || die "no install found (no hooks, no omp extension, no $OLD_WS); use ./install.sh"
[ -n "$harnesses" ] || harnesses="claude"   # workspace but no wiring: install.sh's default
echo "• harnesses      -> $harnesses"

# ---- preflight: nothing may hold the old workspace open ----------------------
if [ -d "$OLD_WS" ]; then
  for lock in .consolidate.lock.d .dump.lock.d; do
    [ -e "$OLD_WS/$lock" ] && die "background agent running ($OLD_WS/$lock); retry when it finishes"
  done
  if [ "$FORCE" = 0 ] && pgrep -f -- "$OLD_WS" >/dev/null 2>&1; then
    echo "✖ processes still use $OLD_WS:" >&2
    pgrep -fl -- "$OLD_WS" >&2 || true
    die "close every Claude Code / omp session, then re-run (or pass --force)"
  fi
fi

# ---- 1. move the workspace ---------------------------------------------------
if [ -L "$OLD_WS" ]; then
  die "$OLD_WS is a symlink; move its target to $NEW_WS by hand, remove the link, and re-run"
elif [ -d "$OLD_WS" ]; then
  if [ -e "$NEW_WS" ]; then
    rmdir "$NEW_WS" 2>/dev/null \
      || die "both $OLD_WS and a non-empty $NEW_WS exist; merge or remove one, then re-run"
  fi
  mv "$OLD_WS" "$NEW_WS"
  echo "✔ workspace      -> moved $OLD_WS to $NEW_WS"
elif [ -d "$NEW_WS" ]; then
  echo "• workspace      -> already at $NEW_WS"
else
  echo "• workspace      -> none found; install.sh will create $NEW_WS"
fi

# ---- 1b. keep the workspace's outl actor across the move ---------------------
OLD_WS="$OLD_WS" NEW_WS="$NEW_WS" OUTL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/outl" python3 - <<'PY'
import hashlib, os

new_root = os.path.realpath(os.environ['NEW_WS'])
old_root = os.path.realpath(os.environ['OLD_WS'])   # resolves the parent; the leaf is gone
actors = os.path.join(os.environ['OUTL_CFG'], 'actors')
try:
    wsid = open(os.path.join(new_root, '.outl', 'workspace-id')).read().strip()
except OSError:
    print("• outl actor     -> no outl workspace at %s; nothing to bind" % new_root)
    raise SystemExit

def read(path):
    try:
        with open(path) as f:
            return dict(l.split('=', 1) for l in f.read().splitlines() if '=' in l)
    except OSError:
        return None

target = os.path.join(actors, '%s.%s' % (wsid, hashlib.sha256(new_root.encode()).hexdigest()[:32]))
old = None
for name in sorted(os.listdir(actors)) if os.path.isdir(actors) else []:
    if name == wsid or name.startswith(wsid + '.'):
        b = read(os.path.join(actors, name))
        if b and b.get('root') == old_root and b.get('actor'):
            old = b
            break
cur = read(target)

if old is None:
    print("• outl actor     -> no binding for %s; outl will use %s" %
          (old_root, cur['actor'] if cur else 'a new actor'))
elif cur and cur.get('actor') == old['actor']:
    print("• outl actor     -> %s already bound to %s" % (old['actor'], new_root))
elif cur:
    print("! outl actor     -> %s is bound to %s, not the workspace's actor %s; outl opened the "
          "new root before the binding was written. Review %s by hand." %
          (new_root, cur.get('actor'), old['actor'], target))
else:
    with open(target, 'w') as f:
        f.write('actor=%s\nroot=%s\nmachine=%s\ndev=%d\n' %
                (old['actor'], new_root, old.get('machine', ''), os.stat(new_root).st_dev))
    print("✔ outl actor     -> bound %s to %s" % (new_root, old['actor']))
PY

# ---- 2. rewrite harness configs ----------------------------------------------
OLD_WS="$OLD_WS" NEW_WS="$NEW_WS" SETTINGS="$SETTINGS" CLAUDE_JSON="$CLAUDE_JSON" \
OMP_MCP="$OMP_DIR/mcp.json" python3 - <<'PY'
import json, os

old, new = os.environ['OLD_WS'], os.environ['NEW_WS']
tilde_old = '~/.claude/memory'

def sub(s):
    return s.replace(old, new).replace(tilde_old, new) if isinstance(s, str) else s

def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (FileNotFoundError, ValueError):
        return None

def save(path, data, indent):
    tmp = path + '.upgrade.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write('\n')
    os.replace(tmp, path)

def fix_servers(servers):
    n = 0
    if not isinstance(servers, dict):
        return 0
    for spec in servers.values():
        if isinstance(spec, dict) and isinstance(spec.get('args'), list):
            args = [sub(a) for a in spec['args']]
            if args != spec['args']:
                spec['args'] = args
                n += 1
    return n

# Claude Code MCP registrations: user scope + every project scope.
p = os.environ['CLAUDE_JSON']
d = load(p)
if d is not None:
    n = fix_servers(d.get('mcpServers'))
    for proj in (d.get('projects') or {}).values():
        if isinstance(proj, dict):
            n += fix_servers(proj.get('mcpServers'))
    if n:
        save(p, d, 2)
        print("✔ .claude.json   -> repointed %d MCP server(s) at %s" % (n, new))
    else:
        print("• .claude.json   -> no MCP server uses the old workspace")

# omp MCP registrations.
p = os.environ['OMP_MCP']
d = load(p)
if d is not None:
    if fix_servers(d.get('mcpServers')):
        save(p, d, '\t')
        print("✔ omp mcp.json   -> repointed outl at %s" % new)
    else:
        print("• omp mcp.json   -> no MCP server uses the old workspace")

# Claude Code settings: drop the old hook handlers (install.sh wires memory-hook) and
# repoint workspace-scoped permission rules.
p = os.environ['SETTINGS']
d = load(p)
if d is not None:
    changed = False
    hooks = d.get('hooks')
    if isinstance(hooks, dict):
        for event in list(hooks):
            groups = hooks[event]
            if not isinstance(groups, list):
                continue
            kept_groups = []
            for g in groups:
                gh = g.get('hooks') if isinstance(g, dict) else None
                if not isinstance(gh, list):
                    kept_groups.append(g)
                    continue
                kept = [h for h in gh if not (isinstance(h, dict)
                        and str(h.get('command', '')).rstrip('/').split('/')[-1] == 'claude-memory-hook')]
                if len(kept) != len(gh):
                    changed = True
                if kept:
                    g = dict(g); g['hooks'] = kept
                    kept_groups.append(g)
            if kept_groups:
                hooks[event] = kept_groups
            else:
                del hooks[event]
                changed = True
    perms = d.get('permissions')
    if isinstance(perms, dict):
        for key in ('allow', 'ask', 'deny'):
            rules = perms.get(key)
            if not isinstance(rules, list):
                continue
            out = []
            for r in (sub(r) for r in rules):
                if r not in out:
                    out.append(r)
            if out != rules:
                perms[key] = out
                changed = True
    if changed:
        save(p, d, 2)
        print("✔ settings.json  -> dropped claude-memory-hook hooks, repointed permission rules")
    else:
        print("• settings.json  -> nothing referenced the old install")
PY

# ---- 3. remove the old artifacts ---------------------------------------------
remove_file "$BIN_DIR/claude-memory-hook"
remove_file "$BIN_DIR/claude-memory-dump"
remove_file "$OLD_OMP_EXT"
# A section written by the old installer names the old workspace; install.sh re-appends it.
for f in "$CLAUDE_DIR/CLAUDE.md" "$OMP_DIR/AGENTS.md"; do
  [ -f "$f" ] && grep -q '\.claude/memory' "$f" && strip_memory_section "$f"
done

# ---- 4. install the current layout -------------------------------------------
echo
"$SRC/install.sh" --harness "$harnesses"

echo
for f in "$CLAUDE_DIR/CLAUDE.md" "$OMP_DIR/AGENTS.md" "$SETTINGS" "$OMP_DIR/mcp.json"; do
  [ -f "$f" ] && grep -q -e "$OLD_WS" -e '~/.claude/memory' -e 'claude-memory-' "$f" \
    && echo "! $f still mentions the old install; review it by hand"
done
echo "Upgrade complete. Start a NEW session in each harness."
