#!/usr/bin/env bash
#
# install.sh — put the llm-harness-memory system files into place for one or more
# agent harnesses (Claude Code, omp).
#
# Run this AS YOUR NORMAL USER on the target Mac (not sudo):
#
#     ./install.sh                      # Claude Code (default)
#     ./install.sh --harness omp        # oh-my-pi (omp)
#     ./install.sh --harness all        # both; also: --harness claude,omp
#
# Every harness shares one memory workspace (~/.llm-harness-memory), one hook, one index,
# and the same helper binaries in ~/.local/bin; each harness only adds its own wiring.
#
# Claude Code: copies the agent definition, appends the memory section to
# ~/.claude/CLAUDE.md, wires the SessionStart/PreCompact/SessionEnd/UserPromptSubmit/
# PostToolUse hooks into settings.json, and allows the whole outl MCP server (plus
# memory-recall + memory-index) so the memory graph is invisible and never prompts.
#
# omp: installs the adapter extension (omp/llm-harness-memory.ts) that drives the same hook
# from omp lifecycle events, the memory-recall task agent, and the memory section in
# ~/.omp/agent/AGENTS.md. Override the agent dir with OMP_AGENT_DIR.
#
# It does NOT initialize the outl workspace or register the outl MCP server — do those
# yourself:
#
#     brew tap outlmd/outl https://github.com/outlmd/outl
#     brew trust outlmd/outl
#     brew install outl-beta
#     outl init ~/.llm-harness-memory
#     claude mcp add outl --scope user -- outl --workspace ~/.llm-harness-memory mcp serve   # Claude Code
#     # omp: add the `outl` server to ~/.omp/agent/mcp.json (snippet printed below)
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
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ "$WANT_CLAUDE" = 1 ] || [ "$WANT_OMP" = 1 ] || WANT_CLAUDE=1

CLAUDE_DIR="$HOME/.claude"
MEM_DIR="$HOME/.llm-harness-memory"
BIN_DIR="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDEMD="$CLAUDE_DIR/CLAUDE.md"
HOOK="$BIN_DIR/memory-hook"
MEMIDX="$BIN_DIR/memory-index"
AGENTS_DIR="$CLAUDE_DIR/agents"
OMP_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"

if [ -d "$HOME/.claude/memory/.outl" ] && ! [ -e "$MEM_DIR" ]; then
  echo "✖ found a workspace at ~/.claude/memory; run ./upgrade.sh to move it to $MEM_DIR" >&2
  exit 1
fi
mkdir -p "$MEM_DIR" "$BIN_DIR"

# append_memory_section <file> <whole-template-if-missing: yes|no>
# Idempotently appends MEMORY_TEMPLATE.md's "## Persistent memory" section to <file>.
# Shipped sections reference the protocol docs by ~ path (user-agnostic, read on demand —
# no @import), so no path rewrite is needed.
append_memory_section() {
  local file="$1" whole="$2" label section
  label="$(basename "$file")"
  if [ -f "$file" ] && grep -q '^## Persistent memory' "$file"; then
    echo "• $label already has the memory section; left as-is ($file)"
    return
  fi
  section="$(awk '/^## Persistent memory/{p=1} p' "$SRC/MEMORY_TEMPLATE.md")"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ]; then
    printf '\n\n%s\n' "$section" >> "$file"
    echo "✔ $label -> appended memory section to $file"
  elif [ "$whole" = yes ]; then
    cp "$SRC/MEMORY_TEMPLATE.md" "$file"
    echo "✔ $label -> $file"
  else
    printf '%s\n' "$section" > "$file"
    echo "✔ $label -> $file"
  fi
}

# ======================= shared: workspace protocol + binaries =======================

# ---- 1. protocol doc --------------------------------------------------------
cp "$SRC/AGENTS.md" "$MEM_DIR/AGENTS.md"
echo "✔ AGENTS.md      -> $MEM_DIR/AGENTS.md"

# ---- 2. binaries (patch the outl path for this machine's Homebrew) ----------
if command -v brew >/dev/null 2>&1; then
  OUTL_PATH="$(brew --prefix)/bin/outl"
else
  OUTL_PATH="/opt/homebrew/bin/outl"   # Apple-Silicon default; Intel is /usr/local/bin/outl
fi
# memory-hook: every harness's lifecycle events; memory-agent: headless runner
# (claude -p | omp -p) for the background agents.
for f in memory-hook memory-agent; do
  tmp="$(mktemp)"
  sed "s|^OUTL=.*|OUTL=\"\${OUTL_BIN:-$OUTL_PATH}\"|" "$SRC/$f" > "$tmp"
  mv "$tmp" "$BIN_DIR/$f"
  chmod 755 "$BIN_DIR/$f"
  echo "✔ $f -> $BIN_DIR/$f  (outl: $OUTL_PATH)"
done
# memory-index: retrieval sidecar; memory-consolidate: automatic headless distillation
# of aged journals; memory-dump: on-close journaler (fired by SessionEnd).
for f in memory-index memory-consolidate memory-dump; do
  cp "$SRC/$f" "$BIN_DIR/$f"
  chmod 755 "$BIN_DIR/$f"
  echo "✔ $f -> $BIN_DIR/$f"
done

# ================================= Claude Code ======================================
if [ "$WANT_CLAUDE" = 1 ]; then

# ---- 3. memory-recall subagent: isolated read-only retrieval (keeps page ----
#          bodies out of the main thread). Deployed as a Claude Code agent def.
mkdir -p "$AGENTS_DIR"
for a in "$SRC"/agents/*.md; do
  [ -e "$a" ] || continue
  cp "$a" "$AGENTS_DIR/$(basename "$a")"
  echo "✔ agent          -> $AGENTS_DIR/$(basename "$a")"
done

# ---- 4. CLAUDE.md (append the memory section if it isn't already there) ------
append_memory_section "$CLAUDEMD" yes

# ---- 5. wire hooks + auto-allow read-only recall tools into settings.json ----
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

fi # WANT_CLAUDE

# ===================================== omp ==========================================
OMP_MCP_TODO=0
if [ "$WANT_OMP" = 1 ]; then

# ---- 6. adapter extension: omp lifecycle events -> memory-hook --------
mkdir -p "$OMP_DIR/extensions" "$OMP_DIR/agents"
cp "$SRC/omp/llm-harness-memory.ts" "$OMP_DIR/extensions/llm-harness-memory.ts"
echo "✔ omp extension  -> $OMP_DIR/extensions/llm-harness-memory.ts"

# ---- 7. memory-recall task agent -------------------------------------------
# omp agents take omp tool names and model selectors. MCP tools reach omp subagents
# regardless of `tools`, so the read-only contract rests on the agent prompt.
for a in "$SRC"/agents/*.md; do
  [ -e "$a" ] || continue
  awk 'NR == 1 && /^---$/ { fm = 1; print; next }
       fm && /^---$/      { fm = 0; print; next }
       fm && /^tools:/    { print "tools: read, grep"; next }
       fm && /^model:/    { print "model: claude-sonnet-5"; next }
       { print }' "$a" > "$OMP_DIR/agents/$(basename "$a")"
  echo "✔ omp agent      -> $OMP_DIR/agents/$(basename "$a")"
done

# ---- 8. user context: omp's ~/.omp/agent/AGENTS.md (shadows ~/.claude/CLAUDE.md) ----
append_memory_section "$OMP_DIR/AGENTS.md" no

# ---- 9. outl MCP server: report whether omp already serves it ---------------
if python3 - "$OMP_DIR/mcp.json" <<'PY' 2>/dev/null
import json, sys
try:
    servers = json.load(open(sys.argv[1])).get("mcpServers") or {}
except Exception:
    sys.exit(1)
sys.exit(0 if "outl" in servers else 1)
PY
then
  echo "• omp mcp.json already serves outl; left as-is"
else
  OMP_MCP_TODO=1
fi

fi # WANT_OMP

cat <<EOF

Done. Files are in place. Remaining steps (you said you'd handle these):
  - brew install outl (outlmd/outl tap) if not already installed
  - outl init $MEM_DIR
EOF
if [ "$WANT_CLAUDE" = 1 ]; then
  echo "  - Claude Code: claude mcp add outl --scope user -- outl --workspace $MEM_DIR mcp serve"
fi
if [ "$OMP_MCP_TODO" = 1 ]; then
  cat <<EOF
  - omp: add the outl server to $OMP_DIR/mcp.json:
      { "mcpServers": { "outl": { "type": "stdio", "command": "$OUTL_PATH",
          "args": ["--workspace", "$MEM_DIR", "mcp", "serve"] } } }
EOF
fi
cat <<EOF
  - build the retrieval index (safe to re-run any time; the SessionStart hook
    keeps it fresh afterward):  $MEMIDX rebuild

Then start a NEW session to load the memory system.
EOF

# Build the index now if the workspace already exists, so it's ready immediately.
if [ -d "$MEM_DIR/pages" ]; then
  "$MEMIDX" -w "$MEM_DIR" rebuild >/dev/null 2>&1 \
    && echo "✔ memory-index   -> built initial index at $MEM_DIR/.outl/index.sqlite" \
    || echo "• memory-index   -> run '$MEMIDX rebuild' after 'outl init' to build the index"
fi
