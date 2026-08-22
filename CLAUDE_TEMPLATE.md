# memory — persistent-memory system for Claude Code

This repo is the installer + source for the outl-backed persistent memory system.
`install.sh` deploys into `~/.claude`: `claude-memory-hook` (SessionStart/PreCompact),
`memory-index` (stdlib-only SQLite retrieval sidecar: FTS5 keyword + a typed/weighted
`[[link]]` edge table with a recursive multi-hop `search` whose depth follows graph size), `memory-consolidate` (headless
distillation agent), and `AGENTS.md` → `~/.claude/memory/`.

Global hard rules live in `~/.claude/CLAUDE.md` and are
**not** repeated here. The section below is the template `install.sh` appends to a
user's global `~/.claude/CLAUDE.md` — keep them in sync with the slim global version (they
reference the full protocol docs by path for on-demand reading, never via `@import`).

## Persistent memory

You have persistent, cross-session memory in an **outl** graph at `~/.claude/memory`
(via the `outl` MCP tools). A **SessionStart hook** injects the memory **index (TOC)** and
the **recent journal window** each session, so recent context is already in front of you.

Work from the injected index; retrieve deeper detail on demand with `outl_page_get <slug>`
(never brute-force the graph); append durable decisions/discoveries to today's journal as you
go. Retention is the **5 most recent journals**; distilling older ones into the knowledge tree
is **automatic** (hook + background agent) — never consolidate or delete journals by hand
unless a `⚠ CONSOLIDATION REQUIRED` fallback directive appears, then follow it.

Full protocol — graph model, crosslinking, writing, retrieval, condensation, frecency — is in
`~/.claude/memory/AGENTS.md`; read it **only when doing memory maintenance**, not every session.
