# llm-harness-memory — persistent memory for LLM coding harnesses

Cross-session memory for LLM coding-agent harnesses, built on an
[outl](https://github.com/outlmd/outl) markdown graph at `~/.llm-harness-memory`. Recent context
is injected at session start, aged journals are distilled into a knowledge tree, and recall is
served by a stdlib-only SQLite sidecar. Every installed harness shares the one workspace, hook,
and index, so memory written in one is recalled in the others.

Supported harnesses:

| Harness | Integration | Headless agent |
|---------|-------------|----------------|
| [Claude Code](https://claude.com/claude-code) | native shell hooks in `~/.claude/settings.json` | `claude -p` |
| [omp (oh-my-pi)](https://github.com/can1357/oh-my-pi) | adapter extension `omp/llm-harness-memory.ts` | `omp -p` |

The core — the outl graph, `memory-index`, the protocol in `AGENTS.md`, and the hook logic — is
harness-agnostic. A harness plugs in by delivering its lifecycle events to the hook in the
[hook protocol](#hook-protocol) and naming itself via `MEMORY_HARNESS`, so background agents run
on the same CLI that fired them.

The outl markdown graph is the **single source of truth**. The SQLite index, the injected
context, and the daily housekeeping are all derived from it and rebuildable from the markdown.

## How it works

```
  Claude Code hooks ─┐
                     ├──► ┌──────────────────────────────────────────────────────┐
  omp extension ─────┘     |  memory-hook  (SessionStart / UserPromptSubmit /      │
                           │               PostToolUse / PreCompact / SessionEnd) │
                           │   start: inject index TOC + recent journals,         │
                           │          refresh the index, run daily chores         │
                           │   end:   flush the session's durable facts to today  │
                           └───────────┬──────────────────────────────┬───────────┘
                                           │ reads / writes               │ on close
                          ┌───────────▼───────────┐      ┌───────────▼───────────┐
                          │ outl graph            │      │ memory-dump           │
                          │ ~/.llm-harness-memory │◄─────┤ (headless agent →     │
                          │ pages/  journals/     │      │  today's journal)     │
                          │ (source of truth)     │      └───────────────────────┘
                          └───┬───────────────▲───┘      ┌───────────────────────┐
                      derives │               │◄────────►│ memory-index          │
                              ▼               │          │ (SQLite sidecar,      │
                       (SQLite index) ────────┘          │  FTS5 + [[link]])     │
                                               ▲         └───────────────────────┘
                                               │ distills aged journals (headless agent)
                                      ┌────────┴───────────┐
                                      │ memory-consolidate │
                                      └────────────────────┘
```

- **Journals** (`journals/YYYY-MM-DD.md`) hold the day's working notes. The agent appends
  durable facts as it works; on session close the **SessionEnd** hook runs `memory-dump`
  to flush anything uncaptured. The **5 most recent** journals are kept; older ones are distilled
  into the knowledge tree and reaped.
- **Knowledge pages** (`pages/*.md`) are a TOC tree linked by typed `[[wikilinks]]`. Retention
  is by **frecency**: `frecency::` is a checkpoint stamped at `seen::`, and effective frecency =
  `frecency − days_since(seen)`. A leaf/line is evicted at effective ≤ 0 (mechanical, no review).
  A fetch credits the page +5 (cap 60), stamps `seen = today`, and propagates +5 up the
  `parent::` chain. The daily sweep writes only evictions.
- **Retrieval auto-scales.** Below a node threshold, memory is read by TOC descent; at/above it,
  `memory-index search` is the entry point. The hook reports which regime is active.
- **Push-retrieval.** A `UserPromptSubmit` hook runs the index against each prompt and injects
  strong hits as pointers. Gated: index active, bm25 ceiling, ≤3 pointers, per-session dedup.
  Crediting runs in the background; `outl_page_get` also credits frecency via a `PostToolUse` hook.
- **Tags** are a curated `#tag` facet layer, orthogonal to `[[links]]`. `memory-index search`
  expands along shared `#topic/…` tags in parallel with the link walk. Numeric/off-vocabulary
  tags are filtered out; PR/issue `#numbers` are excluded and normalized on install.

## Components

Deployed by `install.sh`. Shared by every harness:

| File | Installed to | Role |
|------|--------------|------|
| `AGENTS.md` | `~/.llm-harness-memory/AGENTS.md` | The protocol the agent follows (graph model, crosslinking, writing, condensation, frecency, tags, retrieval). |
| `memory-hook` | `~/.local/bin/` | Shared by every harness. SessionStart: inject TOC + recent journals, refresh the index, run daily chores. PreCompact: remind to flush notes. SessionEnd: fire the journaler. UserPromptSubmit: push-retrieval (gated). PostToolUse(`outl_page_get`): frecency touch. Speaks the [hook protocol](#hook-protocol). Exits 0 on any error. |
| `memory-index` | `~/.local/bin/` | Stdlib-only SQLite retrieval sidecar (see below). |
| `memory-agent` | `~/.local/bin/` | Runs one headless maintenance agent on the harness that fired the hook (`MEMORY_HARNESS`: `claude -p` or `omp -p`), Sonnet 5 by default (`MEMORY_MODEL`). `--ws DIR` scopes its outl MCP server to a workspace. |
| `memory-consolidate` | `~/.local/bin/` | Headless agent (via `memory-agent`) that distills aged journals into knowledge pages, then reaps them. Single-instanced. |
| `memory-dump` | `~/.local/bin/` | SessionEnd journaler: a detached headless agent (via `memory-agent`) that appends durable facts to today's journal, deduped. Skips sessions with no tool use; head/tail-truncates long transcripts. Edits only the journal. |

Per harness:

| File | Claude Code | omp | Role |
|------|-------------|-----|------|
| `agents/memory-recall.md` | `~/.claude/agents/` | `~/.omp/agent/agents/` (tools/model rewritten to omp names) | Read-only retrieval subagent (Sonnet). Returns a conclusion + `[[slugs]]`, keeping page bodies out of the main thread. Its fetches still credit frecency. |
| `MEMORY_TEMPLATE.md` | `## Persistent memory` appended to `~/.claude/CLAUDE.md` | same section appended to `~/.omp/agent/AGENTS.md` | Points the agent at the protocol. |
| hook wiring | `~/.claude/settings.json` hooks + outl allow rules | `omp/llm-harness-memory.ts` → `~/.omp/agent/extensions/` | Delivers lifecycle events to `memory-hook`. |

## `memory-index` — the retrieval sidecar

A single Python file that builds a derived, disposable SQLite index over the markdown graph.
Stdlib only — `sqlite3`/FTS5 from CPython 3.9+; no packages, venv, build step, model, or
network. Delete the index and `rebuild` reconstructs it from the markdown.

- **Lexical recall:** Porter-stemmed, diacritic-folded, prefix-matched; field-weighted bm25
  across three columns (title ≫ heading ≫ body).
- **Graph expansion:** a recursive walk of the typed, weighted `[[link]]` edge table outward
  from the keyword hits. Edge type (`refs` / `supersedes` / `contradicts` / `part-of`) is
  inferred from the wording around each link; the markdown is never annotated. Hop depth scales
  with graph size (1 → 2 → 3).
- **Tag expansion:** a parallel axis from the same seeds (and any `#topic/…` named in the query)
  that pulls pages sharing a curated `#tag` via an indexed join. Numeric/off-vocabulary tags are
  filtered; `[[links]]` keep ranking primacy (tags are additive, never structural).

```
memory-index rebuild        # full reindex from markdown (idempotent)
memory-index refresh        # incremental: reindex only pages whose content changed
memory-index search "q"     # field-weighted bm25 hits + [[link]] graph walk + tag expansion
                            #   (--json for machine output; consumed by the push hook)
memory-index touch <slug>…  # credit a use: frecency +5 (cap 60), seen=today, up the parent chain
memory-index stats          # node/chunk/edge counts, freshness, active/inactive
memory-index doctor         # read-only health report: link graph + tag-noise (--json)
memory-index medic          # prune pathological edges from the index (--dry-run, --off)
memory-index maintain       # daily lazy-decay sweep: evict at effective 0, stamp seen on first
                            #   sight; reports split candidates
memory-index consolidate    # journal-consolidation backlog; --reap deletes aged journals
                            #   the distiller marked `consolidated::`
memory-index normalize      # migrate the graph to the current standard (versioned, idempotent):
                            #   --status | --apply | --force
```

`search` flags: `-k N` (result count), `--no-graph` (keyword only). Workspace: `-w <dir>`
(default `~/.llm-harness-memory`, or `$MEMORY_WS`).

### `doctor` and `medic`

Both operate on the derived index only and never edit the markdown.

- **`doctor`** — read-only report: orphans, dangling `[[links]]`, connected components, hub node,
  superseded targets, effective-frecency decay-risk, and **tag-noise** (numeric/off-vocabulary
  `#tags`). Performance-first verdict; `--json` for scripts.
- **`medic`** — prunes pathological edges from the index: dangling links and self-loops by
  default; opt-in `--cap-hubs N` and `--prune-superseded`. The heal set is persisted as a policy
  and re-applied on every `refresh`. `--dry-run` previews; `--off` restores edges from markdown.
  Dead `[[links]]` stay in the source (they may be intentional placeholders); the medic only
  stops the graph walk from traversing them.

### `normalize` — migrate to the current standard

Conventions apply retroactively. `memory-index normalize` brings the existing graph up to the
current standard, versioned by a `.standard-version` marker (idempotent; a no-op once current).
`install.sh` runs it after an `outl backup`. Flags: `--status`, `--apply`, `--force`.

Migration v1 strips PR/issue `#`-number tags: drop the `#`, adding `PR` only when not already
labeled (`closed #450` → `closed PR 450`, `PR #272` → `PR 272`, `PR#273` → `PR 273`). Markdown
links `[#272](url)` and non-references like `C#9` are left untouched. A block `outl` refuses to
rewrite (e.g. a journal whose `.md` is ahead of the op log) is skipped and flagged by `doctor`.

## Installation

Prerequisites (`install.sh` does not do these):

```bash
brew tap outlmd/outl https://github.com/outlmd/outl
brew trust outlmd/outl
brew install outl-beta
outl init ~/.llm-harness-memory
# Claude Code:
claude mcp add outl --scope user -- outl --workspace ~/.llm-harness-memory mcp serve
# omp: add to ~/.omp/agent/mcp.json (or `/mcp add` → User level)
#   { "mcpServers": { "outl": { "type": "stdio", "command": "/opt/homebrew/bin/outl",
#       "args": ["--workspace", "/Users/<you>/.llm-harness-memory", "mcp", "serve"] } } }
```

Deploy:

```bash
./install.sh                    # Claude Code (default)
./install.sh --harness omp      # omp only
./install.sh --harness all      # both (also: --harness claude,omp)
```

Shared for every harness, `install.sh` copies `AGENTS.md` into the workspace and the binaries
into `~/.local/bin`, patches the `outl` path in `memory-hook` and `memory-agent` for this
machine's Homebrew, and builds the index.

- **Claude Code:** wires the SessionStart + PreCompact + SessionEnd + UserPromptSubmit +
  PostToolUse(`outl_page_get`) hooks into `~/.claude/settings.json`, allows the outl MCP server,
  installs the `memory-recall` agent, and appends the `## Persistent memory` section to
  `~/.claude/CLAUDE.md` (idempotent).
- **omp:** installs the adapter extension to `~/.omp/agent/extensions/llm-harness-memory.ts`, the
  `memory-recall` task agent to `~/.omp/agent/agents/`, and appends the `## Persistent memory`
  section to `~/.omp/agent/AGENTS.md` (idempotent). Reports whether `~/.omp/agent/mcp.json`
  already serves `outl`. `OMP_AGENT_DIR` targets another agent dir (e.g. a profile).

Start a new session to load the system.

## Upgrading from claude-mem

An install from before the rename (workspace `~/.claude/memory`, binaries `claude-memory-hook` /
`claude-memory-dump`, omp extension `claude-memory.ts`) is migrated in place:

```bash
./upgrade.sh            # close every Claude Code / omp session first
./upgrade.sh --force    # skip the check for processes still using the old workspace
```

`upgrade.sh` moves the workspace to `~/.llm-harness-memory`, binds the new path to the
workspace's existing outl actor, repoints the outl MCP server in `~/.claude.json` and
`~/.omp/agent/mcp.json`, rewrites workspace-scoped permission rules in `~/.claude/settings.json`,
removes the old binaries, hook entries, extension, and `## Persistent memory` sections, then runs
`install.sh` for every harness that was wired. Each step is a no-op once done, so it is safe to
re-run. `install.sh` refuses to run while `~/.claude/memory` exists and points here instead.

The actor binding matters: outl records this machine's actor per workspace root in
`~/.config/outl/actors/`. Opening a moved root under a fresh actor replays the op log without the
old actor's page shards, and deleted pages and reaped journals reappear. `upgrade.sh` writes the
binding before outl first opens the new path.

## Hook protocol

`memory-hook` is the single integration point for every harness. It reads one JSON event
on stdin, writes its response on stdout, and always exits 0. The wire format is Claude Code's
hook schema, which Claude Code emits natively; any other harness adapts its own events to it.

| `hook_event_name` | Input fields used | Output |
|-------------------|-------------------|--------|
| `SessionStart` | — | `hookSpecificOutput.additionalContext`: index TOC, journals, chores status |
| `UserPromptSubmit` | `prompt`, `session_id` | `hookSpecificOutput.additionalContext`: push-retrieval pointers (gated) |
| `PostToolUse` | `tool_name` (`mcp__outl__outl_page_get` or `mcp__outl_page_get`), `tool_input.slug` | none; backgrounds the frecency touch |
| `PreCompact` | — | `systemMessage`: flush reminder |
| `SessionEnd` | `transcript_path` | none; detaches `memory-dump` |

The adapter also exports `MEMORY_HARNESS=<name>`; `memory-agent` reads it to run the background
agents (`memory-consolidate`, `memory-dump`) on that harness's headless CLI. Adding a
harness means an adapter for its events plus a `MEMORY_HARNESS` case in `memory-agent`.

## omp

omp has no shell-command hooks; `omp/llm-harness-memory.ts` is an extension that translates omp
events into the hook protocol and runs `memory-hook` with `MEMORY_HARNESS=omp`:

| omp event | Hook event | Effect |
|-----------|------------|--------|
| `session_start`, `session_switch` | SessionStart | Context is computed at session start and delivered as a hidden custom message with the first prompt. |
| `before_agent_start` | UserPromptSubmit | Push-retrieval pointers joined into the same hidden message. |
| `tool_result` (`mcp__outl_page_get`) | PostToolUse | Frecency touch, including fetches made by subagents. |
| `session.compacting` | PreCompact | Reminder added to the compaction summary's context. |
| `session_before_switch`, `session_shutdown` | SessionEnd | Detached `memory-dump` on the session's JSONL transcript. |

Behaviour that differs from Claude Code (the native-hook reference integration):

- Background agents run as `omp -p --approval-mode yolo --no-session`. omp has no per-run MCP
  flag, so `memory-agent --ws` scopes outl with a project `.omp/mcp.json` in a scratch cwd.
  `MEMORY_MODEL` takes an omp selector (default `claude-sonnet-5`, resolved fuzzily across
  providers).
- Injection, push-retrieval, and the journaler are main-session only (`ctx.agent.kind`); the
  touch also fires in subagents.
- omp subagents receive every MCP tool regardless of `tools:`, so `memory-recall`'s read-only
  contract rests on its prompt.
- omp's default approval mode (`yolo`) runs outl tools without prompting. Under a stricter
  `tools.approvalMode`, outl tools (approval tier `write`) prompt unless allowed per tool in
  `tools.approval`.
- `~/.omp/agent/AGENTS.md` shadows `~/.claude/CLAUDE.md` as user context, so the memory section
  is appended there.

## Uninstalling

```bash
./uninstall.sh                    # every harness (default)
./uninstall.sh --harness omp      # one harness; the other keeps working
```

Claude Code: removes the SessionStart + PreCompact + SessionEnd + UserPromptSubmit +
PostToolUse hooks from `~/.claude/settings.json` (other hooks intact), the agent definition, and
the `## Persistent memory` section from `~/.claude/CLAUDE.md`. omp: removes the extension, the
task agent, and the section from `~/.omp/agent/AGENTS.md`. The shared binaries in
`~/.local/bin` are deleted only once no harness is still wired. It leaves `~/.llm-harness-memory`
untouched, so a later `./install.sh` re-couples with nothing lost. Safe to re-run; effective in
a new session.

## Requirements

- At least one supported harness — **Claude Code** and/or **omp** — plus the **outl** CLI + MCP
  server.
- **Python 3.9+** (standard library only).
- **macOS** — the hook resolves `outl` via Homebrew; override with `OUTL_BIN` elsewhere.

## Design principles

- **One source of truth.** The markdown graph is authoritative; the SQLite index is a
  rebuildable projection, rebuilt (never migrated in place) when its schema changes.
- **Zero dependencies for retrieval.** `memory-index` is stdlib-only: no packages, build, model,
  or network.
- **Degrade gracefully.** If the index or its tooling is missing, memory still works via TOC
  traversal; the hooks are best-effort and exit 0.
- **Self-maintaining.** Consolidation and frecency decay run automatically from the SessionStart
  hook; LLM distillation runs in a background headless agent on whichever harness fired the hook.
- **Harness-agnostic core.** Graph, index, protocol, and hook are shared; a harness contributes
  only an event adapter and a headless-CLI invocation.
- **Standards apply retroactively.** Conventions are versioned; `install.sh` migrates the
  existing graph up to a changed standard (backed up, idempotent).

## License

`llm-harness-memory` is released under the [MIT License](LICENSE). It depends on external tools
it does not bundle — notably [outl](https://github.com/outlmd/outl) (MIT), which you install
yourself. See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency and licensing notes.
