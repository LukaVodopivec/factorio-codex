# Factorio Codex

Current release: **0.19.1**.

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
low-resource client as the real player named `Codex`. Then connect the separate
normal couch Factorio client as the characterless spectator/follower. The
native launcher rejects the Steam build because Steam replaces the isolated
LAN identity with the account identity. There is intentionally no Linux visual
client launcher in this repository.
The mod never creates a standalone fallback character. Run
`node companion/dist/cli.js doctor`, then start `codex` at this root. The
committed project config starts MCP automatically. Begin with
`connect_status`, then `observe_local`; `stop` cancels active and queued work.

The built CLI supports `setup`, `doctor [--json]`, `mcp`, `server`, and durable `runs`
recording/comparison commands. MCP exposes exactly
25 text-only tools through `tools/list`. `observe_local` exposes exact
`ground_items` stacks and `pickup_items` physically collects one still-matching
stack through the character's normal picking state. Its character record labels
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
`inspect_entity` reports live inserter endpoints and targets, mining-drill output
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
every probed call, worst cases included, under 10 ms of game tick. An endpoint binds when it lies in the recipient's
collision box within 1/128 tile, the rule a Factorio 2.0.77 probe of flush
burner drills and inserters reproduced exactly. Each candidate carries
`plan_steps` for `queue_plan` (with fuel insertions when `fuel` is given), and
an empty result names one rejection reason per evaluation, the deepest
`closest_rejected`, and a `hint`, including the free-tile gap an inserter
needs between two endpoints. `can_place` reports batch overlaps and where each
output and pickup lands.
Output-capable candidates expose
their deterministic `output_position` and recipient, explicitly `null` for
ground output. Its existing `output_target` contract resolves the requested
recipient by exact entity position, derives the endpoint from prototype geometry
and direction, and requires that exact point to lie within the eligible entity's
`bounding_box` closed by the probed 1/128-tile tolerance. This search-time
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
the map. Placement checks share exact collision geometry and explicitly reject
the Codex body footprint. If a route begins inside a collision, Codex uses
ordinary walking toward Factorio's bounded nearest clear position before
requesting a new native path. Partial inserts fail with requested, moved, and
remainder counts; waits report their observed start/current/delta; recovering a
fluid-filled owned machine requires explicit `allow_fluid_loss=true` and reports
what ordinary dismantling discarded.
`map_summary` summarizes only already-charted terrain and factory landmarks,
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
of latest exact local state. A persistent `gpt-6.1-sol` strategist with `medium`
reasoning at normal speed owns compact NOW/NEXT/LATER priorities, designs every
coupled layout as a validated build package that the pilot revalidates and
queues unchanged, and may use only the separate mechanically read-only MCP
surface (which includes the side-effect-free `can_place` and `find_placement`). Its observations never enter the physical
lane. Sol atomically writes the one `operations.json`, including its initial
revision (`ledger-apply` with an `init` envelope), and it is Sol's only channel
to the pilot; Luna never writes it and continues fail-open when advice is
absent, malformed, stale, or unavailable.
Neither role profile is applied to an active run in place.

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

Records live under `~/.local/share/factorio-codex/runs/`. Debug and assisted
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
travel, and buffer-aware packets over exact next-task quantities. Exactly one
physical call may be in flight; only read-only snapshots may overlap when their
tick inconsistency is acceptable.

`production_requirements` treats mined resources and offshore-pump fluids as
raw roots unless `recipe_choices` names a recipe, and never routes through hidden
recycling recipes. It also accepts one technology or space-location target.
It derives missing current-force prerequisites, remaining science, trigger
conditions, permitted locked-recipe arithmetic, bounded force-flow rates, and
time estimates while separating probabilistic or operational requirements and
never crediting exact remote inventories.

Debug runs continue past `GO+20m` to their assigned milestone unless the owner stops
them; Candidate B and R1-R7 remain historical evidence. Gameplay remains
text-only and physical. See the repo-local `factorio-player` skill for the
current contract and [agent play performance](docs/AGENT-PLAY-PERFORMANCE.md)
for historical evidence.

`map_summary` computes connectivity, components, provenance, diagnostics,
production counters, signatures, transfer attribution and autonomy over every
eligible existing player-force entity in already charted chunks. Presentation
alone is capped: 12 nodes, 24 edges, 24 diagnostics and 8 components. Each
component returns at most 12 node IDs and 24 blocker names, with nested omission
counts; `factory.omissions` counts omitted graph rows. These omissions make the
presentation partial, not the physical evidence incomplete. Exact component
sampling for `validate_factory_component` resolves 1–16 caller-named positions
against the complete graph, including nodes and components absent from the
response. Missing, ambiguous and split-component selections fail structurally.

Component state and validation evidence carry `downstream_kind`: `buffer`,
`consumer`, `mixed` or `none`. A buffer stores output; it is not a consuming
sink, and its stock never proves an upstream production source. The agent
chooses whether buffer-ended capacity fits the current game stage. A full or
otherwise nonaccepting output buffer (including intermediate storage) reports
`blocked_output` and cannot claim current `autonomous_end_to_end`. Unsupported acceptance remains unproven.

`validate_factory_component` uses the existing parked plan step to sample a
bounded 1–300 second unattended interval. It requires unchanged physical
relationships and recipe identities, complete transfer history, proven material
and fuel supply, productive power/fuel status at every sample, at least three
processor cycles, three observed source cycles and three downstream acceptance
samples per output item at each endpoint. Buffer acceptance requires increases
in each matching output stock across distinct samples; a working consumer
supplies consumer acceptance evidence. Drill source cycles use a mining-progress
wrap accompanied by depletion of the
same already charted target. Adjacent sampling intervals vary the phase to
reduce cadence aliasing. Shared-target attribution, unavailable counters or
remaining sampling aliasing stay unproven; longer duration alone need not resolve
every alias.
[Factorio's API](https://lua-api.factorio.com/2.0.72/classes/LuaEntity.html#mining_progress)
provides drill progress; `products_finished` applies to crafting machines.
Private inventory/resource samples and exact internal identity strings are never
returned. Validation returns aggregate production deltas,
`source_cycles_observed`, `downstream_acceptance_samples` and structured blockers, with at most 24 blocker rows and an omission count.
Serialization omissions alone do not reject validation. Character transfers,
changed topology, missing fuel, no production or unobserved downstream acceptance
do reject it. A prior proof also loses current autonomy when a new transfer,
nonproductive status or blocked output appears. These are sampled bounded
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
