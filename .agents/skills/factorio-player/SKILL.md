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
designs coupled layouts as validated build packages, keeps the run notebook,
and uses only the mechanically read-only Factorio MCP surface, including the
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
- Use only locally visible or force-charted structured evidence and real
  movement, reach, collision, inventory, crafting, power, and elapsed time.
  Never use screenshots as gameplay evidence, raw Lua or console, cheats,
  teleport, hidden map state, free resources, imported blueprints,
  copied layouts, tutorials, online sequences, fixed build orders, prescribed
  technology order, timed phases, named routes, map coordinates, or seed facts.
- The supported save is peaceful with enemy bases disabled.

## Tool and evidence semantics

- Start with `connect_status` and `observe_local`. `map_summary` is the
  aggregate factory view: capacity, normalized status, flow, physical
  components (`material_flow.components[]` with blockers and
  `downstream_kind`), and `character_transfers`. Its `detail=full` is for rare
  scouting only. It never authorizes remote inventories and is never a clock.
- Evidence classes stay separate. `fresh_local_exact` holds only at its source
  tick. `charted_remote_summary` carries no exact stock.
  `rolling_force_surface_flow` is a rate over its named window. A
  `time_skewed_physical_tour` is never a simultaneous snapshot.
- Exact natural targets and coordinates are ephemeral. Re-observe before
  targeting entities not yet observed at a new position, and after a route
  failure, selection contradiction, or partial or unexpected result. Never
  substitute a nearby entity or replay stale coordinates.
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
  actual inventory deltas.
- `wait_for_item` observes only within its local range. Use bounded waits for
  meaningful transitions and never poll MCP reads in a host-language loop.
- An `MCP_GAP` blocks only the affected branch. Name the missing field and the
  smallest structured addition, and continue unrelated productive work.

## Automation terms

Keep `machine_present` (built), `locally_operating` (running on cached or
hand-fed input), and `autonomous_end_to_end` distinct. A segment is
`autonomous_end_to_end` only from tool evidence of physical upstream supply,
ordinary transport, processing, downstream acceptance, continuous power and
fuel, several measured cycles, and zero character transfers touching it.
Downstream acceptance is a consumer (`downstream_kind` consumer) or a terminal
buffer that still has space (`downstream_kind` buffer). A full buffer blocks
the segment, and emptying it by hand is automation debt. Every consumed
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

Each run has a notebook directory, `notebook/`, beside the ledger; it starts
empty. Astra alone writes it, as free markdown: ideas, approaches, what worked
or failed, and its own layout templates in relative coordinates. Notes hold
only in-game learned content, never imported or copied external content, and
never world coordinates. `notebook/README.md` is an index of at most 2 KB, and
the whole notebook stays within about 64 KB. A package may name at most three
notes in `notes` (`notebook/<name>.md` paths relative to the ledger's
directory). The pilot reads only the notes a package names. The notebook is not
a broker, a second ledger, or a control channel: every instruction to the
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
  other call; the pilot then re-reads the ledger, and Astra the notebook index.
- The pilot takes no physical action before the supervisor's `GO`. The
  supervisor proves idleness only from a fresh `observe_local.character` with
  no `active_task`, `queue_depth == 0`, and `crafting.queue_size == 0`, and
  nudges or replaces an idle pilot under `AGENTS.md`.
- Complete only from later-tick structured milestone proof. Declare a blocker
  only after materially distinct safe fallbacks are exhausted and no unrelated
  productive branch remains. Stop only on an explicit the owner request. The
  supervisor then calls `stop`; a role told of it never calls `stop`, makes no
  further write, reports in one line, ends its turn, and never marks the goal
  complete.

## Engineering reuse

If a newly observed gameplay difficulty appears to require greenfield code,
perform one bounded Firecrawl reuse survey for a maintained compatible
responsibility. Check license, maintenance, current Factorio API compatibility,
and one-body/one-writer/text-only physical fit. Reject candidates that
introduce cheats, hidden map state, raw console access, imported blueprints,
tutorial sequences, another body, or another writer. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence and patch the smallest existing active path. This is engineering
guidance, not a service, gate, or report workflow.
