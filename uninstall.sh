#!/usr/bin/env bash
#
# uninstall.sh — cleanly decouple the persistent-memory integration from one or more
# agent harnesses.
#
#     ./uninstall.sh                    # every harness (default)
#     ./uninstall.sh --harness claude   # Claude Code only; also: omp, claude,omp, all
#
# Claude Code: removes the SessionStart + PreCompact + SessionEnd + UserPromptSubmit +
#   PostToolUse hooks from settings.json, the memory-recall agent definition, and the
#   "## Persistent memory" section from ~/.claude/CLAUDE.md.
# omp: removes the adapter extension, the memory-recall task agent, and the
#   "## Persistent memory" section from ~/.omp/agent/AGENTS.md (OMP_AGENT_DIR overrides).
# Shared binaries (claude-memory-hook, memory-index, memory-consolidate,
#   claude-memory-dump, memory-agent) are deleted from ~/.local/bin only once no
#   harness is still wired to them.
#
# It DELIBERATELY does NOT touch the memory workspace at ~/.claude/memory — your
# pages/, journals/, AGENTS.md, and the derived .outl index are all left intact.
# This unhooks the agent from the memory system WITHOUT deleting any memory, so a
# later ./install.sh re-couples everything with nothing lost.
#
# Run as your normal user (not sudo). Safe to re-run; it no-ops on anything already
# removed. Paths can be overridden via CLAUDE_DIR / BIN_DIR / OMP_AGENT_DIR (testing).
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WANT_CLAUDE=0
WANT_OMP=0
want() {
  local h
  for h in ${1//,/ }; do
    case "$h" in
      claude) WANT_CLAUDE=1 ;;
      omp)    WANT_OMP=1 ;;
      all)    WANT_CLAUDE=1; WANT_OMP=1 ;;
      *) echo "unknown harness '$h' (want claude|omp|all)" >&2; exit 2 ;;
    esac
  done
}
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) [ $# -ge 2 ] || { echo "--harness needs a value" >&2; exit 2; }; want "$2"; shift 2 ;;
    --harness=*) want "${1#--harness=}"; shift ;;
    -h|--help) sed -n '3,7p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ "$WANT_CLAUDE" = 1 ] || [ "$WANT_OMP" = 1 ] || { WANT_CLAUDE=1; WANT_OMP=1; }

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
OMP_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
MEM_DIR="$CLAUDE_DIR/memory"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/claude-memory-hook"
OMP_EXT="$OMP_DIR/extensions/claude-memory.ts"

# remove_file <path>
remove_file() {
  if [ -e "$1" ]; then
    rm -f "$1" && echo "✔ removed        $1"
  else
    echo "• not present    $1"
  fi
}

# strip_memory_section <file>: drop the installer's "## Persistent memory" section; delete
# the file when nothing but installer content remains.
strip_memory_section() {
  local file="$1"
  if ! [ -f "$file" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "• $(basename "$file") -> not found or python3 missing; skipped section removal ($file)"
    return
  fi
  MEMFILE="$file" python3 - <<'PY'
import os, re

path = os.environ['MEMFILE']
label = os.path.basename(path)
with open(path) as f:
    lines = f.read().splitlines(keepends=True)

start = None
for i, l in enumerate(lines):
    if re.match(r'^##\s+Persistent memory\s*$', l.rstrip('\n')):
        start = i
        break
if start is None:
    print("• %s -> no '## Persistent memory' section; left as-is (%s)" % (label, path))
    raise SystemExit

# The section runs until the next top-level (# or ##) heading, or end of file.
end = len(lines)
for j in range(start + 1, len(lines)):
    if re.match(r'^#{1,2}\s+', lines[j]):
        end = j
        break

remaining = ''.join(lines[:start]) + ''.join(lines[end:])
remaining = re.sub(r'\n{3,}', '\n\n', remaining).rstrip()
stripped = remaining.strip()

# If the file was created wholesale from the installer template (its H1 intro is
# all that's left) or nothing meaningful remains, remove the file outright.
if stripped == '' or stripped.startswith('# memory — persistent-memory system'):
    os.remove(path)
    print("✔ %s -> only installer-added memory content remained; file removed (%s)" % (label, path))
else:
    with open(path, 'w') as f:
        f.write(remaining + '\n')
    print("✔ %s -> stripped the '## Persistent memory' section (%s)" % (label, path))
PY
}

# ================================= Claude Code ======================================
if [ "$WANT_CLAUDE" = 1 ]; then

# ---- 1. remove the memory hooks from settings.json --------------------------
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
  SETTINGS="$SETTINGS" HOOK="$HOOK" python3 - <<'PY'
import json, os

path = os.environ['SETTINGS']
cmd  = os.environ['HOOK']

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError
except (FileNotFoundError, ValueError):
    print("• settings.json  -> unreadable / not an object; left as-is")
    raise SystemExit

hooks = data.get('hooks')
if not isinstance(hooks, dict):
    print("• settings.json  -> no hooks block; nothing to remove")
    raise SystemExit

def is_ours(h):
    if not (isinstance(h, dict) and h.get('type') == 'command'):
        return False
    c = str(h.get('command', ''))
    # Match the exact deployed path, or any command whose basename is the hook,
    # so a differently-rooted install is still cleaned up.
    return c == cmd or c.rstrip('/').endswith('/claude-memory-hook') or c == 'claude-memory-hook'

changed = False
for event in ('SessionStart', 'PreCompact', 'SessionEnd', 'UserPromptSubmit', 'PostToolUse'):
    groups = hooks.get(event)
    if not isinstance(groups, list):
        continue
    new_groups = []
    for g in groups:
        gh = g.get('hooks') if isinstance(g, dict) else None
        if isinstance(gh, list):
            kept = [h for h in gh if not is_ours(h)]
            if len(kept) != len(gh):
                changed = True
            if kept:                       # keep the group only if hooks remain
                g = dict(g); g['hooks'] = kept
                new_groups.append(g)
        else:
            new_groups.append(g)           # leave shapes we don't recognise
    if new_groups:
        hooks[event] = new_groups
    elif event in hooks:                   # drop an event left with no groups
        del hooks[event]
        changed = True
if not hooks:                              # drop an empty hooks block entirely
    data.pop('hooks', None)

if changed:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print("✔ settings.json  -> removed memory hooks (SessionStart/PreCompact/SessionEnd/"
          "UserPromptSubmit/PostToolUse)")
else:
    print("• settings.json  -> no memory hooks found; left as-is")
PY
else
  echo "• settings.json  -> not found or python3 missing; skipped hook removal"
fi

# ---- 2. remove deployed agent definitions ----------------------------------
for a in "$SRC"/agents/*.md; do
  [ -e "$a" ] || continue
  remove_file "$CLAUDE_DIR/agents/$(basename "$a")"
done

# ---- 3. strip the "## Persistent memory" section from CLAUDE.md -------------
strip_memory_section "$CLAUDEMD"

fi # WANT_CLAUDE

# ===================================== omp ==========================================
if [ "$WANT_OMP" = 1 ]; then

# ---- 4. adapter extension + task agent --------------------------------------
remove_file "$OMP_EXT"
for a in "$SRC"/agents/*.md; do
  [ -e "$a" ] || continue
  remove_file "$OMP_DIR/agents/$(basename "$a")"
done

# ---- 5. strip the "## Persistent memory" section from omp's AGENTS.md -------
strip_memory_section "$OMP_DIR/AGENTS.md"

fi # WANT_OMP

# ---- 6. shared binaries: only once no harness is still wired ---------------
still=""
[ -f "$SETTINGS" ] && grep -q 'claude-memory-hook' "$SETTINGS" && still="${still} claude"
[ -e "$OMP_EXT" ] && still="${still} omp"
if [ -n "$still" ]; then
  echo "• binaries kept in $BIN_DIR — still wired for:${still}"
else
  for f in claude-memory-hook memory-index memory-consolidate claude-memory-dump memory-agent; do
    remove_file "$BIN_DIR/$f"
  done
fi

# ---- 4. done ---------------------------------------------------------------
cat <<EOF

Done — the agent is decoupled from the memory system.

PRESERVED (by design, not touched): $MEM_DIR
  Your pages/, journals/, AGENTS.md, and the derived .outl index remain intact.
  Re-couple any time with ./install.sh — nothing was lost.

The change takes effect in a NEW session.
EOF

if [ -d "$MEM_DIR" ]; then
  echo "• memory workspace still present at $MEM_DIR (as intended)"
fi
