# Third-party dependencies

`llm-harness-memory` is licensed under the [MIT License](LICENSE). It relies on external tools at
runtime that it **does not bundle, vendor, or redistribute** — you install them yourself.
This file records those dependencies and their licenses.

Because this repository ships **no source or binaries** of the tools below, their own
license notices are not triggered by distributing this repository. If you later change that
— vendoring a dependency's source, shipping its binary, or baking it into a container or
release archive — you must include that dependency's own license file (its copyright line
and permission notice) alongside your distribution.

## outl

- **License:** MIT
- **Upstream:** https://github.com/outlmd/outl
- **How it's used:** installed separately by the user (e.g. `brew install outl-beta`, or via
  Cargo/git) and invoked at arm's length — as a CLI subprocess and as a separate MCP server
  process. No outl source or binary is included in this repository.
- **Obligation here:** none, because outl is not redistributed. To honor MIT if you ever
  bundle outl, copy its upstream `LICENSE` (copyright notice + MIT permission text) into your
  distribution next to this project's `LICENSE`.

## Agent harnesses

At least one supported harness is required at runtime. None is bundled; each is invoked at
arm's length — its hooks/extension run `memory-hook` as a subprocess, and
`memory-agent` launches the harness CLI headless for the background agents.

### Claude Code / Anthropic Claude

- **License:** proprietary (Anthropic) — separate product, not open-source and not
  redistributed here.
- **How it's used:** native shell hooks in `~/.claude/settings.json` run the memory hook;
  background agents run as `claude -p`.

### omp (oh-my-pi)

- **License:** MIT
- **Upstream:** https://github.com/can1357/oh-my-pi
- **How it's used:** the adapter extension `omp/llm-harness-memory.ts` (this repo's own source)
  is loaded by omp and imports omp's extension types from `@oh-my-pi/pi-coding-agent`;
  background agents run as `omp -p`. No omp source or binary is included in this repository.

### pi

- **License:** MIT
- **Upstream:** https://github.com/earendil-works/pi
- **How it's used:** the adapter extension `pi/llm-harness-memory.ts` (this repo's own source)
  is loaded by pi and imports pi's extension types from `@earendil-works/pi-coding-agent`;
  background agents run as `pi -p`. No pi source or binary is included in this repository.

## Python standard library

- `memory-index` and the hook use only the Python 3.9+ standard library (`sqlite3`/FTS5,
  etc.). **No third-party Python packages** are required or vendored.
