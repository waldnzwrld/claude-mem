# User Global Instructions

## LSP tooling — always use the nvim MCP

Whenever LSP is involved — diagnostics, hover, go-to-definition, symbols,
references, or any "what does the language server say" question — use the **nvim
MCP** LSP tools against the user's live Neovim session:

- `mcp__nvim__vim_lsp_diagnostics`
- `mcp__nvim__vim_lsp_hover`
- `mcp__nvim__vim_lsp_symbols`

**Never** use Claude Code's built-in/internal LSP tool or any VS Code LSP
integration. The user has **no** language servers installed for Claude and does
**not** use VS Code; the only working LSP is the one running inside their Neovim
instance, reachable through the nvim MCP. If the nvim MCP LSP is unavailable,
say so — do not silently fall back to an internal LSP tool.

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
