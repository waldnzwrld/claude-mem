# tests — reusable functional verification

A built-once, run-anywhere test set for the memory system. There are **two** runners over one
committed fixture workspace; both copy the fixture into a throwaway dir **per scenario**, so
the fixture is never mutated and nothing touches live memory.

- **`verify.sh`** — fast, deterministic. Drives `memory-index` directly (no LLM) and asserts
  the mechanical outcomes.
- **`verify-agent.sh`** — the agent-in-the-loop proof. Points a **real running Claude agent**
  at the fixture (real outl MCP, real PostToolUse hook, real `claude -p` consolidation agent)
  and asserts the end-to-end runtime behaves as expected. Slower; consumes model quota.

## Run

```bash
tests/verify.sh                                 # mechanical layer (this branch's ./memory-index)
tests/verify-agent.sh                           # agent-in-the-loop proof (launches Claude)
SKIP_CONSOLIDATION=1 tests/verify-agent.sh      # only the cheap propagation scenario
MI=~/.local/bin/memory-index tests/verify.sh    # test the installed binary instead
```

Exit status is non-zero if any assertion fails. Reuse on every branch as we work.

## How the agent runner isolates live memory

`verify-agent.sh` launches `claude -p` (and the `memory-consolidate` distiller) with:
`--mcp-config` pointing the **outl MCP at the throwaway workspace**, `--strict-mcp-config` so
no other MCP loads, `--settings` wiring the repo's PostToolUse hook, and `MEMORY_WS=<copy>`
so every hook/script targets the copy. The scripts gained a `MEMORY_WS` override for exactly
this (and `memory-consolidate` now scopes its distiller's outl MCP to the workspace it manages).

## What it covers

| # | Scenario | Proves |
|---|----------|--------|
| 1 | graph sanity | rebuild + `part-of` edges |
| 2 | touch propagation | credit flows leaf → parent moc → root index |
| 3 | leaf eviction | frecency 0 soft-trashes the leaf; inbound `[[refs]]` scrubbed (TOC bullet deleted, inline ref rewritten); parent survives |
| 4 | moc cascade | a page-with-children at 0 takes its whole subtree; unrelated tree survives |
| 5 | block eviction | a line whose block-frecency hit 0 is removed; the file lives |
| 6 | pin decay | `pin:: true` is **not** exempt — it evicts at 0 |
| 7 | split detection | oversized leaf flagged as a split candidate |
| 8 | consolidation reap | a journal marked `consolidated::` is reaped; pending backlog detected |
| 9 | healthy baseline | a hot graph evicts nothing |

### `verify-agent.sh` (agent-in-the-loop)

| # | Scenario | Proves |
|---|----------|--------|
| 1 | live agent recall | a real agent calling `outl_page_get` fires the PostToolUse hook → `touch` → frecency propagates leaf → moc → root |
| 2 | consolidation agent | a real `claude -p` distiller consumes the one pending journal, writes it into a knowledge leaf, marks it `consolidated::`, and it is reaped |

## Fixture

`fixture/` is a small deterministic outl workspace (built by `build-fixture.sh`). Block ids
are outl ULIDs and therefore non-deterministic, so the fixture pins **structure**; `verify.sh`
discovers ids at run time. The derived index (`.outl/index.sqlite`) and section ledger
(`.frecency/`) are gitignored — `verify.sh` rebuilds them on its copy.

Rebuild or extend the fixture with:

```bash
tests/build-fixture.sh
```

Requires the `outl` binary (`OUTL_BIN` to override) and Python 3.
