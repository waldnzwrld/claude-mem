# claude-mem — persistent memory for Claude Code

A cross-session memory system for [Claude Code](https://claude.com/claude-code), built on
an [outl](https://github.com/outlmd/outl) knowledge graph of linked markdown. It gives an
agent durable, self-maintaining memory: recent context is injected at session start,
older notes are automatically distilled into a knowledge tree, and recall is served by a
dependency-free SQLite retrieval sidecar.

The **outl markdown graph at `~/.claude/memory` is the single source of truth.** Everything
else — the SQLite index, the injected context, the daily housekeeping — is derived from it
and can be rebuilt from the markdown on any machine.

## How it works

```
                ┌─────────────────────────────────────────────┐
   session      │  claude-memory-hook  (SessionStart / PreCompact)
   starts  ───► │   • injects the index TOC + recent journals   │
                │   • refreshes the retrieval index             │
                │   • runs daily frecency + consolidation chores│
                └───────────────┬─────────────────────────────┘
                                │  reads / writes
                     ┌──────────▼───────────┐        ┌────────────────────┐
                     │  outl graph           │◄──────►│  memory-index       │
                     │  ~/.claude/memory     │ derives│  (SQLite sidecar,   │
                     │   pages/  journals/   │        │   FTS5 + [[link]]   │
                     │   (source of truth)   │        │   graph walk)       │
                     └───────────────────────┘        └────────────────────┘
                                ▲
                                │ distills aged journals (headless `claude -p`)
                        ┌───────┴──────────┐
                        │ memory-consolidate│
                        └──────────────────┘
```

- **Journals** (`journals/YYYY-MM-DD.md`) capture the working narrative day by day. The
  **5 most recent** are kept in high resolution; anything older is **distilled** into the
  knowledge tree and reaped — automatically.
- **Knowledge pages** (`pages/*.md`) are the durable, deduplicated memory: a tree of
  tables-of-contents linked by typed `[[wikilinks]]`, with `frecency` decay so stale
  leaves surface as prune candidates.
- **Retrieval auto-scales.** Below a node threshold the graph is small enough to read by
  descending the TOC; at/above it, `memory-index search` becomes the search-first entry
  point. The hook tells the agent which regime is active.

## Components

Everything is deployed by `install.sh`:

| File | Installed to | Role |
|------|--------------|------|
| `AGENTS.md` | `~/.claude/memory/AGENTS.md` | The full protocol the agent follows (graph model, crosslinking, writing, condensation, frecency, retrieval). |
| `claude-memory-hook` | `~/.local/bin/` | SessionStart: inject TOC + recent-journal window, refresh the index, run daily chores. PreCompact: remind the agent to flush notes before compaction. Designed to never fail a session. |
| `memory-index` | `~/.local/bin/` | Stdlib-only SQLite retrieval sidecar (see below). |
| `memory-consolidate` | `~/.local/bin/` | Headless `claude -p` agent that distills aged journals into knowledge pages, then reaps them. Single-instanced, safe to re-run. |
| `CLAUDE_TEMPLATE.md` | appended to `~/.claude/CLAUDE.md` | The `## Persistent memory` section that points the agent at the protocol. |

## `memory-index` — the retrieval sidecar

A single Python file that builds a **derived, disposable** SQLite index over the markdown
graph so recall lands on the right band in one shot, then walks outward along `[[links]]`.

**No dependencies.** Stdlib only — the `sqlite3`/FTS5 that ship with CPython 3.9+. No
third-party packages, no virtualenv, no build step, **no model and no network.** Delete
the index and `rebuild` reconstructs it from the markdown anywhere.

**Lexical recall** is Porter-stemmed (so `consolidate` matches `consolidation`),
diacritic-folded, and prefix-matched (`consol*` → `consolidation`), ranked by
**field-weighted bm25** across three columns — page **title ≫ heading ≫ body** — so a
title hit outranks an incidental body mention.

**Graph expansion** walks the typed, weighted `[[link]]` edge table outward from the
keyword hits via a recursive query. Edge *type* (`refs` / `supersedes` / `contradicts` /
`part-of`) is inferred from the wording around each link — the markdown is never annotated,
so the source stays clean. Hop depth scales with graph size (1 → 2 → 3).

```
memory-index rebuild        # full reindex from markdown (idempotent)
memory-index refresh        # incremental: reindex only pages whose content changed
memory-index search "q"     # field-weighted bm25 hits + typed [[link]] graph walk
memory-index stats          # node/chunk/edge counts, freshness, active/inactive
memory-index maintain       # daily frecency decay sweep (reports prune candidates)
memory-index consolidate    # report the journal-consolidation backlog; --reap deletes
                            #   aged journals verified as already distilled
```

`search` flags: `-k N` (result count), `--no-graph` (keyword only).
Workspace is `-w <dir>` (default `~/.claude/memory`, or `$MEMORY_WS`).

## Installation

**Prerequisites** (do these yourself — `install.sh` does not):

```bash
brew tap outlmd/outl https://github.com/outlmd/outl
brew trust outlmd/outl
brew install outl-beta
outl init ~/.claude/memory
claude mcp add outl --scope user -- outl --workspace ~/.claude/memory mcp serve
```

**Then deploy the memory system:**

```bash
./install.sh
```

`install.sh` copies the files into place, patches the hook's `outl` path for this machine's
Homebrew, wires the SessionStart + PreCompact hooks into `~/.claude/settings.json`, appends
the `## Persistent memory` section to `~/.claude/CLAUDE.md` (idempotently), and builds the
initial index if the workspace exists.

Start a **new** Claude Code session to load the memory system.

## Requirements

- **Claude Code** and the **outl** CLI + MCP server.
- **Python 3.9+** (standard library only — used by `memory-index` and the hook).
- **macOS** — the hook resolves `outl` via Homebrew; override with `OUTL_BIN` elsewhere.

## Design principles

- **One source of truth.** The markdown graph is authoritative; the SQLite index is a pure,
  rebuildable projection — never migrated in place, just rebuilt when the schema changes.
- **Zero dependencies for retrieval.** `memory-index` is stdlib-only: no packages, no build,
  no model, no network. It works on any machine that has Python.
- **Degrade gracefully.** If the index or its tooling is missing, memory still works via
  TOC traversal. The hooks are best-effort and exit 0 — a broken helper never fails a
  session.
- **Self-maintaining.** Journal consolidation and frecency decay run automatically from the
  SessionStart hook, with a headless agent doing the LLM distillation in the background.
