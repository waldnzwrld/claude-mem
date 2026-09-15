# Persistent Memory Protocol

You (Claude) have persistent, cross-session memory. It lives in an **outl** outliner graph
at `~/.claude/memory` and is reachable through the `outl` MCP tools (also the `outl` CLI).
It is your **active, vivid persistence layer** — always loaded, and the **first place you
look** before reaching for code, a file/dir search, or the web, not a reference archive you
consult last. Keep it curated continuously, not just at maintenance time.
This document is the source of truth for how that memory works. `~/.claude/CLAUDE.md` points
at it and the SessionStart hook injects the live memory state every session, so you never
need to be told that you have memory — but this full protocol is **not** loaded every
session; read it only when doing memory maintenance.

## How memory reaches you

At the start of every session a **SessionStart hook** injects, as context:

1. The **`index` page** — a compact table of contents (the "MOC", map of content).
2. **Today's journal in full**, plus the **`## Focus` digest** of the previous up-to-4 dated
   journals (each prior day contributes only its day's-work TOC — pull a full prior journal
   with `outl_daily_get <date>` when a digest line points somewhere you need).
3. Occasionally a **`⚠ Consolidation due`** flag (see *Condensation* below).

Beyond the session-start injection, a **`UserPromptSubmit` hook pushes retrieval per prompt**:
it runs the index against the user's prompt and, on a strong hit, injects a **"Relevant memory
(auto-surfaced …)"** block of `slug › heading` pointers *before you act* (see *Retrieval
regime auto-scales*). Those are pointers, not content — `outl_page_get` a slug to confirm.

So at the start of a session you already know the shape of memory. **Do not** re-read the
whole graph. Work from the injected index and pull detail on demand.

## Retrieving context (TOC-first — descend, don't dump)

**For any lookup deeper than a quick single-slug read, prefer delegating to the
`memory-recall` subagent** (Sonnet, read-only outl tools). It performs the walk below in an
isolated context and returns the conclusion + `[[slugs]]`, so the bulky page bodies never
enter the main thread. A page it fetches still credits frecency (the `PostToolUse` touch hook
fires inside subagents too). Reserve a direct `outl_page_get` on the main thread for a quick
single-slug read. The protocol below is what that agent — or you, for that quick read — follows.

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

**Retrieved bodies are disposable — keep the conclusion + the slug, not the page.** A page
you `outl_page_get` is a re-fetchable projection of the graph, not something to hold onto.
Once you have used it, carry forward only (a) the conclusion you drew and (b) its `[[slug]]`,
and let the raw body fall out of context. Compaction summarizes tool results away wholesale —
there is no selective tool-result retention in the harness — so a lingering page body is pure
cost with no payoff: if you need the detail again, re-fetch by slug (the FTS/graph walk costs
zero model tokens — see [[memory-retrieval-index]]). The durable residue of any retrieval is
tiny, which is exactly what keeps an MCP-heavy session from bloating.

## Retrieval regime auto-scales to graph size (the index)

The TOC-descent above is the retrieval mechanism for a **small** graph — cheap when there
are tens of nodes. Past a threshold (default **150 nodes**) descent stops being free: you
don't know which `[[link]]` name holds the answer, and `outl_search` is keyword-only, so it
misses paraphrase (a query for "money stuff" never finds `[[payments-hands-off]]`). At that
scale a **derived retrieval index** — the `memory-index` sidecar — front-runs the descent.
You never choose the regime; it's gated on node count.

- **`memory-index` is a rebuildable derivative, never a source of truth.** It's a single
  SQLite file at `.outl/index.sqlite` — an FTS5 keyword index plus a **typed, weighted
  `[[link]]` edge table** (nodes = pages, edges = links) — built with the Python standard
  library only: no third-party packages, no venv, no build step, so it just works on any
  machine that has Python. Delete it and `memory-index rebuild` reconstructs it from the
  markdown. The markdown graph remains the only authority.
- **Edges carry a typed relationship, authored or inferred.** Each edge has a `type` (`refs`
  by default, or `supersedes` / `contradicts` / `part-of`) and a `weight` (link multiplicity),
  and exactly one edge is kept per src→dst (the highest-precedence type). Typing has two
  sources, **authored beating inferred**:
  - **Authored (authoritative):** a frontmatter prop that names the relationship, its value one
    or more `[[slug]]` links — `supersedes:: [[old-note]]`, `contradicts:: [[other]]`,
    `parent:: [[toc]]` (→ `part-of`). State the type here when you mean it; the keyword guess
    never overrides it. Prefer this for any real supersede/contradict relation.
  - **Inferred (fallback):** a bare inline `[[link]]` takes its type from the wording of its
    line (line-granular — every link on a line is tagged alike), else `refs`.
- **Type steers the walk, it isn't just a label.** A page that something `supersedes` is stale,
  so association never surfaces it — the graph walk skips superseded targets. (The opt-in
  `medic --prune-superseded` heal additionally drops plain refs into them.) You do nothing to
  produce edges beyond authoring links/props; a schema bump self-heals on the next read.
- **The SessionStart hook injects whether the index is ACTIVE.** When it is, retrieve like
  this: run **`memory-index search "<query terms>"`** *first* to land directly on the narrow
  relevant band — keyword (FTS5/bm25) ranking that returns `slug › heading` pointers, **then**
  a graph walk out from those hits along the typed edges (nearest- and strongest-first,
  labelled `via <node> · <type> · <N>h ·w<weight>`) — **then** `outl_page_get` the one or two
  slugs it names to read full detail. Search replaces steps 1–4's blind descent; you still
  expand via the graph. (Matching is keyword, not semantic: prefer the subject's own terms,
  and fall back to TOC descent when a paraphrase misses.)
- **Hop depth is a function of graph size**, gated on node count like the ACTIVE/inactive
  regime: the recursive traversal walks 1 hop below 3× the active threshold, 2 at 3×, 3 at 10×.
  `memory-index stats` shows the edge-type breakdown for the current graph.
- **When the index is inactive** (small graph, or the hook says so), use the TOC-descent
  above unchanged. It is also the **universal fallback** whenever the index is stale or
  `memory-index` is unavailable — the system always works without it.
- **Push-retrieval — memory relevant to a prompt is surfaced for you.** A
  `UserPromptSubmit` hook runs the index against the user's prompt *before* you see it and
  injects a **"Relevant memory (auto-surfaced …)"** block of `slug › heading` pointers when
  a hit is strong (conservative bm25 gate, ≤3 pointers, once per slug per session; a
  trivial/off-topic prompt surfaces nothing). Treat those lines as **pointers, not
  content** — `outl_page_get` a slug before relying on it (that fetch also credits its
  frecency). This complements, and never replaces, your own `memory-index search`: absence
  of a surfaced block does not mean memory is empty — search or descend when the task needs it.
- Writing is unchanged: you still author markdown/journals normally. The hook keeps the
  index fresh (`memory-index refresh`, incremental by page hash) with no action from you.

## MCP call discipline

A few rules keep MCP usage cheap, for both the interactive session and subagents:

- **Read with `outl_page_render` (or export-md) for recall, not `outl_page_get`.**
  `page_get`'s JSON return is ~2.5–3× the tokens of the rendered markdown. Reserve
  `outl_page_get` for the moment you're about to *write* — you need its block ids to target an
  append.
- **Batch writes into one call.** Prefer `outl_batch`, `outl_page_create` with a `content`
  forest, or `outl_block_append_tree` over a string of individual `outl_block_append` calls —
  one per bullet burns one model turn each. This still has to respect journal-append
  discipline (append under the existing section block id; never emit a duplicate `## Section`
  header — see *Writing to memory*).
- **Navigate to locate, then one render to read.** Use `outl_query` / `outl_search` /
  `outl_backlinks` to find the right slug, then a single `outl_page_render` — not a sweep of
  `outl_page_get` calls across candidates.
- **Don't re-fetch what's already in context.** Don't `outl_page_get` a page already
  fetched/rendered this session. Dispatch `memory-recall` only when the answer is genuinely
  deeper than the injected index/journals — not for something you already hold.

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
  Props `project::`, `updated::`, `summary::`, `tags::`, plus the frecency pair `frecency::`
  (int) / `seen::` (date) that **every** page now carries — leaves and TOCs alike (see
  *Frecency & pruning*). There is no `pin::` exemption.
- **Journals** — one per day, slug `YYYY-MM-DD`. Five fixed sections, in this order:
  `## Focus`, `## Key Decisions`, `## Discoveries`, `## Action Items`, `## Session Notes` —
  laid down **once** by the `journal` template (see `templates-journal`), then appended to
  *under* the matching section. There is exactly one of each section per day; never create a
  second copy. Raw and short-lived; distilled into the tree by condensation. The per-section
  contract and quality bar live in *Writing to memory*.

Two rules keep the tree lean:

- **Split on growth.** When **any page's** body exceeds the load-cost budget — **~1800
  estimated tokens** (`MEMORY_SPLIT_TOKENS`, measured as the `.md` projection's chars/4, i.e.
  what an `outl_page_get` actually spends; ≈150 lines / ~1500 words as a rough human gauge) —
  it is split so no single page is expensive to load. A content **leaf** becomes a TOC: its
  sections move into child leaves (`<slug>-<section>`), one-line `[[links]]` + hooks left
  behind. An overgrown **TOC/hub** becomes a thin index of **sub-TOCs**: its entries are
  grouped into sub-TOCs (`<slug>-<group>`) and only their one-line `[[link]]` + hook stays in
  the parent. Either way detail moves down a level and the parent stays scannable — better to
  traverse a few tiny pages than load one huge one. This is **automatic**: the daily
  `memory-index maintain` sweep flags any page over budget (leaf or hub), and the SessionStart
  hook hands them to the headless `memory-consolidate` compaction agent (which also distils
  journals and prunes dead lines, leaves, and TOCs) — it carves them with no prompting. A `⚠
  Split-on-growth candidates` directive is only the fallback for when the agent CLI is
  unavailable.
- **TOCs live with their children — via frecency, not exemption.** A TOC now carries and
  decays frecency like any page, but every use of a descendant propagates credit *up* the
  `parent::` chain (see *Frecency & pruning*), so a TOC stays warm as long as anything beneath
  it is used and only ages to 0 once its whole subtree is cold — at which point `maintain`
  trashes the TOC together with its subtree. You no longer prune empty TOCs by hand.

## Crosslinking conventions

Crosslinks are what make this a graph instead of a pile of files. Use them liberally.

- `[[page-slug]]` — reference any project or knowledge page. outl auto-creates the page on
  first mention, so linking a not-yet-existing topic is fine; it marks intent.
- **Journals always link outward.** Every substantive journal item should link the
  `[[project-...]]` or `[[topic]]` it concerns. Those backlinks are how condensation later
  finds what to distill and where.
- **Knowledge pages link back** to their project via the `project::` property and to
  related pages via `[[...]]` in the body.
- `#tag` — cross-cutting themes that span projects (`#security`, `#decision`, `#gotcha`). See
  *Tag layer* below for the controlled vocabulary and the PR/issue-number rule.
- `((block-id))` — block reference/embed; use only to quote one specific decision across
  pages, not for ordinary links.

## Tag layer

`[[Link]]` and `#tag` are not interchangeable. `[[Link]]` is the sole **structural**,
frecency-bearing citizen — a directed edge the retrieval graph walks (parent chains, credit
propagation, backlinks all ride on it). `#Tag` is a flat, many-to-many **facet**: it labels the
containing page's subtree, classifying it rather than pointing anywhere. A tag is not an edge
and does not carry or propagate frecency.

**Controlled, numeric-free vocabulary.** Two families only:

- `#topic/<x>` — topical facets, many per page, cross-cutting the tree (a retrieval-expansion
  surface for `memory-index search`, not a substitute for `[[link]]`ing the owning TOC).
- `#status/<x>`, plus the lifecycle tags `#active`, `#in-deep`, `#stale` — state and
  maintenance markers.

Everything else — and especially a bare number — is off-vocabulary.

**Never write a bare `#272` in memory.** `outl` turns any `#token` into a tag — including
`#272`, `PR#273`, or one written inside backticks or with a backslash escape — which pollutes
the tag index with one-off numeric tags. Neither backticks nor a backslash prevents this; only
dropping the leading `#` before the digits does. Write a PR/issue reference instead as a
markdown link, `[#272](https://github.com/owner/repo/pull/272)` (keeps the `#272` glyph, links
to GitHub, creates no tag), or plainly as `PR 272`.

**Standard migration.** These conventions apply retroactively: when the standard advances,
`memory-index normalize` brings the existing graph up to it (versioned by a `.standard-version`
marker, so it is idempotent and a no-op once current). `install.sh` runs it automatically after
taking an `outl backup`. The first migration smart-strips PR/issue `#`-number tags (drop the
`#`, prefix `PR` only when not already labeled); `memory-index doctor` reports any that remain
under `tag-noise`. `normalize` skips a block `outl` refuses to rewrite (e.g. a journal whose
`.md` is ahead of the op log) — reconcile that first, then re-run.

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
reach a permanent leaf — whether **written through** at decision time (impactful facts) or
distilled at **condensation** (everything else). See *Two-tier writes* for which path a fact
takes.

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

## Two-tier writes: write-through vs. condense-later

Not every fact should wait for condensation to reach deep memory. Deep memory (knowledge
leaves) is written at **two** times: **write-through** at decision time for impactful facts,
and **condensation** for everything else. Tier every durable fact as you write it:

- **Impactful → write-through NOW, to both the journal *and* the deep leaf.** A fact that
  either (a) makes a current knowledge page inaccurate or incomplete, (b) reverses or
  supersedes a prior durable decision, or (c) introduces a new architectural component,
  cross-project relationship, or durable user fact.
- **Small → journal now; promote or refine at condensation.** Incremental progress, or a
  refinement that doesn't contradict any existing page.
- **Ephemeral → journal now; dropped at condensation.** Transient git/branch/working-tree
  state, "currently doing X", session-local status/action-items. Never becomes a leaf.
- **Borderline → journal now; evaluated at age-out.** Durability genuinely uncertain — the
  distiller applies the signal filter then and promotes-or-drops.

**Write-through procedure (impactful only):**

1. Append the fact to today's journal under the right section (a breadcrumb, with evidence).
2. Descend the TOC to the target leaf (create it under the right TOC — splitting a crowded
   TOC — if none fits). Merge the **distilled** fact; synthesize, never paste, and never
   duplicate a point the leaf already states.
3. Refresh the leaf: `updated:: <today>`; `summary::` if it changed; ensure `parent::`,
   `project::`, and back-links; bump `frecency` +5 (cap 60), or seed `frecency:: 30` for a new
   leaf; set `seen:: <today>`. A new leaf/TOC also needs its one-line `[[link]]` + hook added
   to the parent TOC (and the parent to `index` if it is a new top-level topic).
4. **Mark the journal breadcrumb `#in-deep [[target-leaf]]`.** This tells condensation the
   item is already in deep memory (so it is verified, not re-merged — see *Condensation*) and
   doubles as the routing link.

Edit-merge, never clobber: read the leaf first and add to it. This applies to the headless
on-close journaler too — `claude-memory-dump` write-through's impactful items on these same
rules; an autonomous agent that pastes instead of merging duplicates pages.

## Condensation (daily → knowledge rollup)

**Retention = the 5 most recent journal files** (by date). High-resolution recent memory
holds exactly these 5 and never more; the count is what governs, not the calendar, so gaps
in dates are irrelevant. The instant a 6th journal appears, the oldest surplus journal is
distilled into permanent knowledge pages and then deleted — the distilled version lives on —
bringing the count back to 5. The count is never reduced below 5 except transiently while a
new journal is being added.

**Trigger — mechanized, and it does not depend on you remembering.** The SessionStart hook
runs `memory-index consolidate --reap` on **every** session (not just the first of a day, so
a missed reminder is caught the next session, never lost until tomorrow). It splits every
aged journal (every journal older than the 5 most recent) two ways and acts accordingly:

- **reapable** = aged **and** already carries `consolidated:: <date>` → the hook **deletes it
  automatically** (`outl page delete --confirm`). You never delete a journal by hand.
- **pending** = aged and **not** yet `consolidated::` → distillation is synthesis, so it needs
  an LLM — but it is **not left to whatever interactive session happens to notice a directive**.
  The hook launches **`memory-consolidate`**, a detached, headless `claude -p` agent, in the
  background: it distills every pending journal per this section, marks each `consolidated::
  <today>`, and reaps — automatically, with no prompting, on every install that has the
  `claude` CLI. Your interactive session is only *told* it is running (so you don't do it by
  hand). The **`⚠ CONSOLIDATION REQUIRED`** directive is now only a **fallback**, injected when
  the `claude` CLI or `memory-consolidate` is unavailable; when you see it, do the steps below
  *this session, before the user's request*.

**Retention is by count and deletion is driven by the `consolidated::` mark:** the 5 most
recent journals are vivid memory and stay; the reap deletes any *aged* journal (older than
those 5) that carries a `consolidated::` mark. The `distilled-into::` property is still
recorded as provenance — which leaves each journal fed — but it is **not** a reap gate. An
earlier design re-verified that every named leaf existed and carried `updated:: >= <consolidated
date>` before deleting; that gate was removed because it looped: a correctly-distilled journal
whose leaf stored `updated::` as a bullet rather than hoisted frontmatter, or whose leaf already
held the fact and wasn't re-stamped, failed verification and was re-distilled (and re-billed)
every session while lingering past the 5-journal window. The distiller therefore sets
`consolidated::` **only as its genuine last action, after the leaves are truly written** —
that mark is the commitment that the content reached the tree.

When you see the `⚠ CONSOLIDATION REQUIRED` directive, for each pending journal date:

1. `outl_daily_get <date>` — read the raw journal.
2. Cluster its items by the `[[linked page]]` / topic they concern. **Items already marked
   `#in-deep [[leaf]]` were written through to deep memory when authored (see *Two-tier
   writes*) — do NOT re-merge them. Verify the named leaf still carries the fact, and list
   that leaf in this journal's `distilled-into::` evidence so the reap check passes; that is
   all they need.**
3. Tier every remaining cluster before writing anything. **DROP ephemeral items outright** —
   transient git/branch/working-tree state, "currently doing X", session-local status (e.g.
   "branch X has uncommitted changes" never becomes a leaf). For **borderline** items whose
   durability is genuinely uncertain (e.g. a "retrieval cost pattern" musing), apply *What
   long-term memory is for* and promote-or-drop **deliberately** — do not reflexively keep.
   For each cluster that clears the bar (keep cross-repo relationships, plan state, decisions
   + why; drop anything the repo/git/`CLAUDE.md` already holds) — descend the tree to the
   target leaf document (an existing one, or create a new leaf under the right TOC — splitting
   or adding a TOC level if a parent is getting crowded). Merge the **distilled** points in —
   synthesize, don't copy verbatim, and never duplicate a point the leaf already states
   (semantic dedup, on top of the `#in-deep` skip above). Set/refresh `updated::` and
   `summary::`; ensure `project:: [[...]]`,
   `parent:: [[<toc>]]`, and back-links are present. Touch its frecency (a new leaf seeds
   `frecency:: 30`; merging into an existing one is a use → `+5`, cap 60); set
   `seen:: <today>`.
4. If you created a new leaf or TOC, add its one-line `[[link]]` + hook to the parent TOC
   (and the parent to `index` if it's a new top-level project/topic).
5. **Record evidence, then mark done — as the LAST actions, and never delete by hand.**
   First `outl_page_prop_set <date> distilled-into="[[slug-a]] [[slug-b]] …"` naming every
   leaf you actually merged this journal into (as provenance; set each of those leaves'
   `updated:: <today>` in step 3); if the journal held nothing durable, `outl_page_prop_set
   <date> distilled-into=none` instead. Then `outl_page_prop_set <date> consolidated=<today>` —
   set this ONLY once the leaves are truly written, because the reap deletes any aged journal
   carrying a `consolidated::` mark (there is no separate per-leaf re-verification). The hook
   reaps at the *next* session start — or run `memory-index consolidate --reap` yourself to
   burn it now.

Then run the **frecency sweep** (see below) over all leaf documents.

Finally, refresh `index`: bump its `updated::` and trim the `## Recent journals` list to the
current window.

## Frecency & pruning

Every node — every content **line**, every **leaf**, and every **TOC/MOC** — that stops
earning its place is dropped, so the tree never accretes dead weight. Frecency = frequency +
recency, kept integer-simple (no exponentials), scaled to a **~1-month** window: long enough
that real-but-occasional knowledge survives, short enough that stale detail clears out. It is
the **sole retention metric** for this decay-cache memory, and it runs at **three
granularities**, all sharing the same seed **30** / cap **60**, decayed **lazily** (see *Lazy
decay* below) rather than rewritten day by day:

- **Page (leaf AND TOC).** *Every* page carries `frecency::` (integer) and `seen::` (last date
  the score changed) as **hoisted frontmatter** — leaves and MOCs alike. There is **no `pin::`
  exemption** any more; a foundational page is protected only by sitting on a warm access path
  (see *Credit* below). Only **journals** are outside frecency — they have their own
  count-based retention (see *Condensation*).
- **Line (content block).** Each real content bullet decays independently, keyed by its
  **stable outl block id**, so a stale line inside an otherwise-live page ages out on its own
  while the file lives. Scores live in a ws-level ledger
  `~/.claude/memory/.frecency/sections.json` keyed `{slug: {block_id: {f, seen}}}` —
  **outside** `.outl/`, so a `rebuild` never wipes it. It is a usage signal, not knowledge: if
  lost, lines just reseed at 30. **Never hand-edit it;** `memory-index` owns it. (Headings and
  frontmatter props are not tracked lines.)

**Lazy decay — `frecency::` is a checkpoint, not a running counter.** `frecency::` is written
only at `seen::` (the date of last credit, or of creation) and is never rewritten day by day.
The *effective* frecency at any moment is computed on the fly, not stored:

> **effective = `frecency` − days_since(`seen`)**

A page or block is evicted the moment its effective frecency is **≤ 0**. Seed on creation is
still **30** with `seen:: <creation date>`; cap is still **60**; journals remain exempt.

**Credit — a use warms the whole access path.** Reinforcement is `touch`'s job (decay's
counterpart), fired automatically by the `PostToolUse(outl_page_get)` hook on every successful
fetch, any page type, and safe to run by hand (`memory-index touch <slug>`). Credit is the only
thing that writes frecency at all, and it always writes the pair together — `frecency += bump`
**and** `seen = today` (cap 60) — which re-bases the checkpoint so the decay window restarts
from today. One fetch credits:

- the fetched page **+5** (cap 60);
- **every ancestor MOC up the `parent::` chain +5** — using a memory means using the index that
  led to it, so an index never dies while anything reached through it stays live. This upward
  propagation is what makes MOC decay safe: a TOC only reaches 0 once its *entire subtree* has
  gone cold.
- every content line of the fetched page **+2** — a whole-page fetch is weak per-line evidence.
  The precise line signal is the **search hit**: `memory-index search --credit` (the
  push-retrieval hook) resolves to an exact `slug › heading` and bumps just the matched lines
  **+1**.

Because the fetch hook already credits reads, do **not** hand-bump on top of a fetch. Still
bump by hand for a use that is *not* a fetch — e.g. merging into a leaf during condensation —
via `outl page prop set` or `memory-index touch`. Optionally order a TOC's link list by
effective frecency (high → low) so the most-used pathways surface first.

**Decay & eviction — silent and mechanical, no longer yours to review.** On the first session
of a new day the SessionStart hook runs `memory-index maintain`, which now *computes* effective
frecency (`frecency − days_since(seen)`) for every page and line instead of decrementing a
stored value, and writes through `outl` for almost nothing:

- a **one-time migration stamp** — any page or block that already carries a `frecency::` but no
  `seen::` gets `seen = today` written once, so it starts its decay window; and
- an **eviction**, when effective frecency is **≤ 0**.

No other write happens — the old daily `-1` per node is gone. (Every daily decay write was an
`outl` op, and `outl` replays its whole op log on every boot, so cutting the daily write keeps
every future `outl` call cheap.) Anything at effective **0 is FORGOTTEN immediately** — no
prompt, no injected `⚠` candidate list, no reviewed step:

- **line → 0** — delete just that block (`outl block delete`); the file stays.
- **leaf → 0** — soft-trash the page and scrub `[[it]]` out of every surviving block; the
  parent TOC stays.
- **MOC → 0** — soft-trash the MOC **and its whole subtree** (all descendants via `part-of`),
  and scrub inbound refs. Upward credit propagation guarantees this only fires once the entire
  subtree is cold, so the cascade is safe.

The old "pruning stays yours / prune-candidate directive" step is **gone**: `maintain`
performs all deletion itself through `outl`, then refreshes the index. There is still no
`pin::` exemption. `doctor` still reports `decay-risk` (page ≤5) and `sec-decay` (line ≤5) for
visibility (both now read off effective frecency), and the ledger GCs block ids that no longer
exist.

Scale: a fresh node (seed 30) survives ~30 idle days; each use adds ~5 days and re-bases the
checkpoint to today; a heavily-used node rides at the 60-day cap. Deletion here is intentional
and unrecoverable, exactly like journal burning.

## Research references (external live docs)

Research the user commissions is written as markdown to `~/Code/research/*.md` — **outside**
the graph. Those files are the source of truth and must never be copied into or symlinked
under `pages/` (a raw file has no `.outl` sidecar and no frontmatter, so it isn't a real
node, and the pruning sweep — `outl_page_delete` — could destroy it). Link them via a
**reference stub**: a third node kind alongside `moc` and `knowledge`.

- **Kind.** `type:: reference`, slug `research-<topic>`. Props: `source:: <absolute path to
  the ~/Code/research/*.md file>`, `status:: active | complete`, `parent:: [[research]]`,
  `summary::`, `updated::`, plus the frecency pair `frecency::` / `seen::` like any page.
  `maintain` decays every non-journal page, so a stub also ages out if it is never touched —
  but its **primary lifecycle is `status::`**: it is deleted explicitly on `status:: complete`
  (below), and while its research stays in use, fetching the stub (or the `[[research]]` walk
  that lands on it) keeps it warm well ahead of decay.
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
- **Every page carries the frecency pair `frecency::` / `seen::`** (see *Frecency & pruning*) —
  TOCs (`type:: moc`), leaves (`type:: knowledge`, plus `project::`, `parent::`, `updated::`,
  `summary::`), and reference stubs (`type:: reference` + `source::` + `status::`) alike. Only
  journals are exempt, and there is no `pin::` exemption.
- **Keep every page small.** ANY page — leaf or TOC — whose body exceeds ~1800 tokens (the
  `MEMORY_SPLIT_TOKENS` budget) is automatically split by the compaction agent: a leaf into a
  TOC + child leaves, an overgrown hub into grouped sub-TOCs (see *Split on growth* and *The
  graph model*). A page that would eat a big slice of context on read is a bug — traversing
  tiny pages is the whole point.
- Prefer editing an existing leaf over creating a near-duplicate; descend the tree or
  `outl_search` first. Editing an existing leaf also refreshes its frecency — another
  reason to merge rather than fork.
- **Any change to a page body bumps its `updated::`** to that day. The routing/staleness
  signals all rely on `updated::` tracking the body; a body edited without bumping `updated::`
  is the classic staleness bug (a MOC whose contents moved on while its date froze).
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
