---
name: memory-model
description: Show, list, or change the model that the persistent-memory background agents (journal writer, consolidation) run on in {{HARNESS_LABEL}}. Use when the user asks which model memory management uses, or wants to pick, change, or reset it.
---

# Memory model

The memory system runs headless agents in the background (the on-close journaler and the
journal/page consolidator). They use one model per harness, stored in
`~/.llm-harness-memory/.memory-models` and managed only through `memory-agent`. This skill is for
`{{HARNESS}}`; never edit the file by hand.

```bash
M=~/.local/bin/memory-agent
$M --harness {{HARNESS}} --get-model      # harness, effective model, source (default | MEMORY_MODEL | file)
$M --harness {{HARNESS}} --list-models    # models {{HARNESS}} can run, one selector per line
$M --harness {{HARNESS}} --set-model <m>  # store <m>; rejected if {{HARNESS}} does not list it
$M --harness {{HARNESS}} --unset-model    # back to the default
```

## Steps

1. Run `--get-model` and tell the user the current model and where it comes from. If the source
   is `MEMORY_MODEL`, that environment variable overrides the stored choice until it is unset.
2. If they only asked what it is, stop here.
3. Run `--list-models`. Show the choices, and ask which one to use; do not pick for them. The
   background agents do long tool-using runs, so say so if they choose a very small model.
4. Run `--set-model <their choice>`, then `--get-model` to confirm it took effect. It applies to
   the next background run; nothing needs a restart.
5. To go back to the default, run `--unset-model`.

## Notes

- Claude Code cannot list models: `--list-models` prints aliases (`sonnet`, `opus`, `haiku`), and
  any full Claude model ID is also accepted.
- A model is stored as given. For omp and pi a bare id (`claude-sonnet-5`) is accepted if it
  matches a listed `provider/id` selector, and it is stored bare, as omp/pi resolve it themselves.
