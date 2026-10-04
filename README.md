# Factorio Codex

Current release: **0.20.0**.

Factorio Codex lets one Codex TUI control one physical character named Codex
through deterministic, text-only local perception. The only active path is the
project MCP server → serialized RCON bridge → Factorio mod. Movement, reach,
inventory, crafting, placement, research and elapsed game time remain real.

Requirements: Factorio 2.0.x with the Space Age expansion, Node.js 22.12+,
and a dedicated save. The fixed
`/silent-command remote.call` bridge means Factorio disables achievements for
that save. The interface never exposes Lua, arbitrary console commands, images,
global-map state, teleportation of the Codex body or free resources. Connected
spectator cameras follow Codex without affecting its physical movement. Every
supported save is permanently peaceful with enemy bases disabled. Play is
Nauvis-first: there are no rocket, space-platform, or planet-travel tools yet.

## Install and use

```sh
nvm use 22
npm ci
npm run build
node companion/dist/cli.js setup
node companion/dist/cli.js server create <run-dir>
node companion/dist/cli.js server start <run-dir> [--bind <lan-address>]
node companion/dist/cli.js server stop <run-dir>
```

Each run directory owns its fresh peaceful Space Age save, logs, PID, and a
run-local mod directory (base, elevated-rails, quality, space-age, and the
companion). `server start` verifies the mod protocol and version before
returning; `server stop` saves over RCON before shutting down.

The server-and-agent workstation has no dedicated GPU and is permanently
headless. Run only the dedicated server, Node bridge, and agent tooling there;
never start a Factorio GUI/client or any other visual GUI workload on it during
rollout, validation, or benchmarks. All visual workloads run on the couch PC.
There, install the full standalone Factorio Space Age build under
`%LOCALAPPDATA%\factorio-codex\standalone-space-age` and run the couch-only
`scripts/launch-native-client.ps1 -Address <server:port>` to connect its isolated
maximum-quality 4K client as the real player named `Codex`. Then connect the separate
normal couch Factorio client as the characterless spectator/follower. The
native launcher rejects the Steam build because Steam replaces the isolated
LAN identity with the account identity. There is intentionally no Linux visual
client launcher in this repository.
The mod never creates a standalone fallback character. Run
`node companion/dist/cli.js doctor`, then start `codex` at this root. The
committed project config starts MCP automatically. Begin with
`connect_status`, then `observe_local`. The pilot never calls `stop`, not for
ordinary gameplay, report checkpoints, turn endings, monitoring timeouts,
package changes, or routine plan recovery; it abandons a stalled wait by
queueing the corrective plan without `after_plan_id`, which runs while the wait
is parked, or else lets the wait's bounded timeout end it. Under `AGENTS.md`, the supervisor
alone uses this emergency tool for an explicit the owner stop, retained-work
reconciliation, or recorded emergency quiescence during replacement. A TUI
interruption alone does not authorize cancellation. `stop` takes `{}` and calls
`cancel` with `all:true`, cancelling active tasks, queued plans, and character
crafting; committed physical effects remain. Recover ordinary unexpected or
partial results from fresh structured state and exact known plan IDs, then
resume remaining safe work through the existing FIFO.

The built CLI supports `setup`, `doctor [--json]`, `mcp`, `server`, and durable `runs`
recording/comparison commands. MCP exposes exactly
25 text-only tools through `tools/list`. `observe_local` exposes exact
`ground_items` stacks and `pickup_items` physically collects one still-matching
stack through the character's normal picking state, or takes `count` items
from a plain transport belt at the given belt position as an exact conserved
transfer: with the body within `item_pickup_distance` of the belt's centre and
room for the whole count, exactly those items leave the belt tile's lines and
enter the main inventory; otherwise an honest refusal, never a partial spill.
A hand-mining result adds `drill_produced: true`, `drills` and
`stockpile_total` when own mining drills already mine that resource. Its character record labels
the existing `inventory` as `main` and reports equipped ammunition separately.
`queue_plan` immediately adds
one Lua-contiguous plan to the sole FIFO; both calls echo the stored
`after_plan_id`, and `plan_status` retains only assigned `queued`, first
`running`, first applicable `waiting`, and one truthful final transition after its
terminal result, even when a plan completes before its first poll. A bounded
`plan_status` wait returns on meaningful progress or terminal state without
canceling work on a monitoring timeout, while `run_plan` provides synchronous
compatibility. Plans reuse the existing honest physical runners, explicitly
report sequential nontransactional effects with no rollback, return inventory
deltas by default, and attach a compact or full local observation only when
requested.
`inspect_entity` reads any entity within 30 tiles and, beyond that, only
own-force entities in charted chunks, marked `remote: true`; a read that
includes any is `fresh_exact_local_and_charted_remote` (exact at its source
tick, readable, not reachable). Uncharted, foreign and empty remote positions
share one refusal. It reports live inserter endpoints and targets, mining-drill output
position, recipient (explicitly `null` when unbound), and a drill-only
`drop_target_bound` boolean, current drill resource targets, furnace
fuel/input/output buffers including exact empty compartments only when the
corresponding inventory exists, belt contents, and world-space fluid endpoints
with direction, filter, and connected-target evidence. `find_placement`
searches authoritative charted candidates, reports compatible mining-drill
resource coverage and ranks higher useful coverage before proximity, rejects
charted candidates with no compatible resources with a deterministic count
while retaining uncharted candidates with coverage omitted, and exposes
cardinal inserter pickup/drop endpoints plus rotated fluid endpoints. It
evaluates nearest positions first and stops at the requested candidates
(drills rank coverage among the nearest 2×limit valid positions), 2,048
position/direction checks, or 600 engine queries (`truncated`), which kept
every probed call, worst cases included, under 10 ms of game tick. Drill preflight uses collision-box point containment within 1/128 tile.
Inserter preflight intersects recipient collision boxes with the endpoint tile
inset by 12/256 tile, as isolated Factorio 2.0.77 probes establish. Each candidate carries
`plan_steps` for `queue_plan` (with fuel insertions when `fuel` is given), and
an empty result names one rejection reason per evaluation, the deepest
`closest_rejected`, and a `hint`, including the free-tile gap an inserter
needs between two endpoints. `can_place` reports batch overlaps and where each
output and pickup lands.
Output-capable candidates expose
their deterministic `output_position` and recipient, explicitly `null` for
ground output. Its existing `output_target` contract resolves the requested
recipient by exact entity position, derives the endpoint from prototype geometry
and direction, and applies the producer-specific recipient query above.
Multiple eligible matches are ambiguous. This search-time
geometry is provisional: it proves neither item acceptance nor runtime binding. Physical placement retains the exact created entity without
removing or replacing it; later-tick `pickup_target`/`drop_target` identity is
authoritative, even when a live endpoint differs from the prototype prediction.
A mining drill's nil `drop_target` is reported as pending first output, never as
bound; an unbound inserter or a non-nil wrong runtime target fails the requested
binding check.
For mining-drill `build_plan` steps with starter insertion, the items are
legitimately inserted once before the step waits for first output to expose the
exact runtime recipient. Inspect the placed inserter's
`pickup_target` to falsify an incorrect source binding.
Native no-path and repeated-stall failures inspect only the immediate charted
collision segment and report stable, capped local candidate identities and
colliding tiles as inferred visible collision candidates, not authoritative
blockers (or explicitly say none was identified); they never expand or search
the map. When the native path fails, up to 16 frontier probes (eight at 4
tiles, eight more at 8 tiles only when the first ring found no charted path)
each record a `frontier_probes` reason, and one `try_again_later` reply is
re-requested once. If the pathfinder refused every probe it answered (at least
one `path_failed`, none `timeout`, `transient` or `path_uncharted`) and an
owned collider stands in the local cage, the failure is `BODY_ENCLOSED`
(`failure_class` `PATH_NOT_FOUND`) with a `suggested_recovery` naming an owned
blocker to `mine`, one on the line toward the target first; otherwise it stays
`PATH_NOT_FOUND` with the probe reasons.
Embedded approaches use frontier recovery instead of ending on an occupied
entity centre. A successful walk or approach never finishes with the body on a
belt: it takes one bounded ordinary-walking step to the nearest charted clear
off-belt tile within 2 tiles (still within reach for an approach), reported as
the `walk_to` outcome's `settle`, or fails with `BODY_ON_CONVEYOR`, which leaves
the body on the belt until the next `walk_to` off it.
`observe_local.character.standing_on` names the conveyor under the body and is
omitted otherwise; recorder samples always state it, as `null` when absent.
`place_entity`, `build_plan` steps and `queue_plan`/`run_plan` `place_entity`
steps accept `belt_to_ground_type` (`input` or `output`) for underground belts
only (any other item fails before walking). `find_placement` accepts the same
optional field to select an explicit underground end, for example
`{ "item": "underground-belt", "preferred": { "x": 1.5, "y": 2.5 },
"directions": [4], "belt_to_ground_type": "output" }`. Every candidate retains
the selected end in its `build_steps` and `plan_steps`, which can be passed
verbatim to `build_plan` and `queue_plan`/`run_plan`, respectively. Omitting
the field preserves existing behavior. Placement geometry is provisional and
does not prove underground pairing; observe pairing after physical construction.
A placed underground belt reports its end and paired
neighbour (`outcome.underground`), or that no pair exists yet. Every read-only
result (`connect_status`, `map_summary`, `progression_status`,
`production_requirements`, `describe_prototype`, `observe_local`,
`inspect_entity`, `plan_status`, `can_place`, `find_placement`) carries
`fifo` with `active_plan_id`, `queue_depth` and `idle_seconds` from the same
read (in `describe_prototype`, whose rows are keyed by prototype name, `fifo`
is that state, not a prototype); after more than 30 idle seconds it adds the `hint` "body idle: queue
bounded work before further reads" and leads its text with it. The read-only
strategist, which cannot queue, sees the hint too. Each `fifo` block and
`observe_local.character` also state `human_control` and `human_idle_ticks`:
while the connected Codex player, in its character, has given real control
input (movement, mining, building, opening a GUI, holding an item) within the
last 300 ticks (about 5 s), the FIFO is parked (no step starts or ticks, no plan is
cancelled or reordered, `queue_plan` still queues) and the hint becomes a
human-control notice; mouse hovering, map view and camera movement never park
it; a step that depended on the body position re-plans from
where the body then stands. `plan_status`, `run_plan` and `queue_plan` results
carry `human_control: true` when a hold delayed the plan, which is neither
idleness nor failure. Placement checks share exact collision geometry and explicitly reject
the Codex body footprint. If a route begins inside a collision, Codex uses
ordinary walking toward Factorio's bounded nearest clear position before
requesting a new native path. Partial inserts fail with requested, moved, and
remainder counts; waits report their observed start/current/delta; recovering a
fluid-filled owned machine requires explicit `allow_fluid_loss=true` and reports
what ordinary dismantling discarded.
`map_summary` summarizes only already-charted terrain and factory landmarks.
Its optional `include` list adds capped top-level sections, each with an
omission count, for own-force entities and resources in chunks the force has
charted on the character's surface:

| `include` | Output key | Content | Cap |
| --- | --- | --- | --- |
| `stockpiles` | `stockpiles` | per item: `total` and `holders` (chest, machine output, belt run) with positions | 64 items, 8 holders each |
| `sites` | `sites` | per charted chunk: own machine counts and a position, independent of the landmark cap | 256 |
| `patches` | `patches` | resource patches with `amount`, `tiles`, `bbox`, `centroid` | 64 |
| `power` | `power.networks` | production, consumption, capacity (W), satisfaction, accumulator charge, producers, consumers | 32 |
| `problems` | `problems` | machines with `no_power`, `low_power`, `no_fuel`, `full_output`, shortages or no resources; dead machines (no power, no fuel) before input waits | 64 of `problems_total`; `problems_by_status` counts every problem |
| `flows_all` | `force_flows_all` | per item and fluid: per-minute and lifetime produced and consumed | 256 |

Limits: charted-force scope replaces the earlier no-remote-inventory rule.
Nothing is read from uncharted chunks or other forces, no read charts terrain,
and reading is not reach: every mutation keeps its walking and reach checks.
`production_requirements` performs deterministic recipe arithmetic, and
`connect_entities` builds an inventory-backed physical belt, pipe, or power
route.
`progression_status` separates ordinary queueable research from action/trigger
unlocks, retaining item/entity quality filters and comparators, scripted trigger
descriptions, and fieldless space-platform triggers. `start_research` refuses a
trigger technology with its required in-game action and never reports it as
queued progress.

Live play is currently supervised debugging, not benchmarking. The initiating
session may inspect, intervene, modify, rescue, and restart the run through its
separate debug surface. Every intervention is recorded and assisted progress is
never benchmark evidence. Ordinary gameplay uses exactly two persistent
reasoning sessions around one physical body and one FIFO mutation lane. A
`gpt-6-luna` pilot with `low` reasoning and fast mode enabled is the sole
gameplay writer, character controller, immediate-safety authority, and source
of latest exact local state. A persistent `gpt-6-astra` strategist with `medium`
reasoning at normal speed owns compact NOW/NEXT/LATER priorities, designs every
coupled layout as a validated build package that the pilot revalidates and
queues unchanged, and may use only the separate mechanically read-only MCP
surface (which includes the side-effect-free `can_place` and `find_placement`). Its observations never enter the physical
lane. Astra atomically writes the one `operations.json`, including its initial
revision (`ledger-apply` with an `init` envelope), and it is Astra's only channel
to the pilot; Luna never writes it and continues fail-open when advice is
absent, malformed, stale, or unavailable. A task-list `essential_prerequisite`
is one outcome sentence of at most 160 characters. Each run has an
markdown notebook at `<run_dir>/notebook/` with one folder per role
(`notebook/astra/`, `notebook/luna/`): each role writes its own folder and reads
either at any time, including exact positions, maps and infrastructure lists
observed in that run, and keeps a short `INDEX.md` there; nothing is imported
or carried to another run. A build
package may name up to three `notes` (paths that `ledger-apply` requires to
exist beside the ledger). The ledger stays the only command channel. A queued or standing package
stays in the ledger until Astra's next publish replaces it. A package that
extends a proven component re-validates the joined component, and Astra
reuses its own proven notebook template at a new anchor after one `can_place`
batch. When input rate stays flat for two report checkpoints while plates
accumulate in buffers, NOW returns to extraction and smelting funded from
those buffers; hauling finished plates or hardware to a build site is capital,
not service. The pilot passes `after_plan_id` only when a plan needs its
predecessor's effects, because a chained successor is cancelled when its
predecessor fails, times out, or ends partial; independent work queues
unchained and runs while a wait or validation is parked. Until the first
package arrives it gathers only within 30 tiles of its `GO` position or of the
site NOW's `essential_prerequisite` sent it to, skips a package whose
placements already stand as specified, and takes what it can use from its own
chests, furnaces and belts (a full terminal buffer included), unloading surplus
only into an existing chest or line. Taking stock is normal play at any time
except from a component whose validation window is running; a proof speaks
only for its window, and a later take from a furnace or machine inside a
proven component (or any deposit, or any transfer on a power component) leaves
a stale proof (`character_transfer_observed`) that the next validation renews. Neither role calls
`list_threads`, `read_thread`, or `wait_threads`, and after a context
compaction each re-reads its goal file and `SKILL.md` first.
Neither role profile is applied to an active run in place. The
repo-local `factorio-player` skill holds only the hard rules both roles obey
(`SKILL.md`), a short Factorio intro whose hints evidence may override
(`PLAYER-KNOWLEDGE-v1.md`), and one goal file per role.

Start the foreground recorder immediately before gameplay begins. It takes a
successful native baseline before printing `GO`, then records cumulative and
run-relative resources plus diagnostic factory context every five minutes of
wall time. Stop it with Ctrl-C at the run boundary; that signal captures one
final sample and closes the manifest.

```sh
factorio-codex runs record --ledger operations.json \
  --variant guidance-v2 --change "expand measured bottlenecks before manual batches" \
  --kind debug
factorio-codex runs mark-assisted <run-id> --reason "supervisor teleport recovery"
factorio-codex runs compare <baseline-run-id> <candidate-run-id>
```

Records live under `~/.local/share/factorio-codex/runs/`. A run manifest keeps
the role profiles its run recorded, so runs from earlier role pairs remain
readable and comparable. Debug and assisted
runs remain available for descriptive comparison but are excluded from an
automatic benchmark verdict. Clean benchmark runs from the same baseline save
receive a conservative resource-vector verdict at each common five-minute
checkpoint; mixed resource tradeoffs are never collapsed into one total score.

After immediate safety and a hard production unblock, the pilot evaluates the
highest-payback expansion of the measured factory bottleneck before another
manual deficit batch. It uses current utilization, buffers, WIP, service time,
power headroom, unlocked demand, and measured deltas; proves capacity through
accepted downstream flow; then reassesses the new bottleneck. Repeated manual
crafting, fueling, hauling, or one-machine service triggers an automation
payback comparison. The pilot prefers evidence-backed headroom, clustered
travel, and buffer-aware packets over exact next-task quantities. Growth is
input first: raw extraction, smelting, fuel and power stay ahead of demand,
progress is judged first by input rate (ore and plates per minute), and science
is never hand-crafted to push research while raw input is the bottleneck. This
is a principle, not a build or technology order. In `map_summary`, use
`factory.force_flows[].produced_per_minute` and `consumed_per_minute` for
achieved rolling throughput: Factorio production statistics call production
`input_rate` and consumption `output_rate`; the aliases preserve those values
and their precision window. Mining groups' `theoretical_items_per_minute` is
installed nominal capacity, summed per drill as
`60 * prototype mining speed / current resource mining time * item yield`.
It excludes speed and productivity bonuses and ignores idle, fuel-starved or
output-blocked duty time. Only deterministic positive item yields are supported
(fixed amounts, including equal minimum/maximum amounts, with probability one).
Fluid extraction, variable yields and missing or invalid target facts leave
capacity unavailable; a group with only some evidenced drills is incomplete
and has no total. Read `capacity_state` and `evidenced_drill_count` alongside
`capacity_basis`. A complete group total divided by its drill count is an
average per-drill estimate; mixed resources can have different individual
capacities. Theoretical capacity never proves achieved throughput or autonomy.
Exactly one
physical call may be in flight; only read-only snapshots may overlap when their
tick inconsistency is acceptable.

`production_requirements` treats mined resources and offshore-pump fluids as
raw roots unless `recipe_choices` names a recipe, and never routes through hidden
recycling recipes. It also accepts one technology or space-location target.
It derives missing current-force prerequisites, remaining science, trigger
conditions, permitted locked-recipe arithmetic, bounded force-flow rates, and
time estimates while separating probabilistic or operational requirements and
never crediting exact remote inventories.

Debug runs record the `GO+20m` recorder checkpoint as a comparison snapshot
without stopping anything, then continue to their assigned milestone unless
The owner stops them; Candidate B and R1-R7 remain historical evidence. Gameplay
remains text-only and physical. See the repo-local `factorio-player` skill for
the current contract and [agent play performance](docs/AGENT-PLAY-PERFORMANCE.md)
for historical evidence.

`map_summary` computes connectivity, components, provenance, diagnostics,
production counters, signatures, transfer attribution and autonomy over every
eligible existing player-force entity in already charted chunks. Presentation
alone is capped: 12 nodes, 24 edges, 24 diagnostics and 8 components. Each
component returns at most 12 node IDs and 24 blocker names, with nested omission
counts; `factory.omissions` counts omitted graph rows. These omissions make the
presentation partial, not the physical evidence incomplete. Uncapped
whole-graph counters sit beside the rows on `material_flow`:
`component_count`, `edge_count` (every edge, `electrical_dependency` included,
so it equals the shown edges plus `omissions.capped_flow_edges`),
`autonomous_component_count`, `validated_component_count` (components with a
retained proven validation of their current topology) and
`products_finished_total`; recorders and measurements read these, never sums
of the capped rows. Exact component
sampling for `validate_factory_component` resolves 1–16 caller-named positions
against the complete graph, including nodes and components absent from the
response. Missing and ambiguous selections retain their target errors. A
split-component selection terminates validation with a failed step whose
`result` contains `code: "FACTORY_COMPONENT_SPLIT"`, `stage: "selector"`, and
`component_signatures_by_position`: an array in requested position order,
including duplicates, of `{position: {x, y}, component_id, component_signature}`.
Every row identifies the exact complete-graph component at that position.
This failure also applies when a later validation sample observes a split;
validation performs no physical action or inventory transfer, and later plan
steps do not execute. Earlier committed steps retain their effects.

Blocker rows are classed and located. `structural` rows describe the build
itself (a missing edge or path, inventory-proven `blocked_output`, or a raw
status such as `no_minable_resources`, disabled or unplugged); `transient` rows
are single status samples such as `insufficient_input`, `full_output`,
`no_fuel` or `no_power` waits; `evidence` rows (ambiguous relationships, and
in validation outcomes character transfers or a topology change) call for local
inspection; in validation outcomes, `throughput` rows name window counts that
fell short. Only non-transient names enter
`autonomy_blockers`, and each component adds up to three `blocker_details`
rows, one per distinct position, with `reason`, `class`, `position`, `entity`
and `related_edge`. A belt run is the tiles joined by `belt_direction` edges,
including an underground entrance to its exit; a consumer may pick up anywhere
along it, through an inserter pickup or a `loader_container` edge. Only a run
with no such outgoing edge reports `belt_dead_end_without_consumer`, at its
last tile. Factorio binds a mining drill's `drop_target` only at its first
output, so a drill whose `drop_target` is still nil while exactly one charted
recipient of its force covers its drop position and can take a mined product
(a conveyor, or a recipient whose native `can_insert` accepts it) reports the readiness row
`drill_output_target_pending_first_output` (class `evidence`, `related_edge`
`{kind: machine_output}`) instead of `output_has_no_physical_sink` and
`downstream_acceptance_path_unproven`; it still proves no path, so validate
after the first output. A burner inserter's `fuel_input_provenance_unresolved`
row carries `related_edge.transport_cargo_fuel: false` when the cargo it moves
is known and none of it burns in its fuel categories: it needs its own fuel
feed or an electric replacement. The field is absent when the cargo is
unknown, such as from a hand-stocked chest.

Component state and validation evidence carry `downstream_kind`: `buffer`,
`consumer`, `mixed` or `none`. A buffer stores output; it is not a consuming
sink, and its stock never proves an upstream production source. The agent
chooses whether buffer-ended capacity fits the current game stage. A buffer is
terminal when nothing leaves it, or when everything that leaves it only refuels
producers upstream of it (a self-fuelling coal drill's chest). A full or
otherwise nonaccepting terminal buffer or consumer reports `blocked_output` and
cannot claim current `autonomous_end_to_end`; a full intermediate buffer is
ordinary backpressure judged by throughput, and a `full_output` status sample
alone does not prove blocked output. Unsupported acceptance remains unproven.

A narrowly proven fuel-replenishment branch may wait without blocking useful
material output. Its inserter keeps normalized `status=full_output`; the node's
`fuel_return_saturation` records the exact destination, fuel and quality,
observed `waiting_for_space_in_destination`, and evidence kind. The existing
`downstream_inventory_blocked` diagnostic remains visible with
`nonblocking_reason=proven_fuel_return_saturation`. This distinction requires
exact runtime pickup/drop relationships and upstream production of the identified
fuel, compatibility with the working destination burner, remaining burning
energy, matching stocked fuel, and supported fuel-inventory space for that
quality. Destination compartment evidence requires a mining drill or successfully
observed recipe ingredients. A held fuel that is also a destination recipe
ingredient remains ambiguous. No stock threshold is hard-coded. Missing or
incompatible evidence, inventory-proven `blocked_output` and unrelated
structural relationship diagnostics still block; other `full_output` samples
are transient. In particular,
`belt_dead_end_without_consumer` remains effective.

`identity_source=held_stack` uses a readable held item. When the stack is empty,
`identity_source=burning_and_stocked_fuel` instead requires exactly one stocked
item/quality pair matching the currently burning pair. Empty-stack names and
qualities are never read. These are supported Factorio 2.0 APIs:
[LuaBurner.currently_burning](https://lua-api.factorio.com/2.0.72/classes/LuaBurner.html#currently_burning),
[LuaInventory.get_contents](https://lua-api.factorio.com/2.0.72/classes/LuaInventory.html#get_contents)
and [LuaItemStack.valid_for_read](https://lua-api.factorio.com/2.0.72/classes/LuaItemStack.html#valid_for_read).
Conflicting or multiple stocked pairs remain unproven. During a validation
window every sampled burner's stored fuel must stay readable; an unreadable
fuel inventory fails the window with `fuel_stock_unreadable` (class `evidence`)
at that burner.

This distinction clears only the branch's output blockers; it never establishes
`autonomous_end_to_end`. The existing bounded production, downstream acceptance,
topology and complete character-transfer history requirements still apply.

An inserter's `waiting_for_source_items` snapshot is normalized as
`insufficient_input` and stays visible as a `transient` row; one sample never
fails preflight or revokes a validated proof. An inserter still waiting for
source items at the end of the window for longer than the path recency limit
(the stall interval, or the last third of a shorter window) carried nothing
there, so downstream growth beyond it came from stock: the window fails with
the located row `transport_starved_before_end` (class `throughput`,
`related_edge` `inserter_pickup`). One early swing does not clear it. A
fuel-only feeder, whose pickup is proven to supply only fuel for the burner it
feeds and no recipe ingredient, and which is that burner's only physical fuel
inlet of any provenance (an inserter from a hand-stocked chest counts), is
neither starved nor nonproductive in a sample where that burner still holds its
top-up stock of five items, so a lazy furnace or drill fuel feeder that swings
less often than the recency limit does not fail a healthy loop. Once the
burner's draw below the top-up stock stays unanswered past its refill bound,
the feeder's whole wait counts as starved, so a dead feeder or source still
fails although stock hid its wait; a competing inactive feeder is never
excused by another inlet's refills. A burner with two supplied fuel feeders
excuses neither: the one that never swings cannot be told from a dead return,
so give a burner one fuel inlet. It is not raised when the inserter's drop target already carries an evidence row
naming a longer window, because a takeoff later in belt order waits while the
burners ahead of it fill. Window samples alternate 29 and 28 ticks apart, so a
short swing is not aliased away against 60-tick machine periods. A sample whose
component signature or hard rows differ from the window's baseline is re-checked
one sample later and ends the window only when the difference persists; a
recovered one is listed first in `transient_conditions` as
`topology_sample_flicker` (with `samples` and `first_tick`). A persistent
signature change ends the window with
`component_topology_changed_during_validation` and a `topology_diff` of at most
four removed and four added component rows (plus an `omitted` count). Within a
window, a drill whose `mining_target` reads nil keeps the products it last
mined.

`validate_factory_component` uses the existing parked plan step to sample a
bounded 1–300 second unattended interval. Its preflight is topology only. When
the first sorted row is a readiness row (unresolved fuel provenance or
compatibility, a missing source-to-downstream or downstream acceptance
path, a furnace that has not smelted yet, a lab with no research in progress
(`consumer_idle_no_research`) or whose research needs a pack the segment
never supplies (`consumer_missing_required_science_pack`), or an electric consumer whose supply is not
proven (`power_supply_component_not_proven`)), the step is refused at once with `FACTORY_COMPONENT_NOT_READY`,
`stage=readiness`, `refused=true` and located rows naming what to build; any
other structural or evidence row fails `stage=preflight`. The window judges
throughput, not single status samples. It requires unchanged physical
relationships and recipe identities, complete transfer history, proven material
and fuel supply, at least three cycles for every processor present, three
observed cycles for every source and three downstream acceptance samples per
output item at each endpoint. A source whose output only refuels other
producers runs at their burn rate (about one coal per 27 s per burner drill):
one cycle suffices while every producer it fuels shows three, and it is
reported as `fuel_source_cycles_observed` instead of lowering
`source_cycles_observed`. When none of its consumers fell below the top-up
stock, or their draws were met from fuel already downstream while it sat
output-blocked, it reports `fuel_demand_not_yet_exercised` (class `evidence`,
with `suggested_duration_seconds`) instead of a cycle shortfall; one seen out
of fuel, power, resources or enabled state keeps the throughput row. An idle furnace keeps its output identity from
`previous_recipe` (whose 2.0 name reads back as a prototype object); one that
never crafted has none. With material arriving from an upstream producer that is
the readiness row `furnace_recipe_not_yet_established` (class `evidence`): start
the window after its first smelt. Without a material feed it stays the
structural `output_identity_unproven`. Waits never fail a window. Once nothing has
progressed for 20 seconds, a source or processor that is nonproductive in at
least 90% of at least three samples since the last progress ends the window
early with `persistent_nonproductive_status:<status>`; a producer out of fuel,
power, resources or enabled state carries that row ahead of producers that only
wait. A window never ends proven once it has stalled (`progress_stalled`, kept
even when progress later resumes). Independently of any stall, a source,
transport or processor out of fuel, power (low power included for sources and
processors), resources or enabled state in at least 90% of the window's
samples (an inserter on an unpowered pole island, say), or still in one at the
end for at least 180 ticks (and three samples), fails it with
`persistent_nonproductive_status:<status>` at that node; a burner out of fuel
no longer than its refill bound below is waiting for a refill. An inserter or
belt on `low_power` still moves items, so its throughput, not that status,
decides. Each endpoint, each
processor and each source that is not fuel-only that met its count must still
have accepted, finished or mined something within four of its own observed
event periods before the end, and within the stall interval (the last third of
a shorter window), or the window fails with `path_stalled_before_end` at that
node and its `last_event_tick`, so one branch that keeps moving cannot hide
another that stopped. A burner
producer that consumed fuel (stored energy fell, the burning remainder
included) must be seen refilled. Consumption below the top-up stock of about
five items with no refill for longer than its supply bound is a starved fuel
return (`fuel_replenishment_not_observed`, with `fuel_items` and
`fuel_draws`). The bound is the longest of 180 ticks, the longest supply
interval its return has already shown plus one sample while the burner kept
demanding, and one nominal mining period of its fuel source (its observed
cycle interval when the prototype gives none) for every burner sharing that
source, plus 180 ticks; a younger draw at the end is still in flight. A fuel
loop must also sustain itself: when the observed burn rate of every burner a
source fuels (split evenly among each burner's sources) exceeds what that
source mines at full duty, the window fails with `fuel_supply_deficit` (class
`throughput`, with `fuel_demand_watts` and `fuel_supply_watts`) at the source,
whatever starter stock or loaded returns carried the window. A burner whose starter stock kept
it at or above the top-up stock, so that no refill was yet due, reports
`fuel_return_not_yet_exercised` (class `evidence`, with `fuel_items` and a
`suggested_duration_seconds` from its observed burn rate): starter fuel cannot
stand in for a fuel loop, and this is not a fuel-edge defect. When that
projection exceeds 300 s it reports `fuel_return_beyond_window` (class
`evidence`, with `projected_seconds`) instead: take its starter fuel down to two
or three items, then rerun. A burner past its supply bound that never ran out
while the other burners on its source were refilled and gained stock, none of
them out of fuel, is behind a loop still converging in belt order:
`fuel_return_not_yet_exercised` with a `suggested_duration_seconds`, not
`fuel_replenishment_not_observed`. A supplied
return inserter seen during the window holding compatible fuel and waiting at
that working burner (the `supplied_working_burner_with_fuel_inventory_space`
evidence) is the return already loaded and counts as exercised. Starter stock
in an intermediate buffer cannot carry a window either: a non-terminal buffer
whose stock of an item fell with no observed inflow fails
`intermediate_buffer_draining` (class `throughput`) at that buffer, and a
furnace or assembler whose input stock fell with no observed inflow fails
`processor_input_draining`, so do not hand-insert input packets larger than a
few crafts before a window. A non-terminal buffer that is not fuel-only and
gained stock with no release within the stall interval (the last third of a
shorter window) before the end fails
`intermediate_buffer_outflow_not_observed`: its outlet is dead. A terminal fuel
buffer that only receives the surplus behind fuel takeoffs on its supply line
and saw no acceptance while a burner it sits behind was refilled and gained
stock reports `surplus_fuel_endpoint_not_yet_reached` (class `evidence`, with
`suggested_duration_seconds`) instead of an acceptance shortfall. Bootstrap burners
with at most two or three fuel items when a fuel return exists, and size
windows to cover one fuel item per burner (a burner drill burns a coal in about
27 s, a stone furnace in about 45 s at full duty and proportionally longer
below it). Buffer acceptance requires increases
in each matching output stock across distinct samples; a working consumer
must also accept every relevant output through its native input inventory
at each counted sample. Supported item probes use lab input or burner-generator
fuel inventories. A lab with research in progress, whatever its status, must
have every pack that research needs supplied by the segment (a lab fed by an
inserter from another lab is supplied through it); otherwise it is
refused at readiness as `consumer_missing_required_science_pack`, so
hand-stocked packs never stand in for a missing pack line. A lab waiting for
packs (`missing_science_packs`) accepts whatever its input inventory can still
insert, but a lab's acceptance counts only from its first `working` sample in
the window. A lab with no research in
progress accepts nothing, so research must be active before a lab-ended
segment is validated, and a lab left without research mid-window ends it. Native thermal generators and terminal storage tanks support
fluid acceptance; other consumer types remain unproven.
The retained graph also supports native offshore-pump supply, separate-pipe
boiler transformation, pipes (including underground connections), pumps (one
box carrying both connections, outside any segment, as in 2.0.77),
thermal generators, and terminal fluid buffers. Identities come from
[Factorio 2.0.76 runtime/prototype evidence](https://lua-api.factorio.com/2.0.76/runtime-api.json):
the offshore source tile's fluid, runtime fluidbox filters and temperature
constraints, boiler mode/target temperature, and generator heat requirements.
Connections retain both fluidbox indices and native flow direction. Box
prototypes are read with `LuaFluidBox.get_prototype(index)`, accepted only as a
single prototype with a readable production type and filter. Only valid,
same-force targets on the current surface in charted chunks participate;
unsupported machinery, merged boxes (an array of prototypes), unreadable
prototypes or unreadable connections stay unproven.

Electrical dependency is not a material path. `electrical_dependency` edges stay
in the presented `material_flow.edges` but never join components, count in a
component's edges or signature, transport items/fluids, satisfy ingredients or
fuel provenance, or substitute an unrelated endpoint for material acceptance.
A consumer keeps its own material component, and the generators sharing one
network form one power component. A consumer whose network's generators sit in
another component carries the located readiness row
`power_supply_component_not_proven` (class `evidence`, `related_edge`
`{kind: electrical_supply}`) until that component is proven: a retained
validation of its exact topology, no character transfer into it since that
validation began, and still generating. The supply is judged on run history,
so a later window or an `activity_since_tick` checkpoint still sees it; its
latest proof is kept per exact topology and its last transfer tick per target,
so eviction of unrelated validations or transfer events never revokes it. A consumer's window also samples the burners and feeders of
every component that supplies it, directly or through another supply, with its own nodes, so a supply burning stored fuel
behind a dead refill fails that window (`fuel_replenishment_not_observed`,
`transport_starved_before_end`); their refill bound uses the supply's fuel
sources as in its own window, and a supply burning faster than those sources
mine fails it with `fuel_supply_deficit`. A supply powered by another supply
is judged after it; supplies that power each other stay unproven. An electric component with no fluid nodes is
proven without fluid samples. An
idle or unpowered line on the network neither fails nor merges with the plant. Three bursts of consecutive ticks inside the existing
1–300 s parked validation window collect native pump movement and generator
output; sparse gaps are never integrated. A burst lasts 120 ticks, but never
more than a third of the window (`duration_seconds` × 20 ticks): a saturated
steam domain shows only the engines' draw, so a light load needs long bursts.
The floor for a boiler proof on a saturated domain is a steady draw of about
15 kW per segment of its steam domain at `duration_seconds` 7 or more (each
inline pump adds a segment; three full bursts and their gaps do not fit 6 s),
and more than about 90 kW per segment at 1 s, 45 kW at 2 s or 30 kW at 3 s. A
boiler still short of its reserve only in a shortened burst (a shorter window,
or a burst clamped after a recovered flicker) while its input domain held is
reported as evidence-class `bounded_fluid_activity_not_observed` with
`suggested_duration_seconds` 7, or one second more than a window of 7 s or
longer; a 300 s window, or a draining input, gets the throughput row instead;
validate a steam plant while its consumers work. Each boiler needs three
uniquely attributable output mass balances with actual fuel consumption and
non-draining water input. Balances run over fluid domains: a segment, plus any
box outside a segment joined to it by a proven pipe connection (in 2.0.77 the
offshore pump output, the boiler's steam output and a pump's single box report
no segment and hold their own stock, so a pump joins its two neighbouring pools
into one domain where its draw and feed cancel; a pump box inside a segment is
refused). Each pool is counted once; a segment's capacity sums its member
boxes, since `get_capacity` is per box, and a segment's contents include every
member box. The balance reserves one fluid unit per member segment, guarding
the documented uint32 segment contents (2.0.77 returns fractional stock, so the
reserve is conservative), and subtracts measured pump inflow; the input and
whole-window draining checks allow the same rounding. A domain that changes
identity during the window, or is shared by several boilers, remains unproven.
Boilers must also exercise actual fuel replenishment. Pumps and generators
need repeated activity and per-path recency; none receives fabricated mining
cycles or crafting counters.

Whole-network native generation increments (the network's output counts) must
match the sum of the observed generators' actual output in each sampled tick,
including when several generators share a name. In 2.0.77 those counts lead
`energy_generated_last_tick` by one tick, quantize each increment to 1/65536 J
and carry each tick's flow at float32 precision, so the comparison is aligned
and allows those roundings only. Unknown suppliers,
accumulator discharge and counter resets are unproven. An input-only electrical
material participant must show actual buffer use and at least three delivery
events, rather than shared network identity or working status alone: a buffer
recharge, or, since a supplied buffer can read full every tick, a positive,
nondecreasing buffer under a positive native drain, or on a working drain-free
consumer (2.0.77 electric mining drills) while its network's consumption for
its prototype rose. Exact electrical
dependents outside the plant's material paths contribute the same private
delivery observations without joining its component, and their blockers name
the dependent's entity and position. A full buffer on an idle drain-free
consumer is never delivery; an external dependent idle throughout at such a
buffer neither proves nor blocks its supplying plant. Fluid endpoints require compatible identity/temperature and segment
capacity, with actual generator activity or distinct buffer arrivals; an engine
that generated last tick accepts even at a full segment, since a pump refills
its segment to exactly full after it consumed. Draining
fluid or electrical stores, incomplete transfer history, character transfers,
changed entities/connections/constraints/network bindings and stopped branches
refuse proof. Current native autonomy revokes when pump/generator activity or
consumer energy fails. A generator on standby is the exception: its own box holds
compatible steam above the fluid's default temperature and every material
consumer on its network is `idle`, `insufficient_input` or `full_output` with a
charged buffer, so it serves at most their constant drain (other consumers on
the network, such as lamps, are not sampled). No demand is
neither an interruption nor `blocked_output`, so standby keeps current
autonomy, but a validation window still counts acceptance only on real
generation. Presentation caps never limit private validation.

Drill source cycles use a mining-progress
wrap accompanied by depletion of the
same already charted target. Adjacent sampling intervals vary the phase to
reduce cadence aliasing. Shared-target attribution, unavailable counters or
remaining sampling aliasing stay unproven; longer duration alone need not resolve
every alias.
[Factorio's API](https://lua-api.factorio.com/2.0.72/classes/LuaEntity.html#mining_progress)
provides drill progress; `products_finished` applies to crafting machines.
Source-to-transport-to-buffer or consumer segments need no processor. Their
source and acceptance proof requirements are identical, and a successful
source-only interval may report `products_finished_delta=0`. A source's own
compatible fuel product proves replenishment only through a directed physical
return path with exact runtime bindings; compatible output or starter fuel
stock alone does not suffice. Topology readiness and local operation precede
bounded proof and never establish `autonomous_end_to_end` on their own.
Private inventory/resource samples and exact internal identity strings are never
returned, except the bounded readable `topology_diff` rows of a persistent
topology change. Validation returns `stage` (`readiness`, `preflight` or `window`),
aggregate production deltas, `source_cycles_observed`,
`fuel_source_cycles_observed` when a fuel-only source was judged by its
consumers, native `native_source_activity_samples`, `fluid_activity_samples`,
`power_delivery_samples`, `mining_sources_present` and `native_power_required`
when applicable, `downstream_acceptance_samples`, `samples_observed`,
`last_progress_tick`, and located blocker rows (`reason`, `class`, `position`,
`entity`, `related_edge`, plus `last_event_tick`, `fuel_items`, `fuel_draws`,
`fuel_demand_watts`, `fuel_supply_watts`, `suggested_duration_seconds` or
`projected_seconds` where
they apply), readiness first, deduplicated by reason and position, at
most 12 with an `omitted_blockers` count, and `topology_diff` when the final
signature differs. Up to eight `transient_conditions` rows report waits and
recovered topology flickers that did not fail it.
Serialization omissions alone do not reject validation. Character transfers,
changed topology, persistent missing fuel or power, no production or unobserved
downstream acceptance do reject it. A prior proof also loses current autonomy
when a disallowed transfer or blocked output appears, or when a source or processor is
at `no_fuel`, `no_power`, `no_resources` or disabled
(`validated_producer_nonproductive`); input and output waits do not revoke it.
An electric consumer's component is current only while its power component is
currently proven. Offline fixtures establish source behavior only; deployment and live supplied
steam-power autonomy remain unverified. Release 0.19.7 called a fluidbox
method absent from Factorio 2.0.77 that its mocks supplied, so each
fresh run now passes the native steam gate in
[live validation](docs/LIVE-VALIDATION.md#live-steam-gate-before-go) before
`GO`.

After successful unattended validation, extracting only accepted products from
that matching component's terminal downstream buffer strictly after the
validation end tick retains its bounded autonomy proof while downstream capacity
and the other current autonomy conditions hold. Harvesting remains character
work: raw transfer actions and extracted-item counts include every harvest.
It never establishes proof or exempts transfers during a new validation window.
Insertions, extractions from processors or intermediate buffers, unrelated items,
and mixed transfers containing any disallowed item revoke current autonomy.
Transfer history must be complete from the matching component's validation start
through the current observation. Evictions strictly before that start do not
invalidate a later proof; an eviction at or after the start, or an unavailable
eviction boundary, leaves it unproven. Aggregate transfer counts and
`character_transfers.history_complete` describe the requested
`activity_since_tick` window (the whole run by default), which may differ from
the component's proof interval. A narrower telemetry window cannot hide
post-proof assistance. Unvalidated components and new validation samples still
require complete history for their assessed windows.
A power supply's proof, which its consumers' components and validation windows
rely on, is kept per exact supplying topology past validation eviction and is
revoked by any later character transfer into that supply, harvesting included,
using a per-target last-transfer tick that survives unrelated event eviction.
Electrical dependencies no longer join components; a terminal buffer still
belongs to its material-flow component, so the harvesting exception still
applies. These are sampled bounded
claims, not a guarantee about every intervening tick or unlimited future demand.

## Verification

```sh
npm ci && npm ls --all
npm run typecheck && npm run build && npm test
npm run test:mcp && npm run test:mcp:built -w companion
npm run package:mod
```

See [live validation](docs/LIVE-VALIDATION.md) for the Factorio-only acceptance
run and [UPSTREAM.md](UPSTREAM.md) for provenance.
