#!/usr/bin/env bash
#
# install.sh — put the Claude persistent-memory system files into place.
#
# Run this AS YOUR NORMAL USER on the target Mac (not sudo):
#
#     ./install.sh
#
# It copies the repo's files to where Claude Code expects them and wires the
# SessionStart/PreCompact/SessionEnd hooks into settings.json. It does NOT initialize the
# outl workspace or register the outl MCP server — do those two yourself:
#
#     brew tap outlmd/outl https://github.com/outlmd/outl
#     brew trust outlmd/outl
#     brew install outl-beta
#     outl init ~/.claude/memory
#     claude mcp add outl --scope user -- outl --workspace ~/.claude/memory mcp serve
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_DIR="$HOME/.claude"
MEM_DIR="$CLAUDE_DIR/memory"
AGENTS_DIR="$CLAUDE_DIR/agents"
BIN_DIR="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/claude-memory-hook"
MEMIDX="$BIN_DIR/memory-index"
CONS="$BIN_DIR/memory-consolidate"
DUMP="$BIN_DIR/claude-memory-dump"
RETRIEVER="$AGENTS_DIR/memory-retriever.md"

mkdir -p "$MEM_DIR" "$BIN_DIR" "$AGENTS_DIR"

# ---- 1. protocol doc --------------------------------------------------------
cp "$SRC/AGENTS.md" "$MEM_DIR/AGENTS.md"
echo "✔ AGENTS.md      -> $MEM_DIR/AGENTS.md"

# ---- 2. hook script (patch the outl path for this machine's Homebrew) -------
if command -v brew >/dev/null 2>&1; then
  OUTL_PATH="$(brew --prefix)/bin/outl"
else
  OUTL_PATH="/opt/homebrew/bin/outl"   # Apple-Silicon default; Intel is /usr/local/bin/outl
fi
tmp="$(mktemp)"
sed "s|^OUTL=.*|OUTL=\"\${OUTL_BIN:-$OUTL_PATH}\"|" "$SRC/claude-memory-hook" > "$tmp"
mv "$tmp" "$HOOK"
chmod 755 "$HOOK"
echo "✔ claude-memory-hook -> $HOOK  (outl: $OUTL_PATH)"

# ---- 2b. memory-index retrieval sidecar -------------------------------------
cp "$SRC/memory-index" "$MEMIDX"
chmod 755 "$MEMIDX"
echo "✔ memory-index   -> $MEMIDX"

# ---- 2c. memory-consolidate: automatic headless distillation of aged journals
cp "$SRC/memory-consolidate" "$CONS"
chmod 755 "$CONS"
echo "✔ memory-consolidate -> $CONS"

# ---- 2d. claude-memory-dump: on-close journaler (fired by SessionEnd) --------
cp "$SRC/claude-memory-dump" "$DUMP"
chmod 755 "$DUMP"
echo "✔ claude-memory-dump -> $DUMP"

# ---- 2e. memory-retriever: the recall subagent (keeps page bodies out of the
#          caller's context — see the routing note in AGENTS.md/CLAUDE.md) ------
cp "$SRC/memory-retriever.md" "$RETRIEVER"
echo "✔ memory-retriever -> $RETRIEVER"

# ---- 3. CLAUDE.md (append the memory section if it isn't already there) ------
# First-run only. If the section already exists we do NOT touch it — the file may
# carry the user's own edits — so protocol updates are NOT auto-applied. Instead we
# print a note telling the user to manually refresh the block from CLAUDE_TEMPLATE.md
# so changes like the memory-retriever routing rule aren't silently missed.
if [ -f "$CLAUDEMD" ] && grep -q '^## Persistent memory' "$CLAUDEMD"; then
  echo "• CLAUDE.md already has a '## Persistent memory' section; left as-is."
  echo "  ↳ NOTE: install.sh will not modify an existing section, so protocol updates"
  echo "    are not applied automatically. To pick up changes (e.g. the memory-retriever"
  echo "    routing rule), replace that section in $CLAUDEMD with the current one from:"
  echo "        $SRC/CLAUDE_TEMPLATE.md"
else
  # Shipped sections reference the protocol docs by ~ path (user-agnostic, read
  # on demand — no @import), so no path rewrite is needed.
  rewritten="$(cat "$SRC/CLAUDE_TEMPLATE.md")"
  if [ -f "$CLAUDEMD" ]; then
    # Append only the "## Persistent memory" section onto the existing file.
    section="$(printf '%s\n' "$rewritten" | awk '/^## Persistent memory/{p=1} p')"
    printf '\n\n%s\n' "$section" >> "$CLAUDEMD"
    echo "✔ CLAUDE.md      -> appended memory section to $CLAUDEMD"
  else
    printf '%s\n' "$rewritten" > "$CLAUDEMD"
    echo "✔ CLAUDE.md      -> $CLAUDEMD"
  fi
fi

# ---- 4. wire SessionStart + PreCompact hooks into settings.json -------------
if command -v python3 >/dev/null 2>&1; then
  SETTINGS="$SETTINGS" HOOK="$HOOK" python3 - <<'PY'
import json, os

path = os.environ['SETTINGS']
cmd  = os.environ['HOOK']

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}

hooks = data.setdefault('hooks', {})

def ensure(event):
    groups = hooks.setdefault(event, [])
    for g in groups:
        for h in g.get('hooks', []):
            if h.get('type') == 'command' and h.get('command') == cmd:
                return False
    groups.append({'hooks': [{'type': 'command', 'command': cmd}]})
    return True

changed = ensure('SessionStart') | ensure('PreCompact') | ensure('SessionEnd')

if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print(f"✔ settings.json  -> wired SessionStart + PreCompact + SessionEnd hooks")
else:
    print("• settings.json already has the hooks; left as-is")
PY
else
  cat <<EOF
! python3 not found — add these to the "hooks" object in $SETTINGS yourself:

  "SessionStart": [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "PreCompact":   [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ]
EOF
fi

cat <<EOF

Done. Files are in place. Remaining steps (you said you'd handle these):
  1. brew install outl (outlmd/outl tap) if not already installed
  2. outl init ~/.claude/memory
  3. claude mcp add outl --scope user -- outl --workspace ~/.claude/memory mcp serve
  4. build the retrieval index (safe to re-run any time; the SessionStart hook
     keeps it fresh afterward):  $MEMIDX rebuild

Then start a NEW Claude Code session to load the memory system.
EOF

# Build the index now if the workspace already exists, so it's ready immediately.
if [ -d "$MEM_DIR/pages" ]; then
  "$MEMIDX" -w "$MEM_DIR" rebuild >/dev/null 2>&1 \
    && echo "✔ memory-index   -> built initial index at $MEM_DIR/.outl/index.sqlite" \
    || echo "• memory-index   -> run '$MEMIDX rebuild' after 'outl init' to build the index"
fi
