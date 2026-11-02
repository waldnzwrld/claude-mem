# memory — persistent-memory system for LLM coding harnesses

This repo (llm-harness-memory) is the installer + source for the outl-backed persistent memory
system, shared by every supported harness (Claude Code, omp, pi). `install.sh` deploys
`memory-hook` (the shared lifecycle hook), `memory-index` (stdlib-only SQLite retrieval
sidecar: FTS5 keyword + a typed/weighted `[[link]]` edge table with a recursive multi-hop
`search` whose depth follows graph size), `memory-consolidate` (headless distillation agent,
run on the harness that fired the hook via `memory-agent`), and `AGENTS.md` →
`~/.llm-harness-memory/`.

The section below is the template `install.sh` appends to each harness's global user-context
file — `~/.claude/CLAUDE.md` for Claude Code, `~/.omp/agent/AGENTS.md` for omp,
`~/.pi/agent/AGENTS.md` for pi. Global hard rules live in those files and are **not** repeated
here. Keep this section in sync with the
slim installed version (it references the full protocol docs by path for on-demand reading,
never via `@import`).

## Persistent memory

This is your **active, vivid memory** — the persistence layer on this machine for who the
user is, the projects and concepts you work on together, and the decisions you've made. It is
an **outl** graph at `~/.llm-harness-memory` (via the `outl` MCP tools), it is **always loaded** (a
**SessionStart hook** injects the **index (TOC)** and a **recent-journal window** every
session), and it is the **first place you look**, not a reference archive you consult last.

**Memory-first, and memory is pushed to you.** Before acting on anything the user says —
before reaching for code, a file or directory search, or the web — check it against memory. A
`UserPromptSubmit` hook already surfaces memory relevant to the prompt as a **"Relevant memory
(auto-surfaced …)"** block of pointers; treat those as pointers, not content —
`outl_page_get` a slug before relying on it (which also credits its frecency). Absence of that
block does not mean memory is empty. For anything deeper than the injected index/journals,
**dispatch the `memory-recall` subagent** (Sonnet, read-only), which walks the graph in an
isolated context and returns the conclusion + `[[slugs]]` without loading page bodies into the
main thread. Reserve a direct `outl_page_get <slug>` for a quick single-slug read; never
brute-force the graph.

**Curate continuously.** Append durable decisions/discoveries to today's journal at each
checkpoint — don't wait for session end — and write impactful facts through to their knowledge
leaf. Retention is the **5 most recent journals**; distilling older ones into the knowledge
tree is **automatic** (hook + background agent) — never consolidate or delete journals by hand
unless a `⚠ CONSOLIDATION REQUIRED` fallback directive appears, then follow it.

Full protocol — graph model, crosslinking, writing, retrieval, condensation, frecency — is in
`~/.llm-harness-memory/AGENTS.md`. That doc is **not** loaded every session (context economy);
read it **only when doing memory maintenance**. The memory itself, though, is always live.
