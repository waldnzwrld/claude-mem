# memory — persistent-memory system for Claude Code

This repo is the installer + source for the outl-backed persistent memory system.
`install.sh` deploys into `~/.claude`: `claude-memory-hook` (SessionStart/PreCompact),
`memory-index` (stdlib-only SQLite retrieval sidecar), `memory-consolidate` (headless
distillation agent), and `AGENTS.md` → `~/.claude/memory/`.

Global hard rules (git-state discipline, nvim-only LSP) live in `~/.claude/CLAUDE.md` and are
**not** repeated here. The two sections below are the template `install.sh` appends to a
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

## Project CLAUDE.md protocol

Project repos' CLAUDE.md files form a linked tree of TOC docs — descend-on-demand,
split-on-growth, like the memory graph but plain markdown. Size the structure to the repo
(flat file → domain tree; you judge it, the user doesn't manage it); read the root CLAUDE.md
as an index, follow links on demand, keep each file small, store only what the repo can't
reconstruct. Full protocol, on demand: `~/.claude/project-claude-protocol.md`.
