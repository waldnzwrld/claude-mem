# User Global Instructions

## Hard rules (always on, every repo, every session)

- **Never state anything about a repo's git or working-tree state without first
  checking it in the current turn.** This covers every claim of the form "this
  isn't committed", "that was reverted", "the branch is clean/dirty", "there are
  uncommitted changes", "X is still on the branch", "nothing changed since", etc.
  Before making any such claim, run the relevant command (`git status`,
  `git diff`, `git log`, `git show`, `git stash list`, …) *this turn* and speak
  only from that fresh output. Remembered or inferred state from earlier in the
  conversation is not evidence — it goes stale the moment the user touches the
  tree. If you have not just checked, do not assert; check first, or say you
  need to check.

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

## Project CLAUDE.md protocol

Every project repo's CLAUDE.md files form a linked tree of TOC docs — the same
descend-on-demand, split-on-growth discipline as memory, but in plain markdown
(no outl), cataloged by business domain. Judge how much structure to impose from
the repo's own size & complexity (flat file → domain tree); the user does not
manage that. Read the root CLAUDE.md as an index, follow markdown links on
demand, keep each file small. Full protocol:

@/Users/waldnzwrld/.claude/project-claude-protocol.md
