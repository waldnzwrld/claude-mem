#!/usr/bin/env bash
#
# install.sh — put the Claude persistent-memory system files into place.
#
# Run this AS YOUR NORMAL USER on the target Mac (not sudo):
#
#     ./install.sh
#
# It copies the repo's files to where Claude Code expects them, wires the
# SessionStart/PreCompact/SessionEnd/UserPromptSubmit/PostToolUse hooks into
# settings.json, and allows the whole outl MCP server (plus memory-recall +
# memory-index) so the memory graph is invisible and never prompts. It does
# NOT initialize the outl workspace or register the outl MCP server — do those
# two yourself:
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
BIN_DIR="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/claude-memory-hook"
MEMIDX="$BIN_DIR/memory-index"
CONS="$BIN_DIR/memory-consolidate"
DUMP="$BIN_DIR/claude-memory-dump"
AGENTS_DIR="$CLAUDE_DIR/agents"

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

# ---- 2e. memory-recall subagent: isolated read-only retrieval (keeps page ----
#          bodies out of the main thread). Deployed as a Claude Code agent def.
for a in "$SRC"/agents/*.md; do
  [ -e "$a" ] || continue
  cp "$a" "$AGENTS_DIR/$(basename "$a")"
  echo "✔ agent          -> $AGENTS_DIR/$(basename "$a")"
done

# ---- 3. CLAUDE.md (append the memory section if it isn't already there) ------
if [ -f "$CLAUDEMD" ] && grep -q '^## Persistent memory' "$CLAUDEMD"; then
  echo "• CLAUDE.md already has the memory section; left as-is"
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

# ---- 4. wire hooks + auto-allow read-only recall tools into settings.json ----
if command -v python3 >/dev/null 2>&1; then
  SETTINGS="$SETTINGS" HOOK="$HOOK" MEM_DIR="$MEM_DIR" python3 - <<'PY'
import json, os

path = os.environ['SETTINGS']
cmd  = os.environ['HOOK']
mem  = os.environ['MEM_DIR']

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}

hooks = data.setdefault('hooks', {})

def ensure(event, matcher=None):
    groups = hooks.setdefault(event, [])
    for g in groups:
        if matcher is not None and g.get('matcher') != matcher:
            continue
        for h in g.get('hooks', []):
            if h.get('type') == 'command' and h.get('command') == cmd:
                return False
    group = {'hooks': [{'type': 'command', 'command': cmd}]}
    if matcher is not None:
        group['matcher'] = matcher
    groups.append(group)
    return True

# UserPromptSubmit → push-retrieval; PostToolUse(outl_page_get) → frecency touch. The
# PostToolUse matcher scopes it to the one tool so the hook doesn't fire on every call.
hooks_changed = (ensure('SessionStart') | ensure('PreCompact') | ensure('SessionEnd')
                 | ensure('UserPromptSubmit')
                 | ensure('PostToolUse', matcher='mcp__outl__outl_page_get'))

# Make the memory graph invisible: auto-approve the whole outl MCP server with a
# single server-scoped allow rule. `mcp__outl` matches every tool the server
# provides — reads AND writes (journaling, curation, consolidation), main thread
# AND the memory-recall subagent. Per the Claude Code permission model an allow
# match resolves immediately and skips the classifier, in every mode, so memory
# never prompts. A server rule is also future-proof: a new outl tool needs no
# edit here. (Per-tool enumeration was the old bug — it covered 18 read tools and
# left every write to prompt.) outl marks no tool `requiresUserInteraction`, the
# one thing that would force a prompt through an allow rule, so this suffices.
allow_wanted = ['mcp__outl']
allow_wanted.append('Task(memory-recall)')
# Read-only memory-index subcommands, bare and rtk-rewritten (the rtk Bash hook,
# when present, rewrites `memory-index …` → `rtk memory-index …`).
for sub in ('doctor', 'search', 'stats'):
    allow_wanted.append('Bash(memory-index %s:*)' % sub)
    allow_wanted.append('Bash(rtk memory-index %s:*)' % sub)
# `outl doctor --repair` on the memory workspace only. The classifier flags any
# --repair as irreversible local destruction and blocks it in auto mode; an allow
# match resolves first and skips the classifier. outl takes a timestamped backup
# under .outl/repair-backup/ before writing and stays under its own safety
# ceilings, so this is safe to auto-approve. Scoped to MEM_DIR so a bare
# `outl doctor --repair <other-workspace>` still prompts. Bare + rtk-rewritten.
allow_wanted.append('Bash(outl doctor --repair %s:*)' % mem)
allow_wanted.append('Bash(rtk outl doctor --repair %s:*)' % mem)
# outl block/page delete on the memory workspace, only with --confirm in the invocation.
allow_wanted.append('Bash(outl -w %s block delete --confirm:*)' % mem)
allow_wanted.append('Bash(rtk outl -w %s block delete --confirm:*)' % mem)
allow_wanted.append('Bash(outl -w %s page delete --confirm:*)' % mem)
allow_wanted.append('Bash(rtk outl -w %s page delete --confirm:*)' % mem)

perms = data.setdefault('permissions', {})
allow = perms.get('allow')
if not isinstance(allow, list):
    allow = []
    perms['allow'] = allow
# Collapse any per-tool `mcp__outl__<tool>` entries a previous install wrote; the
# server rule below subsumes them. Keep everything else untouched.
before = list(allow)
allow[:] = [e for e in allow if not (isinstance(e, str) and e.startswith('mcp__outl__'))]
collapsed = len(before) - len(allow)
have = set(allow)
added = [e for e in allow_wanted if e not in have]
allow.extend(added)
perms_changed = bool(added) or collapsed > 0

if hooks_changed or perms_changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')

if hooks_changed:
    print("✔ settings.json  -> wired SessionStart + PreCompact + SessionEnd + "
          "UserPromptSubmit + PostToolUse hooks")
else:
    print("• settings.json already has the hooks; left as-is")
if perms_changed:
    note = ""
    if collapsed:
        note = " (collapsed %d redundant per-tool outl entries)" % collapsed
    print("✔ settings.json  -> allowed the outl MCP server + memory-recall + "
          "memory-index + scoped outl doctor --repair%s" % note)
else:
    print("• settings.json already allows the outl server + recall tools; left as-is")
PY
else
  cat <<EOF
! python3 not found — add these to the "hooks" object in $SETTINGS yourself:

  "SessionStart":    [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "PreCompact":      [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "SessionEnd":      [ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "UserPromptSubmit":[ { "hooks": [ { "type": "command", "command": "$HOOK" } ] } ],
  "PostToolUse":     [ { "matcher": "mcp__outl__outl_page_get", "hooks": [ { "type": "command", "command": "$HOOK" } ] } ]

  ...and, under "permissions": { "allow": [ ... ] }, add "mcp__outl" (the whole
  outl server — every read and write, so the memory graph never prompts),
  "Task(memory-recall)", "Bash(memory-index doctor|search|stats:*)", and
  "Bash(outl doctor --repair $MEM_DIR:*)" (scoped repair, skips the classifier).
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
