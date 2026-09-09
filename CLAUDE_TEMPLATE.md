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

This is your **active, vivid memory** — the persistence layer on this machine for who the
user is, the projects and concepts you work on together, and the decisions you've made. It is
an **outl** graph at `~/.claude/memory` (via the `outl` MCP tools), it is **always loaded** (a
**SessionStart hook** injects the **index (TOC)** and a **recent-journal window** every
session), and it is the **first place you look**, not a reference archive you consult last.

**Memory-first.** Before acting on anything the user says — before reaching for code, a file
or directory search, or the web — check it against memory. Read the injected index/journals
first; for anything deeper, **dispatch the `memory-recall` subagent** (Sonnet, read-only),
which walks the graph in an isolated context and returns the conclusion + `[[slugs]]` without
loading page bodies into the main thread. Reserve a direct `outl_page_get <slug>` for a quick
single-slug read; never brute-force the graph.

**Curate continuously.** Append durable decisions/discoveries to today's journal at each
checkpoint — don't wait for session end — and write impactful facts through to their knowledge
leaf. Retention is the **5 most recent journals**; distilling older ones into the knowledge
tree is **automatic** (hook + background agent) — never consolidate or delete journals by hand
unless a `⚠ CONSOLIDATION REQUIRED` fallback directive appears, then follow it.

Full protocol — graph model, crosslinking, writing, retrieval, condensation, frecency — is in
`~/.claude/memory/AGENTS.md`. That 28KB doc is **not** loaded every session (context economy);
read it **only when doing memory maintenance**. The memory itself, though, is always live.
