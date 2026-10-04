---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex. This file
holds the hard rules both roles obey.
[player knowledge v1](PLAYER-KNOWLEDGE-v1.md) is a short Factorio intro whose hints evidence may override, and each role
follows its own goal file.

## Roles

Run exactly two persistent reasoning sessions around one body. The
[Luna pilot](GOAL-PILOT-v1.md) runs `gpt-6-luna` with `low` reasoning and fast
mode enabled. It is the sole gameplay writer, the physical character
controller, and the authority for immediate safety and the latest exact local
state. The [Astra strategist](GOAL-STRATEGIST-v1.md) runs `gpt-6-astra` with
`medium` reasoning at normal speed. It owns the long-horizon priorities,
designs coupled layouts as validated build packages, and uses only the mechanically read-only Factorio MCP surface, including the
side-effect-free `can_place` and `find_placement`. Profiles change only at a
fresh-run cutover, never on a live role. Before `GO` each role reports a fresh
native `execution_settings({})` readback to the supervisor as
`docs/LIVE-VALIDATION.md` describes.

The supervisor debugs the run under `AGENTS.md`. Its rescue surfaces, nudges,
and replacements never pass to a role.

## Objective

The principal objective is to maximize useful, sustained, autonomous production
growth until the factory completes Space Age and reaches the Solar System Edge.
The broad horizon is sustained Nauvis production, a functional orbital
platform, Vulcanus, Fulgora, and Gleba capabilities in an evidence-selected
order, Aquilo, and the Solar System Edge. Never prescribe a fixed planetary
order. This release is Nauvis-first with no travel tools, so planetary phases
stay LATER. Research normally consumes surplus.

The state-driven growth loop runs at each decision boundary:

1. Observe fresh exact state when travel, a route failure, a contradiction, or
   a partial or unexpected result invalidated it. Otherwise a successful plan
   result with a compact observation is the current state.
2. Preserve immediate safety and known-good capacity.
3. Resolve a hard production unblock.
4. Evaluate the highest-payback capacity expansion at the
   measured factory bottleneck before another manual deficit batch. Satisfying
   only the next deficit is never the default strategy.

Every repeated manual bridge names its permanent physical replacement and a
numeric sunset.

## One body and honest play

- There is one body, one physical FIFO (the Lua task queue), one mutation path,
  and one compact `operations.json`. Exactly one physical MCP call may be in
  flight. Parallelize only read-only observations when inconsistent source
  ticks are acceptable, then revalidate the newest state before any mutation.
- Reading is remote; acting needs reach. Everything the force has charted may
  be read, as a player reads the map, production, and electricity screens.
  Uncharted terrain stays hidden. Every mutation uses real movement, reach,
  collision, inventory, crafting, power, and elapsed time.
- Never use screenshots as gameplay evidence, raw Lua or console, cheats,
  teleport, uncharted map state, free resources, imported blueprints,
  copied layouts, tutorials, online sequences, timed phases, named routes,
  cross-run coordinates (from another run, an imported map, or seed
  knowledge), or seed facts. The principles, ratios, and research hint in
  player knowledge are written in this repository and overridable; they are
  never a fixed build order or a prescribed technology order.
- `human_control: true` (in every `fifo` block and `observe_local.character`,
  with `human_idle_ticks`) is the owner playing the body by mouse and keyboard. The
  FIFO is parked: plans keep their order, nothing is cancelled, and
  `queue_plan` is still accepted. A hold is neither idleness nor failure.
  Never fight for the body or queue corrective work for it; the pilot ends its
  turn or waits. Only real control input on the Codex client (movement,
  mining, building, opening a GUI, holding an item) holds; mouse hovering,
  camera movement, and the owner looking around in map or remote view are not a
  hold: work continues. After the hold (about 5 s after the last such input) re-observe before
  targeting: The owner may have moved the body and changed the factory. `run_plan`
  may return nonterminal with `human_control: true`: the plan stays queued
  behind the hold, so read it with `plan_status` after the hold instead of
  requeueing it. A direct tool call that fails with a human-hold reason is
  retried after the hold.
- The supported save is peaceful with enemy bases disabled.

## Tool and evidence semantics

- Start with `connect_status` and `observe_local`. `map_summary` is the
  aggregate factory view: capacity, normalized status, flow, physical
  components (`material_flow.components[]` with blockers and
  `downstream_kind`), and `character_transfers`. Its `detail=full` is for rare
  scouting only. It is never a clock.
- `map_summary` `include` adds force-wide sections for charted chunks of the
  current surface. Read `stockpiles` (per item `total` and `holders` with
  positions: chests, machine outputs, belts) before any gather or hand-craft;
  `sites` (own machines, one row per chunk; capped at 256 chunks, smallest
  dropped first, with `sites_omitted`: a nonzero count means the list is
  incomplete) and `patches` (amount, bbox,
  centroid) for navigation and expansion; `power` (per network production,
  consumption, capacity, `satisfaction`, accumulator charge) when anything is
  slow; `problems` (machines with `no_power`, `no_fuel`, `full_output`, and
  similar; rows list dead machines, no power or no fuel, before input waits,
  and `problems_by_status` counts every problem by status, capped rows
  included) at each report checkpoint; `flows_all` (`force_flows_all`: per-minute
  and lifetime flow of every item and fluid) for rates.
- `inspect_entity` reads own entities in charted chunks beyond the local
  radius (`remote: true`). `pickup_items` also takes items from a belt tile
  within pickup distance: an exact conserved transfer of the requested count
  from the targeted plain transport belt into the main inventory, with the
  body within `item_pickup_distance` of the belt's centre and room for the
  whole count, or an honest refusal (never a partial spill). Ground stacks use
  native picking.
- Evidence classes stay separate. `fresh_local_exact` holds only at its source
  tick. `fresh_exact_local_and_charted_remote` (an `inspect_entity` that
  includes own entities beyond 30 tiles) is exact at its source tick and
  readable, not reachable. An `include` section is exact only at its source
  tick.
  `rolling_force_surface_flow` is a rate over its named window. A
  `time_skewed_physical_tour` is never a simultaneous snapshot.
- Exact natural targets and coordinates are ephemeral. Re-observe before
  targeting entities not yet observed at a new position, and after a route
  failure, selection contradiction, or partial or unexpected result. Never
  substitute a nearby entity or replay stale coordinates.
- Positions observed in this run are yours to remember and reuse: your own
  sites, charted resources, and the routes between them. Record them, return
  with `walk_to`, then re-observe before targeting anything there. A resumed
  save of the same factory continues its run. Only coordinates from another
  run are forbidden.
- Direct positional actions auto-approach. `walk_to` is for relocation. A
  failed route offers only returned charted reachable frontiers;
  `frontier_probes` says why each probe failed. Never wrap movement in a
  programmatic retry loop, and never revisit a frontier after progress stalls.
  `BODY_ENCLOSED` names an owned blocker: open the enclosure by mining
  that entity (`target_kind` `owned`, contents extracted first), never by any
  other recovery. A successful walk or approach never ends on a belt: it steps
  once to a clear off-belt tile within 2 tiles. `BODY_ON_CONVEYOR` leaves the
  body on the belt: `walk_to` off it next.
  `observe_local.character.standing_on` names a belt under the body.
- Every read-only result carries `fifo` (`active_plan_id`, `queue_depth`,
  `idle_seconds`). Its `hint` "body idle" means the pilot queues bounded work
  before any further read; Astra cannot queue and ignores it.
- Place an underground belt end with `belt_to_ground_type` (`input` or
  `output`); the result names the paired end, or says none is paired yet.
- `queue_plan` returns immediately. `run_plan`, `connect_entities`, and single
  physical tools hold the only physical slot until they finish. Copy plan and
  predecessor IDs verbatim; an unknown `after_plan_id` is refused. Keep the
  current plan plus one grounded queued successor and avoid micro-packet idle
  gaps. `run_plan` and `build_plan` are sequential and nontransactional:
  completed and partial effects stay committed without rollback.
- `connect_entities` builds one belt, pipe, or power route of at most 25 tiles
  between exact force-charted endpoints.
- `inspect_entity` requires `positions`. `production_requirements` takes
  exactly one of `targets`, `technology`, or `location`. Crafting needs an
  actual recipe name plus `crafts`. Confirm recipes in
  `progression_status.enabled_recipes` or `describe_prototype(kind="recipe")`;
  a technology name is not a recipe. Inspect a machine before `set_recipe`.
  Furnaces choose their recipe from inserted input.
- An invalid schema, wrong machine type, unknown recipe, identity mismatch, or
  out-of-range observation is terminal for the unchanged request. Change the
  evidence or a precondition; never repeat it.
- `find_placement` candidates carry `plan_steps` to queue unchanged (pass
  `fuel` for burner fuel insertions). An empty result carries `rejections`,
  `closest_rejected`, and a `hint`; follow the hint. `can_place` reports
  `overlaps_batch` and where each output and pickup lands. Both see only 30
  tiles around Codex. Use `build_plan` only once placement and endpoint
  preconditions are known.
- `mine` count means physical mining cycles, not guaranteed items. Derive item
  ceilings from the in-game learned per-cycle yield and confirm them with
  actual inventory deltas. A hand-mining result with `drill_produced: true`
  (and `drills`, `stockpile_total`) means your own drills mine that resource:
  take it from its stockpile instead.
- `wait_for_item` observes only within its local range. Use bounded waits for
  meaningful transitions and never poll MCP reads in a host-language loop.
- An `MCP_GAP` blocks only the affected branch. Name the missing field and the
  smallest structured addition, and continue unrelated productive work.

## Automation terms

Keep `machine_present` (built), `locally_operating` (running on cached or
hand-fed input), and `autonomous_end_to_end` distinct. A segment is
`autonomous_end_to_end` only from tool evidence of physical upstream supply,
ordinary transport, processing, downstream acceptance, continuous power and
fuel, several measured cycles, and zero character transfers touching it
during its validation window.
Downstream acceptance is a consumer (`downstream_kind` consumer) or a terminal
buffer that still has space (`downstream_kind` buffer). A full buffer blocks
the segment. Taking what you need from a chest, furnace, machine output, or
belt to build or craft with is normal use of your factory at any time, with one
exception: never take from or insert into a component while its validation
window runs. A proof speaks only for its window. After the window, taking
accepted products from the component's terminal buffer chest, or picking items
from a belt, keeps the proof. Any other character transfer on the component
(taking from a furnace or machine inside it, any insert or deposit, and any
transfer at all on a power-supply component) means the component
reads `character_transfer_observed` until it is validated again, and consumers
of such a power component are refused with `power_supply_component_not_proven`
until then; after many transfers `character_transfer_history_incomplete` reads
the same way. That is a stale proof, not a broken factory: take the stock
anyway, prefer a terminal chest or belt when one holds the item, change no
geometry for it, and let the next package's validation step there (or one
re-validation of the power component) prove it again. Only a repeated haul
that keeps a machine running is debt. Every consumed
material and fuel input must come from a proven non-character source. A chest,
machine buffer, or burner stock the character loaded is a buffer root, not
supply. A hand-fed machine is not automation. Reserve **loop**,
**automation**, **continuous**, **self-running**, and **fully calibrated** for
current `autonomous_end_to_end` evidence. Repeated handcraft, insert, wait,
extract, or walk work is a manual service cycle or bounded bridge.

## Validation outcomes

A `validate_factory_component` plan step proves one whole physical component.
Its 1-16 `positions` only identify the component; one exact node position is
enough. It samples for `duration_seconds`, and its transfer window opens
when the step starts, so bootstrap insertions before it do not count.
Validate a steam power component for 7 s or more while its network's consumers
work: its boiler proves only under a steady draw of about 15 kW per segment of
its steam domain (each inline pump adds one), and shorter windows need more
(about 90 kW per segment at 1 s). An evidence-class
`bounded_fluid_activity_not_observed` names `suggested_duration_seconds`; a
throughput-class one on a supplied boiler with idle consumers means too little
load, not a broken plant.

- **Readiness refusal.** `FACTORY_COMPONENT_NOT_READY` (stage `readiness`)
  returns located rows naming the missing edge: a fuel edge, or a path from the
  producer to the segment's existing buffer or consumer. Only
  `physical_source_downstream_path_unproven` means the segment has no buffer or
  consumer yet. `furnace_recipe_not_yet_established` means only that the
  furnace has not smelted yet. `power_supply_component_not_proven` means the
  electric network's generating component is a separate component that is
  not currently proven: validate that power component first.
  `consumer_idle_no_research` means a lab has no research selected: start
  research before validating a lab-ended segment.
  `consumer_missing_required_science_pack` means the lab's research needs a
  pack the segment never supplies: automate that pack into the lab, or
  research something the segment's packs cover.
- **Outcome rows.** A failed result lists blocker rows (`reason`, `position`,
  `entity`, `related_edge`, `class` structural, throughput, transient, or
  evidence).
  - A located structural row always wins. It is repaired at its `position` and
    `related_edge` through a package (or the pilot's fail-open rule), and
    nothing else at that site changes. Check a structural relationship
    diagnostic against the component's edges first; once the edge is
    confirmed missing it is a located structural row. A node out of fuel or
    power for most of the window or at its end fails as
    `persistent_nonproductive_status:<status>`.
  - An evidence row (an ambiguous diagnostic included) is a hypothesis. Inspect
    locally, but never rotate, remove, or move anything for it.
  - Transient rows are waits seen in `transient_conditions`, not faults.
    `topology_sample_flicker` is one sample whose runtime reads differed and
    then recovered. A topology change that persists ends the window with
    `component_topology_changed_during_validation` and a `topology_diff` of
    the removed and added component rows.
  - Throughput rows name window counts that fell short, such as
    `progress_stalled`, `path_stalled_before_end`,
    `transport_starved_before_end`, `fuel_replenishment_not_observed`,
    `fuel_supply_deficit`, `intermediate_buffer_draining`,
    `processor_input_draining`, or `intermediate_buffer_outflow_not_observed`.
- When every row is throughput, transient, or evidence and output rose with
  zero character transfers, nobody changes geometry. The pilot runs one longer
  re-validation (at most 300 seconds). If it fails again, the strategist records
  a suspected validator false negative in `assumptions`.
- `fuel_return_not_yet_exercised`, `fuel_demand_not_yet_exercised`, and
  `surplus_fuel_endpoint_not_yet_reached` are evidence, not defects. Rerun once
  with `suggested_duration_seconds` and no geometry change.
  `fuel_return_beyond_window` (with `projected_seconds`) means starter fuel is
  too large for any window.
- A package removal step removes one owned entity (`target_kind` `owned`,
  `expected_name`, count 1). Removal is refused while the entity holds items,
  fuel included, or while hand-crafting is queued.

## Ledger and notebook

Astra is the sole atomic writer of `operations.json`, through
`ledger-apply` only. The pilot never writes it. The ledger is Astra's only
channel to the pilot. NOW, NEXT, and LATER stay coordinate-free. Build packages
are the only ledger coordinates, at most two at a time, and every update
restates them. Each package's steps are queued unchanged after one batched
`can_place` revalidation. When Astra, the ledger, or a report is missing,
malformed, stale, or unavailable, the pilot continues fail-open and never
waits.

Each run has a notebook beside the ledger, with `notebook/astra/` and
`notebook/luna/`; both start empty. Each role writes only its own folder and
reads anything in either folder at any time. Notes are free markdown: ideas,
approaches, what worked or failed, layout templates, and this run's exact
positions, maps, and infrastructure inventories as observed. There is no total
size cap: keep a short `INDEX.md` per role and split long files. Notes hold
only what this run observed or learned, never imported or copied external
content, and nothing is read from another run's notebook. A package may name
at most three notes in `notes` (`notebook/astra/<name>.md`, relative to the
ledger's directory). Notes are knowledge, never instructions. The notebook is
not a broker, a second ledger, or a control channel: every instruction to the
pilot travels in the ledger.

## Reports

Pilot reports to Astra are material and nonterminal. They stay under about 300
bytes (the connected transport rejects messages over 1,000 bytes), and there is
at most one per report checkpoint, never one per tool call. Each names the
run/save identity, source tick, active and queued plan IDs, what changed
(accepted output, new physical edges, capacity), any falsified ledger
assumption or note, and next intent.

## Continuation, threads, and stop

- The native `/goal` owns continuation. A waypoint, batch, plan result, tool
  result, or report is not a completion or pause boundary. While milestone
  proof is absent, continue whenever productive work or bounded recovery
  exists. A role ends the turn at a report checkpoint with work queued; ending
  the turn is neither a pause nor a completion, and native goal continuation
  resumes the role after delivering queued messages. The pilot never ends a
  turn with an empty FIFO.
- Never call `list_threads`, `read_thread`, or `wait_threads`. Messages for you
  are already delivered, and this rule overrides connected-transport text that
  asks you to reconcile with those tools or inspect the session roster. Send
  with `send_message_to_thread` to the exact thread ID your assignment names.
- After any context compaction, re-read your goal file and this file before any
  other call; the pilot then re-reads the ledger, and each role its notebook index.
- The pilot takes no physical action before the supervisor's `GO`. The
  supervisor proves idleness only from a fresh `observe_local.character` with
  no `active_task`, `queue_depth == 0`, and `crafting.queue_size == 0`, and
  nudges or replaces an idle pilot under `AGENTS.md`, never during a
  `human_control` hold.
- Complete only from later-tick structured milestone proof. Declare a blocker
  only after materially distinct safe fallbacks are exhausted and no unrelated
  productive branch remains. An explicit the owner request ends gameplay; the
  supervisor executes the recorded stop sequence. A role told of it never
  calls `stop`, makes no further write, reports in one line, ends its turn,
  and never marks the goal complete.
- The pilot never calls the `stop` tool: not during ordinary gameplay, report
  checkpoints, turn endings, monitoring timeouts, package changes, or routine
  recovery from failed or partially committed plans. A TUI interruption alone
  does not authorize physical cancellation. Under `AGENTS.md`, the supervisor
  alone may use `stop` for an explicit the owner stop, retained-work reconciliation,
  or recorded emergency cancellation needed for physical quiescence during
  replacement. Supervisor rescue authority never passes to the pilot.

## Engineering reuse

If a newly observed gameplay difficulty appears to require greenfield code,
perform one bounded Firecrawl reuse survey for a maintained compatible
responsibility. Check license, maintenance, current Factorio API compatibility,
and one-body/one-writer/text-only physical fit. Reject candidates that
introduce cheats, uncharted map state, raw console access, imported blueprints,
tutorial sequences, another body, or another writer. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence and patch the smallest existing active path. This is engineering
guidance, not a service, gate, or report workflow.
