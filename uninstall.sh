#!/usr/bin/env bash
#
# uninstall.sh — cleanly decouple the persistent-memory integration from one or more
# agent harnesses.
#
#     ./uninstall.sh                    # every harness (default)
#     ./uninstall.sh --harness claude   # Claude Code only; also: omp, pi, claude,omp, all
#
# Claude Code: removes the SessionStart + PreCompact + SessionEnd + UserPromptSubmit +
#   PostToolUse hooks from settings.json, the memory-recall agent definition, and the
#   "## Persistent memory" section from ~/.claude/CLAUDE.md.
# omp: removes the adapter extension, the memory-recall task agent, and the
#   "## Persistent memory" section from ~/.omp/agent/AGENTS.md (OMP_AGENT_DIR overrides).
# pi: removes the adapter extension and the "## Persistent memory" section from
#   ~/.pi/agent/AGENTS.md (PI_AGENT_DIR overrides).
# Shared binaries (memory-hook, memory-index, memory-consolidate,
#   memory-dump, memory-agent) are deleted from ~/.local/bin only once no
#   harness is still wired to them.
#
# It DELIBERATELY does NOT touch the memory workspace at ~/.llm-harness-memory — your
# pages/, journals/, AGENTS.md, and the derived .outl index are all left intact.
# This unhooks the agent from the memory system WITHOUT deleting any memory, so a
# later ./install.sh re-couples everything with nothing lost.
#
# Run as your normal user (not sudo). Safe to re-run; it no-ops on anything already
# removed. Paths can be overridden via CLAUDE_DIR / BIN_DIR / OMP_AGENT_DIR / PI_AGENT_DIR
# (testing).
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SRC/lib.sh"

WANT_CLAUDE=0
WANT_OMP=0
WANT_PI=0
want() {
  local h
  for h in ${1//,/ }; do
    case "$h" in
      claude) WANT_CLAUDE=1 ;;
      omp)    WANT_OMP=1 ;;
      pi)     WANT_PI=1 ;;
      all)    WANT_CLAUDE=1; WANT_OMP=1; WANT_PI=1 ;;
      *) echo "unknown harness '$h' (want claude|omp|pi|all)" >&2; exit 2 ;;
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
[ "$WANT_CLAUDE" = 1 ] || [ "$WANT_OMP" = 1 ] || [ "$WANT_PI" = 1 ] || { WANT_CLAUDE=1; WANT_OMP=1; WANT_PI=1; }

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
OMP_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
PI_DIR="${PI_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}"
MEM_DIR="$HOME/.llm-harness-memory"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/memory-hook"
OMP_EXT="$OMP_DIR/extensions/llm-harness-memory.ts"
PI_EXT="$PI_DIR/extensions/llm-harness-memory.ts"

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
    return c == cmd or c.rstrip('/').endswith('/memory-hook') or c == 'memory-hook'

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

# ====================================== pi ==========================================
if [ "$WANT_PI" = 1 ]; then

# ---- 6. adapter extension + "## Persistent memory" section in pi's AGENTS.md ----
remove_file "$PI_EXT"
strip_memory_section "$PI_DIR/AGENTS.md"

fi # WANT_PI

# ---- 7. shared binaries: only once no harness is still wired ---------------
still=""
[ -f "$SETTINGS" ] && grep -q 'memory-hook' "$SETTINGS" && still="${still} claude"
[ -e "$OMP_EXT" ] && still="${still} omp"
[ -e "$PI_EXT" ] && still="${still} pi"
if [ -n "$still" ]; then
  echo "• binaries kept in $BIN_DIR — still wired for:${still}"
else
  for f in memory-hook memory-index memory-consolidate memory-dump memory-agent; do
    remove_file "$BIN_DIR/$f"
  done
fi

# ---- 8. done ---------------------------------------------------------------
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
