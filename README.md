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
                ┌───────────────────────────────────────────────────┐
  session ───► │  claude-memory-hook   (SessionStart / PreCompact /   │
  start/end    │                        SessionEnd)                   │
                │   start: inject index TOC + recent journals,        │
                │          refresh the index, run daily chores        │
                │   end:   flush the session's durable facts to today │
                └───────────────┬───────────────────────┬────────────┘
                                │  reads / writes        │ on close
                     ┌──────────▼───────────┐   ┌────────▼───────────┐
                     │  outl graph           │   │ claude-memory-dump │
                     │  ~/.claude/memory     │   │ (headless Sonnet →  │
                     │   pages/  journals/   │◄──┤  today's journal)   │
                     │   (source of truth)   │   └────────────────────┘
                     └───────┬──────────▲────┘   ┌────────────────────┐
                     derives │          │◄──────►│  memory-index       │
                             ▼          │        │  (SQLite sidecar,   │
                     (SQLite index) ────┘        │   FTS5 + [[link]])  │
                                ▲                 └────────────────────┘
                                │ distills aged journals (headless Sonnet)
                        ┌───────┴──────────┐
                        │ memory-consolidate│
                        └──────────────────┘
```

- **Journals** (`journals/YYYY-MM-DD.md`) capture the working narrative day by day. The
  agent appends durable facts as it works; on session close the **SessionEnd** hook runs a
  cheap headless agent (`claude-memory-dump`) that flushes anything still uncaptured — so
  journaling never depends on a context compaction happening. The **5 most recent** journals
  are kept in high resolution; anything older is **distilled** into the knowledge tree and
  reaped — automatically.
- **Knowledge pages** (`pages/*.md`) are the durable, deduplicated memory: a tree of
  tables-of-contents linked by typed `[[wikilinks]]`, with `frecency` decay so stale
  leaves surface as prune candidates.
- **Retrieval auto-scales.** Below a node threshold the graph is small enough to read by
  descending the TOC; at/above it, `memory-index search` becomes the search-first entry
  point. The hook tells the agent which regime is active.
- **Retrieval is also pushed, not only pulled.** A `UserPromptSubmit` hook runs the index
  against each prompt and injects the strong hits as pointers before the agent acts — so
  relevant memory surfaces even when the agent wouldn't have thought to look. It's gated
  conservatively (bm25 ceiling, ≤3 pointers, deduped per session) so trivial prompts inject
  nothing. Fetching a surfaced page (`outl_page_get`) then credits its frecency via a
  `PostToolUse` hook, closing the loop the daily decay sweep opens.

## Components

Everything is deployed by `install.sh`:

| File | Installed to | Role |
|------|--------------|------|
| `AGENTS.md` | `~/.claude/memory/AGENTS.md` | The full protocol the agent follows (graph model, crosslinking, writing, condensation, frecency, retrieval). |
| `claude-memory-hook` | `~/.local/bin/` | SessionStart: inject TOC + recent-journal window, refresh the index, run daily chores. PreCompact: remind the agent to flush notes before compaction. SessionEnd: fire the on-close journaler. **UserPromptSubmit: push-retrieval** — surface memory relevant to the prompt as pointers (conservative bm25 gate, deduped per session). **PostToolUse(`outl_page_get`): frecency touch** — credit a fetched leaf's use. Designed to never fail a session. |
| `memory-index` | `~/.local/bin/` | Stdlib-only SQLite retrieval sidecar (see below). |
| `memory-consolidate` | `~/.local/bin/` | Headless agent that distills aged journals into knowledge pages, then reaps them. Runs on **Sonnet 5** (override with `MEMORY_MODEL`). Single-instanced, safe to re-run. |
| `claude-memory-dump` | `~/.local/bin/` | On-close journaler fired by the SessionEnd hook: a detached headless agent reads the session transcript and appends only the durable facts to today's journal, deduping against existing entries. Runs on **Sonnet 5**; never edits anything but the journal. |
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
keyword hits via a recursive query — seeded by the keyword hits, it reaches associatively
related nodes the query never matched lexically (spreading-activation style recall). Edge
*type* (`refs` / `supersedes` / `contradicts` / `part-of`) is inferred from the wording
around each link — the markdown is never annotated, so the source stays clean. Hop depth
scales with graph size (1 → 2 → 3).

```
memory-index rebuild        # full reindex from markdown (idempotent)
memory-index refresh        # incremental: reindex only pages whose content changed
memory-index search "q"     # field-weighted bm25 hits + typed [[link]] graph walk
                            #   (--json for machine output; consumed by the push hook)
memory-index touch <slug>…  # credit a use: frecency +5 (cap 60), seen=today, on the named
                            #   knowledge leaves (fired by the PostToolUse page-get hook)
memory-index stats          # node/chunk/edge counts, freshness, active/inactive
memory-index doctor         # read-only link-graph health report (--json)
memory-index medic          # prune pathological edges from the index (--dry-run, --off)
memory-index maintain       # daily frecency decay sweep (reports prune candidates)
memory-index consolidate    # report the journal-consolidation backlog; --reap deletes
                            #   aged journals the distiller marked `consolidated::`
```

`search` flags: `-k N` (result count), `--no-graph` (keyword only).
Workspace is `-w <dir>` (default `~/.claude/memory`, or `$MEMORY_WS`).

### Graph health: `doctor` and `medic`

Associative recall is only as good as the link graph, so two commands keep it honest —
both operate on the **derived index only and never edit your markdown**:

- **`doctor`** — a read-only health report: orphans, dangling links (`[[links]]` to
  non-existent pages), connected components (fragmentation), the hub node, superseded
  targets, and frecency decay-risk, with a performance-first verdict. `--json` for scripts.
- **`medic`** — prunes pathological edges from the index for performance/precision:
  **dangling links** and **self-loops** by default, with opt-in `--cap-hubs N` (cap a
  node's out-edges to the top-N by weight) and `--prune-superseded`. The heal set is
  persisted as a policy, so every `refresh` (including the SessionStart hook's) keeps the
  graph healthy. `--dry-run` previews; `--off` disables and restores edges from markdown.

A dead `[[link]]` is often an intentional placeholder for a page yet to be written, so the
medic leaves it in the source and merely stops the graph walk from wasting hops on it.

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
Homebrew, wires the SessionStart + PreCompact + SessionEnd hooks into
`~/.claude/settings.json`, appends the `## Persistent memory` section to
`~/.claude/CLAUDE.md` (idempotently), and builds the initial index if the workspace exists.

Start a **new** Claude Code session to load the memory system.

## Uninstalling

```bash
./uninstall.sh
```

Reverses `install.sh`'s three coupling actions: removes the SessionStart + PreCompact +
SessionEnd hooks from `~/.claude/settings.json` (leaving any other hooks intact), deletes the
deployed binaries from `~/.local/bin`, and strips the `## Persistent memory` section from
`~/.claude/CLAUDE.md`.

It **deliberately leaves `~/.claude/memory` and everything in it untouched** — your
`pages/`, `journals/`, `AGENTS.md`, and the derived index all remain. This decouples the
agent from the memory system without deleting any memory, so a later `./install.sh`
re-couples everything with nothing lost. Safe to re-run (it no-ops on anything already
removed); the change takes effect in a new session.

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

## License

`claude-mem` is released under the [MIT License](LICENSE).

It depends on external tools it does not bundle or redistribute — notably
[outl](https://github.com/outlmd/outl) (MIT), which you install yourself. See
[THIRD_PARTY.md](THIRD_PARTY.md) for the dependency and licensing notes.
