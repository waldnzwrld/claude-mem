# User Global Instructions

## Persistent memory

You have persistent, cross-session memory in an **outl** graph at `~/.claude/memory`,
reachable via the `outl` MCP tools. A **SessionStart hook** injects the current memory
**index (TOC)** and the most recent **journals** at the start of each session — so you are
always aware of past context without being told.

Work from the injected index, retrieve detail on demand (`outl_page_get <slug>` — never
brute-force the whole graph), record durable decisions/discoveries to today's journal as
you go, and run the daily→knowledge condensation when a `⚠ Consolidation due` flag appears.

Full protocol (crosslinking, writing, retrieval, condensation):

@/Users/waldnzwrld/.claude/memory/AGENTS.md
