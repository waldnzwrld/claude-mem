# claude-mem — persistent memory for Claude Code

Cross-session memory for [Claude Code](https://claude.com/claude-code), built on an
[outl](https://github.com/outlmd/outl) markdown graph at `~/.claude/memory`. Recent context is
injected at session start, aged journals are distilled into a knowledge tree, and recall is
served by a stdlib-only SQLite sidecar.

The outl markdown graph is the **single source of truth**. The SQLite index, the injected
context, and the daily housekeeping are all derived from it and rebuildable from the markdown.

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

- **Journals** (`journals/YYYY-MM-DD.md`) hold the day's working notes. The agent appends
  durable facts as it works; on session close the **SessionEnd** hook runs `claude-memory-dump`
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

Deployed by `install.sh`:

| File | Installed to | Role |
|------|--------------|------|
| `AGENTS.md` | `~/.claude/memory/AGENTS.md` | The protocol the agent follows (graph model, crosslinking, writing, condensation, frecency, tags, retrieval). |
| `claude-memory-hook` | `~/.local/bin/` | SessionStart: inject TOC + recent journals, refresh the index, run daily chores. PreCompact: remind to flush notes. SessionEnd: fire the journaler. UserPromptSubmit: push-retrieval (gated). PostToolUse(`outl_page_get`): frecency touch. Exits 0 on any error. |
| `memory-index` | `~/.local/bin/` | Stdlib-only SQLite retrieval sidecar (see below). |
| `memory-consolidate` | `~/.local/bin/` | Headless agent (Sonnet 5, override `MEMORY_MODEL`) that distills aged journals into knowledge pages, then reaps them. Single-instanced. |
| `claude-memory-dump` | `~/.local/bin/` | SessionEnd journaler: a detached headless agent (Sonnet 5) that appends durable facts to today's journal, deduped. Skips sessions with no tool use; head/tail-truncates long transcripts. Edits only the journal. |
| `agents/memory-recall.md` | `~/.claude/agents/` | Read-only retrieval subagent (Sonnet, outl read tools only). Returns a conclusion + `[[slugs]]`, keeping page bodies out of the main thread. Its fetches still credit frecency. |
| `CLAUDE_TEMPLATE.md` | appended to `~/.claude/CLAUDE.md` | The `## Persistent memory` section pointing at the protocol. |

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
(default `~/.claude/memory`, or `$MEMORY_WS`).

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
outl init ~/.claude/memory
claude mcp add outl --scope user -- outl --workspace ~/.claude/memory mcp serve
```

Deploy:

```bash
./install.sh
```

`install.sh` copies the files into place, patches the hook's `outl` path for this machine's
Homebrew, wires the SessionStart + PreCompact + SessionEnd + UserPromptSubmit +
PostToolUse(`outl_page_get`) hooks into `~/.claude/settings.json`, allows the outl MCP server,
appends the `## Persistent memory` section to `~/.claude/CLAUDE.md` (idempotent), builds the
index, and (after an `outl backup`) normalizes the graph to the current standard. Start a new
Claude Code session to load the system.

## Uninstalling

```bash
./uninstall.sh
```

Removes the SessionStart + PreCompact + SessionEnd + UserPromptSubmit + PostToolUse hooks from
`~/.claude/settings.json` (other hooks intact), deletes the binaries from `~/.local/bin`, and
strips the `## Persistent memory` section from `~/.claude/CLAUDE.md`. It leaves
`~/.claude/memory` untouched, so a later `./install.sh` re-couples with nothing lost. Safe to
re-run; effective in a new session.

## Requirements

- **Claude Code** and the **outl** CLI + MCP server.
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
  hook; LLM distillation runs in a background headless agent.
- **Standards apply retroactively.** Conventions are versioned; `install.sh` migrates the
  existing graph up to a changed standard (backed up, idempotent).

## License

`claude-mem` is released under the [MIT License](LICENSE). It depends on external tools it does
not bundle — notably [outl](https://github.com/outlmd/outl) (MIT), which you install yourself.
See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency and licensing notes.
