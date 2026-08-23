#!/usr/bin/env bash
#
# uninstall.sh — cleanly decouple the Claude persistent-memory integration.
#
# Reverses install.sh's three coupling actions:
#   1. removes the SessionStart + PreCompact hooks from ~/.claude/settings.json
#   2. deletes the deployed binaries (claude-memory-hook, memory-index,
#      memory-consolidate) from ~/.local/bin
#   3. strips the "## Persistent memory" section from ~/.claude/CLAUDE.md
#
# It DELIBERATELY does NOT touch the memory workspace at ~/.claude/memory — your
# pages/, journals/, AGENTS.md, and the derived .outl index are all left intact.
# This unhooks the agent from the memory system WITHOUT deleting any memory, so a
# later ./install.sh re-couples everything with nothing lost.
#
# Run as your normal user (not sudo):   ./uninstall.sh
# Safe to re-run; it no-ops on anything already removed. Paths can be overridden
# via CLAUDE_DIR / BIN_DIR (used for testing).
#
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
MEM_DIR="$CLAUDE_DIR/memory"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/claude-memory-hook"
MEMIDX="$BIN_DIR/memory-index"
CONS="$BIN_DIR/memory-consolidate"

# ---- 1. remove the SessionStart + PreCompact hooks from settings.json -------
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
for event in ('SessionStart', 'PreCompact'):
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
    print("✔ settings.json  -> removed SessionStart + PreCompact memory hooks")
else:
    print("• settings.json  -> no memory hooks found; left as-is")
PY
else
  echo "• settings.json  -> not found or python3 missing; skipped hook removal"
fi

# ---- 2. remove the deployed binaries ---------------------------------------
for f in "$HOOK" "$MEMIDX" "$CONS"; do
  if [ -e "$f" ]; then
    rm -f "$f" && echo "✔ removed        $f"
  else
    echo "• not present    $f"
  fi
done

# ---- 3. strip the "## Persistent memory" section from CLAUDE.md -------------
if [ -f "$CLAUDEMD" ] && command -v python3 >/dev/null 2>&1; then
  CLAUDEMD="$CLAUDEMD" python3 - <<'PY'
import os, re

path = os.environ['CLAUDEMD']
with open(path) as f:
    lines = f.read().splitlines(keepends=True)

start = None
for i, l in enumerate(lines):
    if re.match(r'^##\s+Persistent memory\s*$', l.rstrip('\n')):
        start = i
        break
if start is None:
    print("• CLAUDE.md      -> no '## Persistent memory' section; left as-is")
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
    print("✔ CLAUDE.md      -> only installer-added memory content remained; file removed")
else:
    with open(path, 'w') as f:
        f.write(remaining + '\n')
    print("✔ CLAUDE.md      -> stripped the '## Persistent memory' section")
PY
else
  echo "• CLAUDE.md      -> not found or python3 missing; skipped section removal"
fi

# ---- 4. done ---------------------------------------------------------------
cat <<EOF

Done — the agent is decoupled from the memory system.

PRESERVED (by design, not touched): $MEM_DIR
  Your pages/, journals/, AGENTS.md, and the derived .outl index remain intact.
  Re-couple any time with ./install.sh — nothing was lost.

The hook change takes effect in a NEW Claude Code session.
EOF

if [ -d "$MEM_DIR" ]; then
  echo "• memory workspace still present at $MEM_DIR (as intended)"
fi
