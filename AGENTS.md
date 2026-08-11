# Persistent Memory Protocol

You (Claude) have persistent, cross-session memory. It lives in an **outl** outliner graph
at `~/.claude/memory` and is reachable through the `outl` MCP tools (also the `outl` CLI).
This document is the source of truth for how that memory works. It is imported by
`~/.claude/CLAUDE.md`, so it loads in every session automatically — you never need to be
told that you have memory.

## How memory reaches you

At the start of every session a **SessionStart hook** injects, as context:

1. The **`index` page** — a compact table of contents (the "MOC", map of content).
2. The **most recent journal(s)** — the last day or two of raw notes.
3. Occasionally a **`⚠ Consolidation due`** flag (see *Condensation* below).

So at the start of a session you already know the shape of memory. **Do not** re-read the
whole graph. Work from the injected index and pull detail on demand.

## Retrieving context (TOC-first — descend, don't dump)

Memory is a **tree of nested TOCs** (see *The graph model*). Answering a question is a walk
*down* that tree, following one `[[link]]` per hop — never a scan of the whole graph. The
point: each `outl_page_get` replaces the parent page in your working context, so descending
is nearly free — you only ever hold the path from the root to your target, not its siblings
or subtree.

1. Start from the injected `index`. Find the relevant `[[project / topic]]`.
2. `outl_page_get` that TOC. Read its one-line hooks; pick the child `[[link]]` that matches.
3. Descend — project TOC → area TOC → sub-area TOC → … — one link per hop, letting each
   read free the last.
4. **Stop at the first node that answers you.** Often a TOC hook is enough and you never
   open the leaf. Otherwise open the leaf document at the bottom.
5. Widen only if the tree fails you: `outl_search "<terms>"`, `outl_backlinks <slug>`,
   `outl_query`.

Example: "how does projectx handle payments?" → `index` → `[[project-x]]` (hook points at
frontend) → `[[project-x-frontend]]` → `[[project-x-frontend-payments]]` → the answer. Five
small reads, the whole graph never loaded.

## The graph model — a tree of TOCs

Memory is a **tree of nested TOCs (MOCs) with real documents at the leaves**. Every node is
small; you descend by following `[[links]]`, and every hop frees the parent's context.
Depth is not fixed — add a level whenever one gets crowded.

- **L0 `index`** (`type:: moc`) — the always-injected top TOC: projects + recent
  cross-cutting topics, grouped under `## Projects`, `## Cross-cutting knowledge`,
  `## Recent journals`. One `[[link]]` + one-line hook each.
- **Project / topic TOC** (`type:: moc`, slug `project-<name>` or `<topic>`) — lists that
  project's areas as `[[links]]` with hooks. Props `status::`, `updated::`, `summary::`.
- **Area / sub-area TOCs** (`type:: moc`, slug `<parent>-<area>`, prop `parent:: [[<parent>]]`)
  — nest as deep as the material needs; each just links its children with hooks. Add
  another level whenever a TOC's link list gets long.
- **Leaf documents** (`type:: knowledge`, `parent:: [[<toc>]]`) — the actual subject matter.
  Props `project::`, `updated::`, `summary::`, `tags::`, plus frecency `frecency::` (int) /
  `seen::` (date). `pin:: true` protects a foundational leaf from pruning.
- **Journals** — one per day, slug `YYYY-MM-DD`. Five fixed sections, in this order:
  `## Focus`, `## Key Decisions`, `## Discoveries`, `## Action Items`, `## Session Notes` —
  laid down **once** by the `journal` template (see `templates-journal`), then appended to
  *under* the matching section. There is exactly one of each section per day; never create a
  second copy. Raw and short-lived; distilled into the tree by condensation. The per-section
  contract and quality bar live in *Writing to memory*.

Two rules keep the tree lean:

- **Split on growth.** When a leaf grows past roughly **150 lines / ~1500 words** — the
  point where reading it would eat a big slice of context — convert it into a TOC: extract
  its sections into child leaf documents (`<slug>-<section>`), and leave one-line `[[links]]`
  + hooks behind. Detail moves down a level; the parent stays scannable. Better to traverse
  three tiny pages than load one huge one.
- **TOCs live with their children.** A TOC is structural — effectively pinned while it holds
  ≥1 live child, and not itself frecency-decayed. When pruning removes its last child,
  delete the now-empty TOC and its link in the parent too.

## Crosslinking conventions

Crosslinks are what make this a graph instead of a pile of files. Use them liberally.

- `[[page-slug]]` — reference any project or knowledge page. outl auto-creates the page on
  first mention, so linking a not-yet-existing topic is fine; it marks intent.
- **Journals always link outward.** Every substantive journal item should link the
  `[[project-...]]` or `[[topic]]` it concerns. Those backlinks are how condensation later
  finds what to distill and where.
- **Knowledge pages link back** to their project via the `project::` property and to
  related pages via `[[...]]` in the body.
- `#tag` — cross-cutting themes that span projects (`#security`, `#decision`, `#gotcha`).
- `((block-id))` — block reference/embed; use only to quote one specific decision across
  pages, not for ordinary links.

## What long-term memory is for (the signal filter)

Memory is not a mirror of the codebase — it is the layer of context that **cannot be
reconstructed from the repos themselves**. Every repo already carries its own `CLAUDE.md` /
`DEVELOPMENT.md` / `README`, its git history, and its source. Duplicating any of that into a
knowledge leaf is waste: it goes stale, it bloats the graph, and the repo was the source of
truth anyway. Before writing or distilling anything, apply one test:

> **Could I reconstruct this by opening the repo (code, git log, `CLAUDE.md`)?** If yes,
> *link to where it lives* instead of copying it. Only store what the repo can't tell you.

**Keep — the durable, cross-cutting, hard-to-reconstruct:**

- **Relationships between repos/systems** — deployment and dependency edges, who builds vs.
  who deploys, how two projects interact. (E.g. [[project-cloud-native]] builds the images
  that [[project-selfhosted-helm]] deploys; [[project-claudio-scheduled-tasks]] acts on the
  cloud-native monorepo baked at `/opt/cloud-native`.) This lives in no single repo.
- **Where we are in a long-running effort** — which area of which codebase we're working in
  day by day, the state of a multi-session workstream, what's done and what's next.
- **Decisions about an overarching plan and their *why*** — architectural direction, the
  long-term trade-off chosen and the constraint that forced it.
- **Non-obvious gotchas** that cost real time to rediscover and are written down *nowhere*
  (not in any `CLAUDE.md` or code comment).
- **Durable facts about the user** and their working preferences.

**Drop — reconstructable or trivial; do not store in long-term leaves:**

- Anything already in a repo's `CLAUDE.md` / `DEVELOPMENT.md` / `README` — **link to it,
  never replicate it.**
- Recent commits / git-log summaries — git history already has these.
- What an individual function, file, or module does — the code is the source of truth.
- Any transient mechanic that a glance at the current repo would re-establish.

The contrast in one line: *remembering recent commits is useless (git has them); remembering
where we are in a long-running project is exactly the point.* Journals may capture more in
the moment (they're raw and short-lived), but only signal that passes this filter should
survive **condensation** into a permanent leaf.

## Writing to memory (continuously)

Append to **today's journal** at natural checkpoints — after a decision is made, something
non-obvious is discovered, a new durable fact about the user or a project surfaces, or an
open thread is opened/closed. Don't wait for the end of the session.

**Scaffold once, then append *under* sections — never restack them.** The daily page has
five fixed sections in a fixed order (below). The **first** time you write on a new day, lay
them down with `outl_template_apply name:journal page:<today>`. Every later write **appends
its item as a child under the matching existing `## Section`** — target that section's block
id with `outl_block_append` / `outl_block_append_tree`. **Never emit a `## Section` header
that already exists.** If you catch yourself adding a second `## Focus` (or any other
section), stop and append under the existing one. This single rule is what stops a day from
sprouting five `## Focus` and three `## Discoveries` blocks.

The five sections and what each holds:

- **`## Focus`** — the day's table of contents: **one bullet per distinct work-stream**
  (not one per checkpoint), each naming its subject as `[[project-...]]` + a short phrase.
- **`## Key Decisions`** — durable choices. Each bullet leads with the decision, then the
  *why* (the reasoning or constraint that forced it).
- **`## Discoveries`** — non-obvious facts learned: gotchas, how something actually works.
- **`## Action Items`** — checkbox todos, `- [ ]` open / `- [x]` done. Concrete next steps.
- **`## Session Notes`** — brief free-form catch-all for what doesn't fit above. Not the
  main channel; keep it short.

**Quality bar — every bullet must:**

- **Name its subject explicitly.** Never write "this repo", "the project", "the branch",
  "the git log" bare — say *which*: `[[project-cloud-native]]`, `carto-selfhosted-helm`,
  `feat/report-payload-shipping`. A note that doesn't identify its subject is worthless read
  cold months later.
- **Link outward** with `[[project-...]]` / `[[topic]]` so condensation can find and route
  it.
- Carry **one durable fact** — a decision + its why, a discovery, a user preference, project
  state. Write signal, not transcript, and apply *What long-term memory is for* above: if the
  repo, its git log, or its `CLAUDE.md` already holds it, link to that instead of copying it.

A `PreCompact` hook will remind you to flush anything unsaved before the context is
compacted — treat that as a cue to write pending notes to the journal.

## Condensation (daily → knowledge rollup)

**Retention window = today + the previous 4 days** (5 raw journals). Journals older than
that are distilled into permanent knowledge pages, then deleted — the distilled version
lives on.

**Trigger:** the SessionStart hook flags `⚠ Consolidation due (first session of a new day)
for: <dates>` on the first session of a new day, listing each journal that has aged out of
the window (date ≤ D‑5). Deletion is unconditional — there is no `consolidated::` guard and
no safety net; the raw journal is burned once distilled. When you see the flag, run the
rollup before other work:

For each flagged journal date:

1. `outl_daily_get <date>` — read the raw journal.
2. Cluster its items by the `[[linked page]]` / topic they concern.
3. For each cluster with lasting value — judged by *What long-term memory is for* (keep
   cross-repo relationships, plan state, decisions + why; drop anything the repo/git/`CLAUDE.md`
   already holds) — descend the tree to the target leaf document (an
   existing one, or create a new leaf under the right TOC — splitting or adding a TOC level
   if a parent is getting crowded). Merge the **distilled** points in — synthesize, don't
   copy verbatim. Set/refresh `updated::` and `summary::`; ensure `project:: [[...]]`,
   `parent:: [[<toc>]]`, and back-links are present. Touch its frecency (a new leaf seeds
   `frecency:: 30`; merging into an existing one is a use → `+5`, cap 60); set
   `seen:: <today>`.
4. If you created a new leaf or TOC, add its one-line `[[link]]` + hook to the parent TOC
   (and the parent to `index` if it's a new top-level project/topic).
5. `outl_page_delete <date> confirm:true` — burn the raw journal now that it's distilled.
   (If a journal held nothing worth keeping, delete it without creating a page.)

Then run the **frecency sweep** (see below) over all leaf documents.

Finally, refresh `index`: bump its `updated::` and trim the `## Recent journals` list to the
current window.

## Frecency & pruning

Leaf documents that stop earning their place are dropped, so the tree of TOCs never
accretes dead pages. Frecency = frequency + recency, kept integer-simple (no exponentials)
so it is maintainable by hand, and scaled to a **~1-month** window — long enough that
real-but-occasional knowledge survives, short enough that stale detail clears out.

- **Only leaf documents** (`type:: knowledge`) carry and decay frecency. **TOCs are not
  decayed** — they live while they hold ≥1 live child (see *The graph model*).
- Each leaf carries `frecency::` (integer, seed **30**, cap **60**) and `seen::` (last date
  the score changed).
- **On material use** — whenever you open a leaf to *use* its content, or merge into it
  during condensation (not a passing glance) — bump `frecency` by **+5** (cap 60) and set
  `seen:: <today>`.
- **Daily sweep** (part of the consolidation pass, once per new day): every non-pinned leaf
  whose `seen::` is not today gets `frecency − 1`; set its `seen:: <today>` so it decays at
  most once per day. Any leaf reaching `0` is pruned: `outl_page_delete <slug> confirm:true`,
  remove its link from the parent TOC, and delete the parent TOC too if that was its last
  child.
- `pin:: true` exempts a foundational leaf (project-critical or identity knowledge) from
  decay and pruning entirely.
- Optional: order each TOC's link list by `frecency` (high → low) so the most-used
  pathways surface first.

Scale: a fresh leaf (seed 30) survives ~30 idle days; each use adds ~5 days; a
heavily-used leaf rides at the 60-day cap. Deletion here is intentional and unrecoverable,
exactly like journal burning.

## Research references (external live docs)

Research the user commissions is written as markdown to `~/Code/research/*.md` — **outside**
the graph. Those files are the source of truth and must never be copied into or symlinked
under `pages/` (a raw file has no `.outl` sidecar and no frontmatter, so it isn't a real
node, and the pruning sweep — `outl_page_delete` — could destroy it). Link them via a
**reference stub**: a third node kind alongside `moc` and `knowledge`.

- **Kind.** `type:: reference`, slug `research-<topic>`. Props: `source:: <absolute path to
  the ~/Code/research/*.md file>`, `status:: active | complete`, `parent:: [[research]]`,
  `summary::`, `updated::`. **No `frecency::` / `seen::` pair** — like a TOC, it is exempt
  from the daily frecency sweep by construction (the sweep only decays `type:: knowledge`
  leaves). Its lifecycle is governed by `status::`, not by access frequency.
- **Pointer, not copy.** The stub stores the *path*, never the content, so it is always
  current — to read the research, open `source::` directly. Body = one-line hook + `[[...]]`
  links to the projects/topics it concerns + a "Live file: `<source>`" pointer line.
- **Linking.** Hang stubs under a top-level `[[research]]` TOC (`type:: moc`, linked from
  `index`); **create that TOC lazily** the first time a research subject is linked, not
  before. Journal items that touch a research subject link `[[research-<topic>]]`, exactly
  like any other outward journal link.
- **On completion** (`status:: complete`): **delete the stub** — `outl_page_delete
  research-<topic> confirm:true`, remove its link from the `[[research]]` TOC, and delete
  the now-empty TOC (and its `index` link) if that was its last child. The `~/Code/research`
  file is left untouched; it is its own archive. Nothing is condensed into a `knowledge`
  leaf.

## Maintenance invariants

- **Every node is reachable from `index` by following links** — no orphans. Each TOC links
  its children with a one-line hook; each leaf sets `parent:: [[<toc>]]`. The
  `## Recent journals` list reflects the retention window.
- Every TOC carries `type:: moc`; every leaf carries `type:: knowledge`, `project::`,
  `parent::`, `updated::`, `summary::`, and the frecency pair `frecency::` / `seen::`
  (foundational leaves add `pin:: true`). Reference stubs carry `type:: reference` +
  `source::` + `status::` and deliberately omit the frecency pair (see *Research
  references*).
- **Keep every page small.** If a leaf pushes ~150 lines, split it into a TOC + child
  leaves (see *The graph model*). A page that would eat a big slice of context on read is a
  bug — traversing tiny pages is the whole point.
- Prefer editing an existing leaf over creating a near-duplicate; descend the tree or
  `outl_search` first. Editing an existing leaf also refreshes its frecency — another
  reason to merge rather than fork.
- The workspace holds only outl's own dirs — `pages/`, `journals/`, `ops/`, `assets/`,
  `.outl/`. Never create parallel `knowledge/`, `daily/`, or `templates/` dirs; every TOC,
  leaf, and the journal template all live as pages in `pages/`.

## outl tool cheat-sheet

- Read: `outl_page_get` / `outl_page_render`, `outl_daily_today` / `outl_daily_get` /
  `outl_daily_range`, `outl_search`, `outl_backlinks`, `outl_query`, `outl_page_list`.
- Write: `outl_page_create` (accepts a `content` forest), `outl_block_append` /
  `outl_block_append_tree`, `outl_block_update`, `outl_daily_append`,
  `outl_page_prop_set`, `outl_page_delete` (needs `confirm:true`),
  `outl_template_apply` (name `journal`).
- Health: `outl_workspace_info`, `outl_workspace_doctor`.
