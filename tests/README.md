# tests — reusable functional verification

A built-once, run-anywhere test set for the memory system. There are **two** runners over one
committed fixture workspace; both copy the fixture into a throwaway dir **per scenario**, so
the fixture is never mutated and nothing touches live memory.

- **`verify.sh`** — fast, deterministic. Drives `memory-index` directly (no LLM) and asserts
  the mechanical outcomes.
- **`verify-model.sh`** — memory-model selection. Offline: the harness CLIs are stubs. Covers
  `memory-agent`'s `--list/get/set/unset/check-model`, precedence (`MEMORY_MODEL`, stored line,
  default), the command line each harness gets, the hint after a failed run, and
  `install.sh`/`uninstall.sh` (`--model`, `--no-prompt`, the prompt through a pty, skills,
  nothing-installed-on-error).
- **`verify-agent.sh`** — the agent-in-the-loop proof. Points a **real running agent** at the
  fixture (real outl MCP, real PostToolUse hook, real headless consolidation agent) and asserts
  the end-to-end runtime behaves as expected. `HARNESS=claude` (default), `HARNESS=omp`, or
  `HARNESS=pi`.
  Slower; consumes model quota.

## Run

```bash
tests/verify.sh                                 # mechanical layer (this branch's ./memory-index)
tests/verify-model.sh                           # memory-model selection (offline, stub CLIs)
tests/verify-agent.sh                           # agent-in-the-loop proof (launches Claude)
HARNESS=omp tests/verify-agent.sh               # same proof through omp + omp/llm-harness-memory.ts
HARNESS=pi tests/verify-agent.sh                # same proof through pi + pi/llm-harness-memory.ts
SKIP_CONSOLIDATION=1 tests/verify-agent.sh      # only the cheap propagation scenario
MI=~/.local/bin/memory-index tests/verify.sh    # test the installed binary instead
```

Exit status is non-zero if any assertion fails. Reuse on every branch as we work.

## How the agent runner isolates live memory

With `HARNESS=claude`, `verify-agent.sh` launches `claude -p` with `--mcp-config` pointing the
**outl MCP at the throwaway workspace**, `--strict-mcp-config` so no other MCP loads, and
`--settings` wiring the repo's PostToolUse hook. With `HARNESS=omp`, it launches `omp -p` in a
scratch project whose `.omp/mcp.json` points outl at the copy, loading only the repo's
`omp/llm-harness-memory.ts` (`--no-extensions -e`). With `HARNESS=pi`, it points
`PI_CODING_AGENT_DIR` at a throwaway agent dir holding only your `auth.json`, `models.json`, and
`settings.json` (minus `packages`), so no installed extension or user MCP server loads;
`--no-extensions` can't be used, since it also disables pi's MCP support. It then launches
`pi -p` in a scratch project whose `.pi/mcp.json` (trusted by `--approve`) points outl at the
copy with `direct` exposure, adding the repo's `pi/llm-harness-memory.ts` with `-e`. pi uses its
own default
model unless `MEMORY_MODEL` is set. Every way, `MEMORY_WS=<copy>` makes every hook/script target
the copy, and `memory-consolidate` and `memory-dump` scope their agent's outl MCP to the
workspace they manage (`memory-agent --ws`).

## What it covers

| # | Scenario | Proves |
|---|----------|--------|
| 1 | graph sanity | rebuild + `part-of` edges |
| 2 | touch propagation | credit flows leaf → parent moc → root index |
| 3 | leaf eviction | frecency 0 soft-trashes the leaf; inbound `[[refs]]` unlinked (TOC bullet deleted, inline ref rewritten to its plain slug); parent survives |
| 4 | moc cascade | a page-with-children at 0 takes its whole subtree; unrelated tree survives |
| 5 | block eviction | a line whose block-frecency hit 0 is removed; the file lives |
| 6 | pin decay | `pin:: true` is **not** exempt — it evicts at 0 |
| 7 | split detection | oversized leaf flagged as a split candidate |
| 8 | consolidation reap | a journal marked `consolidated::` is reaped; pending backlog detected |
| 9 | healthy baseline | a hot graph evicts nothing |
| 10 | body-bullet props | `summary::`/`updated::` written as body bullets are indexed |
| 11 | prose never steers | "under [[x]]" / "replaces [[x]]" wording neither cascades an eviction nor marks a page superseded; only authored `parent::`/`supersedes::` do |
| 12 | stale hierarchy | a re-parent made since the last index refresh is honoured by `maintain` |

### `verify-agent.sh` (agent-in-the-loop)

| # | Scenario | Proves |
|---|----------|--------|
| 1 | live agent recall | a real agent calling `outl_page_get` fires the PostToolUse hook → `touch` → frecency propagates leaf → moc → root |
| 2 | consolidation agent | a real headless distiller (`claude -p` / `omp -p` / `pi -p`) consumes the one pending journal, writes it into a knowledge leaf, marks it `consolidated::`, and it is reaped |

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
