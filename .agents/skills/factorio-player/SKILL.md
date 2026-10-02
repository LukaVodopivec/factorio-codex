---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex. Start exactly
two persistent reasoning sessions: a [Sol strategist](GOAL-STRATEGIST-v1.md)
and a [Luna pilot](GOAL-PILOT-v1.md). The pilot is the sole gameplay writer,
physical character controller, and authority for immediate safety, exact local
state, travel, actions, plans, and physical completion evidence. The
strategist owns coordinate-free long-horizon priorities, designs every coupled
layout as a validated build package (the pilot designs one itself only when no
valid package arrives within two of its report checkpoints) (the only place the ledger carries
coordinates), and may use only the mechanically read-only Factorio MCP surface,
which includes the side-effect-free `can_place` and `find_placement`. There is one body, one physical
FIFO, one mutation path, and one compact `operations.json`.

For the next fresh supervised run, start the pilot as `gpt-6-luna` with
`low` reasoning and fast mode enabled, and the strategist as `gpt-6.1-sol`
with `medium` reasoning and the default service tier. These profiles apply only
at the safe fresh-run cutover; never reconfigure or replace a live role in place.

During preparation, each exact role must send the supervisor a fresh native
`execution_settings({})` readback, with current/next model, effort and service
tiers, `fast_mode_enabled`, and `fast_inherited_from_root` when available,
separate from requested settings. After a profile update, end that turn and
read again in the subsequent turn. The supervisor records receipt times and
explicitly consumes both role reports before `GO`; missing, delayed, malformed
or unexplained contradictory evidence holds gameplay. Apply the profile-evidence
procedure in `docs/LIVE-VALIDATION.md`; an enabled selection feature alone does
not establish the processing tier. Preparation profile reporting uses the
existing role-to-supervisor session transport, never a new pilot channel or a
new ledger field.

Until the owner explicitly re-enables benchmarking, the parent session is a debug
supervisor. It may diagnose or rescue through surfaces unavailable to the pilot,
but records every intervention and requires a fresh structured MCP observation
before returning control. Assisted progress and timing are never benchmark
evidence. The pilot never inherits screenshots, raw Lua/console, teleportation,
hidden map state, free resources, or a second body or write path.

The supervisor follows the stall and replacement contract in `AGENTS.md` and
the scenarios in `docs/LIVE-VALIDATION.md`. With milestone goals open, only a
fresh valid `observe_local.character` with `active_task` absent,
`queue_depth == 0`, and `crafting.queue_size == 0` proves idle. Parked waiting
and predecessor-blocked plans remain pending; `plan_status` requires an exact
known `plan_id`. Failed, missing, malformed, or stale evidence invalidates idle
timing. Retain the evidenced physical-change/idle-transition timestamp across
unchanged samples, excluding advancing ticks and unrelated factory output. If
the start is unknown, retain a labeled lower bound from the first valid idle
sample. Renewed activity resets timing and nudge state; run changes invalidate it.

Before `GO`, prove exact-pilot message delivery and the confirmed retirement
capability described in `AGENTS.md`. At about two idle minutes revalidate and
nudge once; failed or uncertain delivery is a capability problem. At about five
minutes revalidate, interrupt and retire the old pilot with proof it cannot
resume writes, settle in-flight physical calls, and freshly prove no active or
queued work or crafting before starting a replacement. `stop` remains recorded
emergency cancellation, in the cases `AGENTS.md` lists. Record interventions, invalidate affected state,
preserve Sol and the single body/FIFO/write path, and resume from latest structured
state. Offline checks do not establish live delivery or replacement behavior.

## Persistent work

The native `/goal` lifecycle owns continuation. A waypoint, small material
batch, individual plan, tool result, or progress report is not a completion or
pause boundary. While milestone proof is absent, immediately continue whenever
a productive action or bounded recovery exists. Keep the current plan plus one
`plan_status`-confirmed successor when safe. A terminal host continuation handle
is closed; follow its `next_action` or make a fresh call instead of waiting on it
again. After a material report with work queued (or the reason none is safe),
end the turn: a turn end is neither a pause nor a completion, and native goal
continuation resumes the role at once after delivering queued supervisor
messages. The pilot takes no physical action before the supervisor's `GO`. On an
explicit the owner stop the supervisor calls `stop`; a role told of it does not call
`stop`, reports in one line, and ends its turn, and no goal is marked complete
without milestone proof.

Complete only from later-tick structured proof of the assigned milestone. Stop
only on an explicit the owner request. Declare a blocker only after the loaded
exhaustion contract has eliminated materially distinct safe fallbacks and no
unrelated productive branch remains.

## Shared priority and state-driven growth loop

Sol owns one short `NOW`/`NEXT`/`LATER` list in the ledger, which is its only
channel to the pilot; Sol never messages the pilot. Each entry contains
only an objective, strategic reason, measurable completion condition, and any
essential prerequisite. NOW is a broad capacity or infrastructure outcome;
NEXT is the bottleneck expected after it succeeds; LATER is the next major
production or planetary phase. Sol may replace a priority when reports show no
structural growth. Luna may safely finish committed physical work, but applies
the revised priority to subsequent work unless fresh local evidence falsifies
it. Strategist silence, stale state, or a failed ledger read never blocks play.

The principal objective is to maximize useful, sustained, autonomous production
growth until the factory completes Space Age and reaches the Solar System Edge.
Research normally consumes surplus and unlocks stronger scaling tools; the next
item, trigger, technology, or packet is not automatically the main objective.
The broad horizon is sustained Nauvis production, a functional orbital platform,
the capabilities of Vulcanus, Fulgora, and Gleba in an evidence-selected order,
the Aquilo expedition, cryogenic and fusion-capable platform infrastructure,
and travel to the Solar System Edge. Never prescribe a fixed planetary order.
This release is Nauvis-first with no travel tools: planetary phases stay LATER
until travel exists, and sustained autonomous Nauvis production is the current
milestone.

At each natural decision boundary:

1. Observe fresh exact state when travel, a route failure, a contradiction, or
   a partial or unexpected result invalidates it; otherwise a successful plan
   result with a compact observation is the current state. Invalidate stale
   coordinates, identities, inventory claims, and completed assumptions.
2. Preserve immediate safety and known-good capacity.
3. Resolve a hard production unblock when useful work is otherwise stopped.
4. Before another manual deficit batch, evaluate the highest-payback capacity
   expansion at the measured factory bottleneck.
5. Execute the smallest grounded mutation, verify its actual accepted output and
   downstream utilization, identify the new bottleneck, and continue.

Maintain a growth objective alongside the milestone. It names the bottlenecked
stage, utilization, input/output buffers and work in progress, service or travel
time, power headroom, current and foreseeable recipe demand, candidate capacity
investment, break-even in item/time and expected future character touches, and
the expected next bottleneck. Foreseeable demand is limited to current
structured state, the milestone BOM, unlocked recipe evidence, the current plan,
and its validated successor.

Automation means an autonomous end-to-end material-flow segment, not merely a
placed or hand-fed machine. The segment must receive material from a physical
upstream source, move it through ordinary Factorio entities, process it, deliver
output to physical downstream acceptance, remain powered and fueled where needed,
and run for a bounded validation interval with no character inventory transfer
touching that segment. Keep `machine_present`, `locally_operating`, and
`autonomous_end_to_end` distinct. Local operation on cached or hand-inserted
input never proves autonomy. Downstream acceptance is either a consumer
(`downstream_kind` consumer, such as a working lab or generator) or a terminal
buffer that still has space (`downstream_kind` buffer); a full buffer blocks the
segment. The tools report which kind holds; whether a terminal buffer is good
enough for the current stage is a strategic choice, and emptying it by hand is
automation debt that is eventually replaced by a consumer or onward transport.
Every consumed recipe material and every fuel input must arrive from a proven
non-character physical source. A finite chest, machine buffer, or burner stock
loaded by the character is a buffer root, not autonomous supply, regardless of
how long it runs unattended.

Reserve **loop**, **automation**, **continuous**, **self-running**, and
**fully calibrated** for a segment with current `autonomous_end_to_end`
evidence. A repeated handcraft/insert/wait/extract/walk sequence is a **manual
service cycle** or bounded bridge, even when its quantities and timing are
calibrated. Never use fluent terminology to upgrade local operation into
autonomy.

Maintain a short prioritized automation-debt list of recurring character-
mediated edges: manual crafting, insertion, extraction, hauling, fueling, and
one-machine service. Prefer eliminating the edge with the greatest recurring
trips, travel time, inventory transfers, lost uptime, and durable throughput
payback. Track character transfer actions and transferred items against factory
output over a comparable interval; successful scaling makes character touches
per output, service trips per interval, and transport time trend downward while
autonomous physical edges trend upward.

Expand the bottleneck until downstream demand, power, resource supply, or
another measured stage becomes limiting. Reassess factory-wide flow after every
material capacity increase. Never scale a stage blindly while its downstream
consumer is idle, blocked, full, unpowered, or rejecting output. Count capacity
only after later structured evidence proves sustained input, physical transfer,
accepted downstream output, and increased utilization after at least one
expected production cycle.

Repeated manual crafting, fueling, hauling, collection, or one-machine service
is evidence that the service loop should be automated or expanded unless the
investment cannot repay itself within remaining useful demand. Compare a manual
bridge with capacity investment using setup time and materials, manual item/time
cost, expected future touches, reusable demand, power headroom, and downstream
utilization. A bounded manual bridge is valid for immediate safety or a hard
unblock, or when this measured break-even favors it; satisfying only the next
deficit is never the default strategy.

Bootstrap or recovery hand-feeding has a sunset. Every repeated manual batch
names the permanent physical connection that will replace it, the currently
missing capability or item, the bounded number of additional manual batches,
and the numeric stop condition. After an incidental hard shortage is cleared,
return to the unfinished automation investment; immediate research progress
does not cancel work that removes recurring character labor. A queued successor
may be one grounded multi-step construction plan so this investment survives an
interruption without increasing physical concurrency.

Build evidence-backed headroom when observed future demand makes reuse likely.
Prefer fewer, larger, buffer-aware transfers and colocated work over one- or
two-item oscillation. Size input and fuel packets from actual accepted demand,
buffers, WIP, observed consumption or production deltas, required uptime, and
travel plus corrective-action time. Avoid both starvation and oversized idle
stockpiles. Repeated fuel trips trigger a sustainable fuel-logistics payback
evaluation.

Preserve known-good capacity. Build, connect, and prove a replacement through a
later production cycle before removing working equipment or shared power. Rank
placements by useful lifetime, compatible coverage, endpoint binding, power,
and safe character egress before proximity. Stored buffers and one `working`
status are provisional, not sustained-flow proof.

Prefer compact, connectable production and short shared transport corridors
when current evidence makes them viable. Do not create another disconnected
production island unless its useful physical transport path can also be
completed and validated. Validate claimed autonomy over several expected
production cycles or a bounded interval: upstream arrival, active processing,
output departure, downstream acceptance or consumption, continuous power/fuel,
and zero character insert/extract actions for the segment must all hold.

## Tool and physical discipline

- Start with `connect_status` and `observe_local`. Use only locally visible or
  force-charted structured evidence and real movement, reach, collision,
  inventory, crafting, power, and elapsed time.
- Use the aggregate `map_summary` factory view to identify capacity, normalized
  status, force-flow evidence, conservative physical components
  (`material_flow.components[].state` blockers and `downstream_kind`),
  automation debt (`character_transfers`), and missing or ambiguous edges.
  Reserve `detail=full` for rare landmark, resource, or shoreline scouting. It never authorizes remote inventories;
  exact buffers still require ordinary movement followed by local inspection.
- Keep evidence classes separate: `fresh_local_exact` applies only at the local
  inspection source tick; `charted_remote_summary` is a current bounded remote
  aggregate without exact stock; `rolling_force_surface_flow` is a rate over
  its named window; cached or previously observed facts retain their old tick;
  and a `time_skewed_physical_tour` is never a simultaneous snapshot.
- Exactly one physical Factorio tool call may be in flight. The Luna pilot is
  the only role that receives mutation tools, and the Lua task queue is
  the sole FIFO lane. Parallelize only read-only observations when inconsistent
  source ticks are acceptable, then revalidate the newest snapshot before any
  mutation.
- Direct positional actions already auto-approach. Use `walk_to` for scouting or
  relocation, not as a redundant prefix or a route to an entity action. Exact
  walking preserves the requested goal; explicit vicinity walking may resolve a
  reported reachable point nearby. A tool-owned recovery may use a charted
  reachable frontier while preserving the requested goal. Goal occupancy is
  distinct from route failure. Let one bounded tool-owned recovery track net distance and visited
  frontiers; never wrap `walk_to` in a programmatic retry loop or revisit a
  frontier after progress stalls.
- Exact natural targets are ephemeral. Take a fresh local observation before
  targeting entities not yet observed at a new position, and after a route
  failure, selection contradiction, or partial or unexpected result; a
  successful plan result with a compact observation is the post-action state,
  so do not follow each success with another read. Cluster nearby work. Never
  substitute a nearby entity or replay stale coordinates.
- Use `queue_plan`/`plan_status` for current-plus-successor work and bounded
  meaningful-transition waits. `queue_plan` returns immediately; `run_plan` and
  single physical tools hold the only physical slot until they finish, so the
  FIFO is empty while the pilot reasons after them. Copy returned plan and
  predecessor IDs verbatim; an unknown or pruned `after_plan_id` is refused.
  Keep the current plan plus one grounded queued successor and avoid
  micro-packet idle gaps while their shared bottleneck remains valid. While
  preconditions stay valid, size each plan to outlast the pilot's next decision
  (a minute or more of body work, such as a larger mining or crafting batch for
  the next package's items); a `queue_plan` summary naming idle seconds means
  the body sat idle during the decision.
  `run_plan` is sequential and nontransactional: completed and partial effects
  remain committed when a later step fails, with no rollback.
- `inspect_entity` requires `positions`. `production_requirements` accepts
  exactly one of `targets`, `technology`, or `location`. `craft_items` and plan craft steps require an actual recipe name
  plus `crafts`; `place_entity` requires `name`.
- Before crafting, confirm the exact name in
  `progression_status.enabled_recipes` or `describe_prototype(kind="recipe")`.
  A technology unlock name is not automatically a craftable recipe. Inspect the
  live entity before `set_recipe`; furnaces choose from inserted input and never
  accept that action.
- Treat invalid schema, wrong machine type, unknown recipe, identity mismatch,
  and out-of-range observation as terminal for the unchanged request. Re-observe,
  change a precondition, or choose a materially different action; never repeat
  the same terminal semantic error.
- Use `find_placement`, `can_place`, and exact output targets before mutation.
  A candidate's `plan_steps` go into `queue_plan` unchanged (pass `fuel` to add
  burner fuel insertions). An empty result carries `rejections`,
  `closest_rejected`, and a `hint`: change the request as the hint says and
  never repeat it unchanged. `can_place` reports `overlaps_batch` and where each
  output and pickup lands, so a multi-entity design is checked before building.
  Use `build_plan` only after those placement and endpoint preconditions are
  known; its steps are sequential physical mutations, not a transaction.
- Coupled layouts arrive as Sol's build packages in `operations.json`. The pilot
  revalidates a package with one batched `can_place`, prepends its own
  gathering, crafting, and travel, queues the steps unchanged, and reports the
  plan ID or the falsifying step; it never redesigns a package and never waits
  for one.
  Missing drill coverage requires more structured evidence, not placement.
  Distinguish successful placement from endpoint binding, electrical network
  continuity, power, working state, output acceptance, and useful downstream
  production.
- `wait_for_item` observes only within its documented local range. Use bounded
  `wait_for_research`, component validation, and status waiting for meaningful
  transitions. `map_summary` is a diagnostic sample, never a timer. Never put
  repeated MCP observations in a host-language polling expression. After a
  syntax or schema failure, reconsider the higher-level intent as well as the
  malformed expression. While a wait is open, execute independent productive
  work through the same FIFO whenever available.
- A `validate_factory_component` plan step proves autonomy for one whole
  physical component: its 1-16 `positions` only identify the component (one
  exact node position is enough), and it samples the component for
  `duration_seconds` (long enough for several processor cycles). Its transfer window opens
  when the step starts, so queue it after a `wait_for_item` on the segment's
  terminal output, once bootstrap insertions are done and the segment produces.
  A failed preflight lists named blockers such as
  `relationship_diagnostic:belt_orientation_does_not_reach_consumer` or
  `relationship_diagnostic:downstream_inventory_blocked`; those are the next
  repair at that site, before anyone leaves it: the pilot clears
  `nonproductive_status:*` and `blocked_output`; Sol packages every other
  blocker, including fuel and input provenance, which need a physical feed.
- `mine` count means physical mining cycles, not guaranteed items. Recalculate
  BOMs, successors, fuel, and waits from actual accepted/produced quantities. Derive
  item ceilings from the in-game learned per-cycle yield and confirm them with
  actual inventory deltas after partial or unexpected results.

## Reporting and knowledge

Pilot reports to Sol are nonterminal and material, at most one per report
checkpoint, never one per tool call, and stay under about 300 bytes (the
connected transport rejects messages over 1,000 bytes). Before reporting, keep useful work queued or name the exact reason
no successor is safe. Include run/save identity, source tick, active and queued
plan IDs, what changed (accepted downstream output, new physical edges, measured
capacity or avoided touches, or the quantitative reason a short manual bridge
still wins), any falsified ledger assumption, and next intent. The pilot never
writes the ledger; Sol is the sole atomic host writer.

Follow [player knowledge v1](PLAYER-KNOWLEDGE-v1.md). Durable knowledge may hold
only in-game learned recipes, calculations, operations, and coordinate-free
relative layouts. Never persist map coordinates outside the current run's validated build
packages, copied layouts, external
blueprints, tutorials, online sequences, fixed build orders, named routes,
prescribed technology order, timed phases, or seed/map facts.

When an exact factor is unavailable, run only a bounded falsifiable experiment
with its uncertainty, predicted measurable effect, safe bound, numeric stop,
and observed outcome. An `MCP_GAP` blocks only the affected branch and names the
missing field and smallest structured addition; continue unrelated productive
work and never use screenshots or guesses as gameplay evidence.

The supported baseline is peaceful with enemy bases disabled. Concurrency
removes thinking idle time, never physical travel. `stop` is emergency
cancellation only, in the cases `AGENTS.md` lists. Candidate B and other multi-role/frozen benchmark procedures
are historical unless the owner explicitly starts a benchmark.

If a newly observed gameplay difficulty appears to require greenfield code,
perform one bounded Firecrawl reuse survey for a maintained compatible responsibility.
Check license, maintenance, current Factorio API compatibility, and
one-body/one-writer/text-only physical fit. Reject candidates that introduce
cheats, hidden map state, raw console access, imported blueprints, tutorial
sequences, another body, or another writer. Reuse or adapt the smallest
maintained compatible path; otherwise retain candidates only as design evidence
and patch the smallest existing active path. This is engineering guidance, not
a service, gate, or report workflow.
