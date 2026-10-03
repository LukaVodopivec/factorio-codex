# Live validation

This runbook validates release **0.19.9**. Prior live evidence remains historical
until the fresh 0.19.9 run is recorded. The Linux workstation has no dedicated
GPU and is permanently headless: run only the dedicated server, Node bridge,
and agent tooling there. Never start a Factorio GUI/client or any other visual
GUI workload on that workstation during rollout, validation, or a benchmark.
Both visual Factorio processes run exclusively on the couch PC. The
`scripts/launch-native-client.ps1` entrypoint is couch-only; the repository does
not provide a Linux visual client launcher.

1. On the couch PC, install the full standalone Factorio 2.0.x Space Age build under
   `%LOCALAPPDATA%\factorio-codex\standalone-space-age`, or pass its executable as
   `-FactorioBinary`. The Steam build is intentionally rejected for the Codex
   client because it replaces the isolated LAN identity.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Host a dedicated Space Age fresh freeplay save from one run directory with
   permanent peaceful mode and enemy bases disabled:
   `node companion/dist/cli.js server create <run-dir>`, then
   `node companion/dist/cli.js server start <run-dir> [--bind <lan-address>]`.
   The run directory owns its save, logs, PID, and a run-local mod directory
   with base, elevated-rails, quality, space-age, and the companion enabled, so
   stale global mods never load. `server start` refuses a protocol or mod
   version mismatch before `GO`; `server stop <run-dir>` saves over RCON and
   shuts the server down at the run boundary instead of leaving it idle. Both
   server and couch client run the identical Space Age mod set.
   Console-backed RCON disables achievements for the save. Play is
   Nauvis-first: the MCP has no rocket, space-platform, or planet-travel tools
   yet.
4. From the couch PC, run
   `scripts/launch-native-client.ps1 -Address <server:port>` to connect the
   isolated low-resource native client as the real player named `Codex`, before
   starting the normal couch Factorio client as the viewer. Its write-data and
   mod profile lives only in `%LOCALAPPDATA%\factorio-codex\native-client`. Run
   `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`. Confirm the mod refuses an
   absent or wrong player instead of creating a standalone character.
5. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
   Verify `mine` count repeats cycles only on its initial exact resource and
   that `observe_local` reports resources as connected patches with an exact
   `nearest_target`, not duplicate entity rows. Observe an exact `ground_items`
   stack, call `pickup_items` with its unchanged position/item/count, and verify
   ordinary walking/ticks, target depletion, and the matching inventory delta.
6. Run a two-or-more-step `run_plan`. Confirm ordered fail-fast outcomes, no
   later enqueue after failure, and a final observation on completed, failed,
   and cancelled paths. Confirm Codex walks at ordinary Factorio speed and no
   global game-speed setting changes.
7. In the supervisor's recorded emergency-quiescence rehearsal, interrupt a
   long action in the TUI, observe retained work, then have the supervisor call
   `stop` if cancellation is required. Verify active tasks, queued plans, and
   character crafting are cancelled and re-observe physical quiescence. The
   interruption alone grants no cancellation authority to the pilot; ordinary
   recovery retains committed effects and reconciles pending work.
8. Exercise `find_placement` at a shoreline; confirm `map_summary` reads only
   force-charted chunks; verify deterministic production arithmetic and
   ambiguity refusal. Find a cardinal inserter placement with an exact
   `output_target`, physically place it with that target, and distinguish its
   live output point's valid 1×1 recipient geometry from runtime binding. A nil
   `drop_target` before first output must remain explicitly pending, not fail or
   claim binding; a non-nil different target must fail. For a mining drill,
   include legitimate starter fuel in the same build-plan step and confirm the
   plan waits until actual output flow exposes the exact runtime recipient.
   Inspect the placed inserter's `pickup_target` to
   falsify an incorrect source binding. Confirm an output-capable candidate always
   reports `output_position` and reports its recipient or explicit `null`; a
   selection-box-only furnace overlap must not pass exact target filtering.
   Confirm mining-drill candidates report
   only compatible resources whose centers are covered by their mining area; treat a
   deterministic rejection count for charted candidates with zero compatible
   resources and treat omitted coverage as uncharted. Inspect the live inserter
   and confirm its pickup/drop positions and valid target identities; confirm
   belt contents, a mining drill's actual output position, recipient-or-null and
   `drop_target_bound`, its current resource target, and exact furnace
   fuel/input/output buffers only where the corresponding inventory exists.
   Force a bounded no-path/stall fixture and confirm only its immediate charted
   collision segment, stable capped inferred visible collision candidates and
   collision tiles—not an authoritative blocker claim—or the explicit absence
   of an identified blocker. Confirm a terminal
   `plan_status` still carries only the assigned `queued`, first `running`, first
   applicable `waiting`, and truthful final transition after a fast successor.
   Then physically connect steam power to an
   electric drill and deliver mined ore through belt, pipe, and power routes.
9. If bootstrap items are absent, use another fresh built-in freeplay save.
   Gameplay roles never use console commands, editor mode, spawned items, or
   teleporting. A debug supervisor may use those surfaces only for recorded
   diagnosis or the smallest recovery intervention, after which the pilot must
   re-observe authoritative MCP state.

For the 0.19.9 reliability pass, also record these observable checks without
turning them into a fixed opening or map-specific sequence:

- A compact observation stays bounded, names every omission count, and appears
  once as structured content with only a short text summary. Full detail remains
  available only when deliberately requested.
- A freshly observed natural target either mines by exact identity or returns a
  named diagnostic distinguishing exact-coordinate resolution, physical reach,
  and engine selection. Re-observe after any stale-target result.
- A genuine no-path case reports only charted local collision evidence, any
  owned collision cage, and the best bounded reachable frontier/partial route;
  it neither walks that partial route automatically nor reveals uncharted state.
  Its `frontier_probes` give one reason per probe. Only when every answered
  probe was refused and none ended `timeout`, `transient` or `path_uncharted`
  does an enclosure by owned entities fail as `BODY_ENCLOSED`, naming one
  owned blocker (on the line toward the target first); recover only by
  extracting and mining it, never by teleport.
- A successful walk or approach never leaves the body on a belt: it steps once
  to a clear off-belt tile (reported as `settle`). `BODY_ON_CONVEYOR` leaves
  the body on the belt, where it drifts until the next `walk_to` off it; after
  any other plan the idle body shows no belt drift and
  `observe_local.character.standing_on` is absent.
- Neither role calls a thread-reading tool after `GO`, Astra's notebook is
  non-empty, and at least one package names a note.
- An underground belt pair placed with `belt_to_ground_type` `input` then
  `output` reports the output end paired with the input end; the offline
  fixtures do not verify the output end's direction. A `belt_to_ground_type`
  on any other item fails before walking.
- Read-only results carry `fifo`; after more than 30 s of idle body the pilot's
  next read shows the `body idle` hint and the pilot queues work before reading
  further.
- A powered line on the steam network stays its own component: it carries
  `power_supply_component_not_proven` until the plant's component is proven
  (on run history, so a line validated later still sees that proof; only a
  transfer into the plant revokes it, never unrelated later proofs), then
  validates on its own, with the plant's boilers, their refill inserters and
  their fuel sources' supply judged in the line's window. A
  lab-ended segment with no research
  selected is refused as `consumer_idle_no_research`; with research active,
  any lab, working or not, is refused as
  `consumer_missing_required_science_pack` unless the segment supplies every
  pack the research needs (directly or through an upstream lab), and a lab's acceptance counts only after the window
  sees it working. An inserter on `low_power` is
  judged by throughput.
- Growth is input first: from the run recorder's samples at `GO+20m` and
  `GO+60m`, record drills and furnaces by entity and ore and plates produced
  per minute, and compare them with the same checkpoints of debug cycle 6
  (target: both checkpoints above cycle 6). Science is not hand-crafted while
  plate production per minute is below its consumption. Compare per resource:
  use each raw resource in the recorder delta (coal included) and each plate.
  Report both the last 5-minute interval, where a stall shows as 0, and the
  average since the recorder baseline. Take the sample captured nearest
  `GO+20m` and `GO+60m` by wall clock: the recorder baseline precedes the `GO`
  receipt by about 20 s. Recorder flow rows are capped. Component, autonomy,
  validation, edge and product counts are whole-factory only when the sample
  carries the mod's whole-graph counters. Otherwise they are partial and must be
  labelled so.
- Record every `topology_sample_flicker` and every `topology_diff`. A window
  must not end on one differing sample (target: zero flicker early ends), and
  a lazy fuel-only feeder at a stocked burner must not fail
  `transport_starved_before_end` (target: zero such false negatives).
- For path-start recovery, record the deployed source SHA, packaged mod archive
  SHA-256, Factorio version, exact plan identities/outcomes, and structured
  character position plus `path_start` at the starting and later ticks. Exercise
  walking among existing belts and mined-tree remains: footprint overlap alone
  must remain `state=clear` and must not require mining or body-clearance rescue.
  Observation and movement use the same collision-mask classification.
- Exercise a genuine collision overlap while the goal is already inside exact
  arrival tolerance, and repeat with a resolved vicinity goal. Arrival and
  within-reach placement/entity shortcuts must wait for physical clearance.
  Record ordinary escape movement followed by native path traversal. In a true
  cage or a stationary escape, expect a finite actionable `START_COLLISION`
  failure, stopped walking, and no native request from the uncleared start;
  a nearby free destination does not prove that the approach is traversable.
- Continue a partially committed placement plan through embedded approach;
  verify exact entity reach, carried-item consumption and preserved earlier
  placements. `path_start.clear=false, state=unknown` means missing/unsupported
  evidence or a failed engine query, with a reason; it never proves clearance
  and movement reports `START_COLLISION_UNKNOWN`. Record every supervisor
  intervention and exclude assisted progress/timing from benchmark evidence.
  Offline fixture passes do not establish live recovery. Use only an authorized
  supported run; do not restart or alter an unrelated active run for this check.
- A deliberately split electrical route reports successful pole placement
  separately from endpoint coverage and network continuity. Add an honest
  bridge and confirm the later result becomes connected; do not equate either
  result with a powered, working consumer without inspecting that consumer.
- A producer and its recipient can be preflighted when the recipient is an
  earlier placement in the same build plan. Wrong endpoint geometry fails
  before mutation, while runtime binding remains exact and pending until first
  output when appropriate.
- An out-of-range `wait_for_item` fails immediately with the physical-distance
  correction instead of consuming its timeout. An insertion that accepts only
  part of a request terminates as `partial`, reports requested/inserted/remainder
  counts, preserves the useful accepted amount, and does not execute dependent
  steps.
- Queue and plan responses carry a self-describing `terminal` state and exact
  `next_action`; a terminal continuation handle is never waited a second time.
- A plan with `observation_detail=none` returns compact outcomes, execution
  metadata, and inventory deltas without an embedded observation. Explicit
  compact/full requests retain bounded detail and omission counts.
- A bounded `plan_status` wait returns on a meaningful step outcome, waiting
  state, or terminal result. A monitoring timeout does not cancel the plan and
  returns a self-describing continuation.

## Full graph and downstream acceptance validation

Offline Lua fixtures and MCP tests verify graph computation versus capped
presentation and validation failure cases; they are stub evidence, not live
Factorio evidence. Live confirmation requires an installed supported Factorio
2.0.x game. No deployment or server/client replacement is implied by offline
checks.

- Observe an already charted connected segment exceeding 12 nodes and 24 edges.
  Confirm full component counts and accurate presentation omissions. Select
  exact positions beyond returned rows with `validate_factory_component`; an
  unrelated component's presentation omissions must not reject the segment.
- Observe a physically supplied drill–furnace–chest segment with ordinary fuel
  supply and power. Confirm `downstream_kind=buffer`, then validate an unattended
  interval with at least three processor cycles, three observed drill cycles
  (progress wrap plus depletion of the same charted resource) and three distinct
  arrival samples for each relevant output item. Sampling aliasing, unsupported
  source counters and shared mining-target attribution remain unproven. Contrast with a working consumer-ended segment reporting
  `downstream_kind=consumer`. A buffer is storage, never a consuming sink or a
  production source inferred from existing stock; agents decide its usefulness.
- Also check a processor-free source-to-transport-to-buffer or consumer segment.
  Require three observed mining-progress wraps with same-target depletion per
  source and three distinct acceptance samples per relevant output at every
  endpoint, unchanged topology, complete transfer history and zero component
  transfers. Require processor cycles only for processors actually present;
  source-only proof may have `products_finished_delta=0`. For a burner mining
  its own fuel, record the exact directed physical return bindings. Compatible
  mined output and finite starter stock alone cannot prove replenishment.
  Topology readiness and local operation alone are not `autonomous_end_to_end`.
  A working consumer must accept every relevant output through its native input
  inventory at each counted sample. Reject incompatible outputs, full inputs,
  and unsupported consumer acceptance; unrelated stocked inputs and
  working status alone cannot prove endpoint acceptance.
  The historical coal-buffer increase and offline fixtures do not prove live
  autonomy; live evidence needs the exact deployed source/archive identity and
  a fresh structured multi-tick interval. A belt run that ends at an inserter
  pickup, an underground pair, or a loader into a container must not report
  `belt_dead_end_without_consumer`; a run with no consumer reports it once, at
  its last tile, with a position. A queued repair is not complete until
  re-observed.
- Separately authorized live steam-power confirmation must use a **fresh
  supervised Factorio 2.0.x run**, with matching server/client mod sets and
  recorded source commit, release/archive digest and save identity. Do not
  upgrade, replace or restart the existing active run to validate this change.
  Source publication and offline fixtures do not establish installation or
  live steam-power autonomy; both remain unverified until these receipts exist.
  Build a legitimately supplied offshore-pump → separate-pipe boiler → native
  steam transport → thermal generator segment powering a material participant
  with a consuming endpoint or terminal buffer with space. Derive identities
  from the source tile, native fluidbox filters/temperature constraints and
  generator/boiler prototypes, never stocked contents or recipe guesses.
  Keep electrical dependencies separate from material/fuel/acceptance paths.
  Run the existing parked component validator for 1–300 s, long enough to
  exercise boiler fuel replenishment. Require three consecutive-tick bursts
  (eight ticks, extended up to 60, and at most a third of the window, while a
  boiler's balance has not cleared its reserve of one unit per steam-domain
  segment, so a saturated domain needs about 30 kW per segment at 4 s or
  more): native pump activity, generator output, uniquely attributed boiler
  output mass balance with fuel use/non-draining input, endpoint arrivals or
  actual steam consumption, and three electrical delivery events. Preserve mining/crafting proof for the entities that have those
  counters, complete transfer history, zero character transfers, exact private
  topology and per-path recency. Record the compact native aggregate fields;
  exact fluid quantities, network counts and internal signatures stay private.
  Unknown electrical suppliers/accumulator discharge, several boilers sharing
  one fluid domain, unreadable or aliased samples, or idle drain-free
  consumers with full buffers remain unproven. More duration alone need
  not resolve these limits. Check native pumps and underground connectivity,
  multiple observed generators and terminal fluid-buffer acceptance.
  Interrupt water, fuel and electrical supply separately; also test wrong fluid
  or temperature, disconnected pipes, full endpoints, replaced entities,
  changed network bindings and a character transfer. Re-observe revoked
  current autonomy, locate each blocker, and obtain a new bounded proof after
  repair. Finite starter water/steam/fuel/electrical energy must not pass.
- Make the buffer full or nonaccepting. Confirm `blocked_output` and revoked
  current autonomy. Buffer capacity alone and production without accepted
  arrivals must never establish autonomous operation. Unsupported buffer
  acceptance remains unproven; no exact remote inventory/fluid counts appear.
- In an authorized supported Factorio 2.0.x run, observe an exact connected
  fuel-return inserter waiting at the burner's ordinary replenishment target
  while useful production continues, both with held fuel and with an empty
  held stack. For the empty case, capture the supported burning pair and the
  single matching stocked fuel/quality pair; never read empty-stack identity.
  Capture `identity_source`, pickup/drop
  bindings, compatible upstream production, working burner with remaining
  energy, matching stocked fuel and fuel-inventory space. Confirm the waiting
  status stays visible with `fuel_return_saturation` and the corresponding
  diagnostic's `nonblocking_reason`, while that branch alone does not set
  component `blocked_output` or either other output blocker. Do not infer the
  normal replenishment target from a hard-coded count or relabel the inserter
  as working. Unsupported or ambiguous compartment/fuel evidence stays blocked.
- Observe exact `waiting_for_source_items` snapshots at preflight and during
  sampling on both a fuel-return and a material-transport inserter. Confirm the
  status stays visible as a `transient` row and never refuses preflight. Record
  all required source and processor cycles, matching acceptance at every
  endpoint and zero transfers. A node nonproductive for the stall interval, or
  still dead at the window end, must fail as `persistent_nonproductive_status`
  even when independent downstream stock grows. Starve one takeoff from the
  window's first third to its end while stock carries its consumers; it must
  fail as `transport_starved_before_end` at that inserter. A burner's sole
  fuel inlet, a fuel-only feeder, waiting while it still holds its top-up stock (five items)
  owes it nothing in that sample; confirm a lazy furnace fuel feeder proves
  although its swings are further apart than the recency limit, and that a
  feeder stopped behind stocked fuel still fails once a draw goes unanswered.
  A second fuel inlet into that burner, including one from a hand-stocked
  chest, removes the exemption.
- Observe fuel consumption, resumed ordinary replenishment, and renewed waiting
  with unchanged topology. Record continued source/processor production,
  downstream acceptance and zero character transfers across the bounded
  validation interval. Then independently exercise genuine productive-output
  and full/nonaccepting buffer blockage, incompatible/unresolved fuel, and a
  belt run without a consumer; each must still reject autonomy with a located
  row. A segment without a fuel edge or downstream buffer must be refused as
  `FACTORY_COMPONENT_NOT_READY` (`stage=readiness`) before any window.
- Check positive burning energy and matching compatible stocked fuel during
  the window, including after the return inserter resumes working. Independently
  remove stock, interrupt burning energy, or make fuel evidence unsupported,
  and keep downstream output growing through another branch. Each broken return
  must still fail validation with a located fuel row; aggregate output growth is
  not continuous fuel evidence.
- Record the exact deployed source revision and mod archive digest with live
  structured observations. The Lua saturation/replenishment fixture is offline
  simulated evidence, not confirmation of the reported release 0.19.5 live
  observation or any later deployed candidate. This source change has no live confirmation or deployment;
  perform that check only in a separately authorized run, without restarting or
  altering an unrelated active run.
- During separate validation intervals, interrupt fuel/power, change a physical
  relationship, stop production, or perform a character transfer. Each must
  produce structured rejection. Hold a fuel/power interruption past the
  20-second stall, or until throughput stops: a short interruption while output
  continues is a transient wait that passes and appears only in
  `transient_conditions`. The sustained one must end the window with
  `persistent_nonproductive_status:no_fuel` or `:no_power` at the producer, and
  a validated producer at that status must lose `autonomous_end_to_end`. A
  burner loop running on starter fuel with its fuel return starved must fail
  with that stall row or `fuel_replenishment_not_observed`, even when it
  produced earlier in the window. Check complete transfer attribution even when
  the public target-action rows are omitted. Bounded validation samples the
  interval; it cannot guarantee every intervening tick or future buffer demand.
- For the sampling correction, compare repeated 60-second windows at
  varied start phases in a separately authorized isolated run. Record deployed
  commit, archive digest, save identity and start/end ticks. The 29/28-tick
  cadence reduces aliasing but may miss short swings. A private sampled fuel
  rise resets only the exact unique supplied inserter inlet's source-wait
  streak; another possible fuel inlet forbids that attribution. Confirm the
  reset does not excuse a stopped return after one early delivery or borrow
  replenishment from a competing inlet. Keep the ordinary fuel-demand,
  replenishment, supply-deficit, path-recency and structural checks intact.
  Distinguish total wait samples from the final uninterrupted sampled streak:
  in 60 seconds, `transport_starved_before_end` requires a streak strictly older
  than 1,200 ticks, except for pending longer-window evidence at the exact drop
  target. Record saturation and pending rows separately. Equal topology,
  production and wait totals do not establish equivalent physical activity.
  Exact inventories, fuel quantities and internal identities remain private;
  report only bounded outcomes and relevant transport/replenishment evidence.
  The supplied short-swing and boundary fixtures are offline synthetic evidence;
  they establish a possible aliasing mechanism, not the cause of the reported
  release 0.19.6 windows. This correction has no installation or live receipt.

## Persistent two-brain, one-writer contract

The dedicated server and agent session run on the headless workstation, while
the exact `Codex` client and characterless spectator/follower run only on the
couch PC. Do not launch a local GUI as a recovery shortcut.

The next fresh supervised-debug topology has exactly two persistent reasoning
sessions and one physical writer. Start the sole gameplay pilot as
`gpt-6-luna` with `low` reasoning and fast mode enabled. Start the persistent
strategist as `gpt-6-astra` with `medium` reasoning at normal speed and expose only the disabled-
by-default `factorio-readonly` MCP server to it; disable the full `factorio`
server in that Astra session. Astra owns NOW/NEXT/LATER and is the sole atomic writer
of one compact `operations.json`, including its initial revision. The ledger is
Astra's only channel to the pilot. Astra designs every coupled layout as a build
package checked with `find_placement` and `can_place` (the only coordinates in
the ledger); Luna revalidates and queues packages unchanged and owns immediate
safety, travel, gathering, physical plans, actions, and latest exact local
evidence. Astra reads never enter
the physical FIFO, and Luna continues without waiting when Astra or its ledger is
stale or unavailable. Record both profiles, their MCP surfaces, release SHA,
archive hash, and save hash before `GO`. Never apply this cutover to the current
run.

Before `GO`, create an empty `notebook/` directory beside the run's
`operations.json`. Astra alone writes it (markdown ideas, approaches, outcomes,
and relative layout templates; a `README.md` index of at most 2 KB; about 64 KB
in total; no imported or copied external content). A build package may name up
to three `notes`, which `ledger-apply` refuses unless each is an existing file
beside the ledger, and the pilot reads only those. The notebook is not a
broker, second ledger, or control channel. Archive it with the run and
summarise what Astra learned in the run write-up.

Launch the two connected sessions from the repository with `session-launcher`.
The pilot needs no MCP override: the project `.codex/config.toml` defaults are
already its surface. Connected (`--remote`) clients validate `-c` overrides
before the project layer loads, so a role override must name a complete server
table; a partial `mcp_servers.<name>.enabled` override fails with
`invalid transport`.

```sh
session-launcher --name factorio-pilot --model gpt-6-luna --reasoning-effort low --fast on
session-launcher --name factorio-strategist --model gpt-6-astra --reasoning-effort medium --fast off \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=[],enabled=false}' \
  -c 'mcp_servers.factorio-readonly={command="./scripts/start-factorio-mcp",args=["--surface","read-only"],enabled_tools=["connect_status","map_summary","progression_status","production_requirements","describe_prototype","observe_local","inspect_entity","plan_status","can_place","find_placement"],enabled=true,required=false,startup_timeout_sec=180,tool_timeout_sec=600}'
```

The launch flags express requested settings. `--fast on` requests
`service_tier="priority"` plus `features.fast_mode=true`; `--fast off` requests
normal service. Neither a launch flag nor a successful update is role-profile
confirmation. Follow the native readback procedure below before `GO`.
Start each with its checked-in role goal; the pilot takes no physical action
before `GO`. Confirm Astra lists exactly the ten
configured read-only tools (including the side-effect-free placement checks) and cannot list any movement, transfer, crafting,
placement, research mutation, plan enqueue/run/cancel, or stop tool before
`GO`, and that the pilot has the full surface and no read-only server.

Before `GO`, verify the requested fresh save and release hashes, permanent
peaceful mode/enemy bases disabled, exact native player, viewer, and one
body/lane/writer. Archive the previous run's `operations.json` into that previous
run's directory and verify the current ledger destination is absent. Give Astra
the new ledger's absolute path and the exact `run` object
(`id`, `release_sha`, `baseline_save_sha256`, `save_identity`, `created_at`,
`roles` per the ledger schema: `{"pilot":{"model":"gpt-6-luna","reasoning":"low","fast":true},`
`"strategist":{"model":"gpt-6-astra","reasoning":"medium","fast":false}}`), and have Astra create it by piping an
`{"init": true, "run": <that object>, "source_tick": null, "update": ...}`
envelope to `node_modules/.bin/tsx companion/src/cli.ts ledger-apply --ledger
<absolute operations.json path>` from its worktree. Supply a fresh observed
`source_tick` when available; `null` means no observation yet. Fill `update`
with the validated current mutable fields (`phase`, `bottleneck`,
`latest_measured_capacity`, `task_list` with NOW/NEXT/LATER, `assumptions`,
`pilot_plan_ids`, and `build_packages`, usually `[]` at init; every later update
restates it). Verify the receipt returns `status: "applied"`, revision 1,
and the submitted source tick; verify the persisted schema-2 ledger contains
the exact run metadata, revision, source tick, mutable content, and mode `0600`.
The command validates this readback before reporting success. Initialization
refuses every existing destination, including malformed ledgers, without
replacement. Subsequent reports use the unchanged
`{run_id, save_identity, source_tick, update}` envelope and require a newer tick;
an ordinary update cannot initialize an absent ledger. Never hand-seed revision
0: Astra is the sole atomic host writer, including initialization, and Luna
continues fail-open if Astra or the ledger is missing, malformed, stale, or
unavailable. On any resumed save or after a mod upgrade,
reconcile retained work: if `observe_local` reports an active task or queue
depth, call `stop` and re-observe until idle, and treat pre-`GO` plan IDs as
invalid `after_plan_id` values. Rehearse the stop sequence below on the live
role sessions without stopping the server; a role turn must end within about
five seconds of pause plus interrupt. Then resume both role goals through the
native procedure below and pass the live steam gate below before starting the
recorder; an active goal plus an idle thread does not prove that queued `GO`
will start a turn. At `GO+20m`
record the GO+20 recorder checkpoint as the run's comparison snapshot without
stopping anything; assisted debug progress is still not benchmark evidence. Continue past
20 minutes toward the assigned milestone
(currently sustained autonomous Nauvis production: a validated
`autonomous_end_to_end` segment that still holds at the next two recorder
checkpoints, plus useful research consuming produced science); Candidate B and
R1-R7 freeze rules are historical unless the owner starts a benchmark.

### Native role-profile evidence before GO

Use the existing connected session transport, exact role thread/turn identities,
and existing run evidence. Add no launcher wrapper, enforcement hook, evidence
store, ledger field, or gameplay control channel. Apply this procedure only at
the fresh-run preparation cutover; never reconfigure an active gameplay role.

The [official configuration reference](https://developers.openai.com/codex/config-reference)
defines `features.fast_mode` as enabling model-catalog service-tier selection
controls. It describes `service_tier` as a preference for new turns, with `fast`
mapping to `priority`. Separate four kinds of evidence:

- **Requested:** launch flags or the exact `execution_settings` update values.
- **Current turn:** native `current_turn.model`, `reasoning_effort`, and
  `service_tier`; an update does not retroactively change this turn.
- **Next turn:** native `next_turn` model, effort and tier; a successful update
  with `effective:"next_turn"` establishes a request for subsequent turns.
- **Availability/inheritance:** `fast_mode_enabled` and
  `fast_inherited_from_root` when available, preserved verbatim. Verify their
  semantics in the installed runtime, rather than equating similarly named
  fields. The disposable 0.159.2 probes below establish that its enabled flag
  follows the selection feature, independently of the selected Fast tier.

Each exact role calls native `execution_settings({})` in preparation and sends
a compact structured projection copied verbatim from the native result to the
supervisor: both model/effort/tier triples and the availability/inheritance
fields, plus exact thread/turn identity and separate requested values. Keep the
message below the existing 1,000-byte transport limit; exclude unrelated
context, usage and model-catalog fields. Keep requested values separate;
do not reconstruct readback from a launch command or substitute the supervisor's
own settings. Record session and turn identity, native runtime version,
observation receipt time, requested values, reported values and interpretation
in existing run evidence. This preparation report uses the existing session
transport to the supervisor; Astra's only channel to the pilot remains the ledger.
All required profile fields fit this compact projection. If fuller native output
is needed, the supervisor reads it through the existing session transport and
records it in existing run evidence; do not add a store or channel.

If preparation changes a role profile, retain the update receipt, end that
turn, and obtain a fresh native read in the subsequent turn. Require both
`current_turn` and `next_turn` to match Luna / low / Fast (`priority` in the
validated runtime) or Astra / medium / normal (`default` in these probes,
`standard` only when the installed runtime establishes that mapping).
`changed:false` on a read means no update was requested, not failed preparation.
Missing fields, unresolved null tiers, wrong identity, malformed or stale
reports, delayed delivery and unexplained contradictions hold `GO`. Resolve
with the exact role and a fresh read; never silently treat them as confirmation.
Any later settings update invalidates the earlier report.

The supervisor explicitly consumes and records its assessment of **both** fresh
reports before authorizing `GO`. Sending or queuing a report does not prove
consumption. A report that arrives after this assessment requires reassessment;
if it arrives after `GO`, record the missed preparation evidence and qualify the
run rather than retroactively claiming compliant preparation. A true selection
feature flag with current/next normal tiers is consistent in the validated
runtime: preserve it as capability evidence and judge selected normal speed by
the tiers. Any other unexplained conflict must be resolved before `GO`; the flag
alone does not establish a native bug.

These tiers describe native selected thread/turn settings. They do not by
themselves prove provider processing. Record provider-confirmed processing tier
separately if the transport exposes it; otherwise state it is unavailable and
claim only the selected profile. Never infer provider confirmation from latency,
a feature flag, a model catalog, or a role's prose summary.

**Verification evidence and limits (2026-10-02).** Disposable persistent
native 0.159.2 app-server sessions used the existing stdio JSON-RPC mechanism,
with configured MCP servers disabled, a read-only sandbox, and no gameplay
goals. Experimental raw tool-output events supplied actual `execution_settings`
results, not inferred launch values. Receipt times below are UTC:

| Probe / receipt | Native current turn | Native next turn | Enabled / inherited | Supervisor interpretation |
| --- | --- | --- | --- | --- |
| Luna, 01:14:15 | Luna / low / priority | Luna / low / priority | true / false | Pilot selected Fast profile confirmed; no GO while Sol report absent. |
| Sol delayed until 01:14:42 | Sol / medium / default | Sol / medium / default | true / false | Both reports now consumed; normal tier and true flag retained separately, not classified as a bug. No gameplay GO was sent. |
| Sol requests Luna/low/fast:true, 01:14:49; same-turn read | Sol / medium / default | Luna / low / priority | true / false | `changed:true`, `effective:next_turn`; preparation incomplete despite update success. |
| Subsequent turn, 01:14:54 | Luna / low / priority | Luna / low / priority | true / false | Fresh native read confirms application after the turn boundary. |
| Requests Sol/medium/fast:false, 01:14:56; same-turn read | Luna / low / priority | Sol / medium / default | true / false | Disabling Fast selects default for next turn while selection capability remains enabled. |
| Subsequent turn, 01:15:00 | Sol / medium / default | Sol / medium / default | true / false | Fresh normal profile consumed; true flag is capability evidence. |
| Separate session with features.fast_mode=false, 01:15:05 | Sol / medium / null | Sol / medium / null | false / false | Controlled feature-off probe changes the enabled flag; null tier remains qualified, not normal-profile confirmation. |

The supervisor withheld profile approval while Sol's report was outstanding
for 27 seconds, then consumed both structured reports. The delay was controlled
by requesting Sol's read after Luna's; it does not test transport congestion.
The supervisor withheld confirmation across each mismatched current/next update until the subsequent-turn read. This
is a disposable preparation exercise, not a live GO test. The feature-on/off
comparison verifies the installed flag's capability meaning for these probes;
it does not prove identical semantics in other versions or inheritance behavior
for child sessions. Recheck after runtime changes. Provider processing tiers
were not exposed in these settings results, so only native selected tiers are
confirmed. Cleanup read all three test threads idle, archived them through native
session controls, and observed the test app-server exit successfully. Initial
transport-reader sampling was corrected before these complete probes; two
preliminary sessions were also archived. No active gameplay role, shared native
setting or credential was changed; no live run, mod deployment, server restart,
or gameplay-performance claim follows from this validation.

Repository-native offline verification used Node 22.23.2: the two-brain contract
passed all 10 tests, the focused verifier passed all 15 Python tests, and quick
and full passed all four and ten declared checks in a standalone checkout with
byte-identical source at the time of those runs and the existing installed
dependency tree. Subsequent changes were documentation only (compact-report
wording and this evidence record); the two-brain and diff checks were rerun
afterward.
Initial preserved-worktree quick/full attempts reported an owning-checkout
dependency-descriptor mismatch or missing descriptors; they did not establish
which condition caused it. The standalone check supplied a matching real owning
checkout without altering the verifier.
an earlier issue remains separately owned; this correction changes no verifier code or
suppresses any check. Fresh independent read-only review found a preparation
message-size conflict; the compact projection above resolves it (a representative
message with native Sol values and UUID identities is 417 bytes), and the
reviewer confirmed the transport fix. A subsequent evidence-coverage finding
was resolved by qualifying which source the broad checks covered, as above.
Offline results do not prove
live role preparation, provider processing tiers, or improved gameplay.

After integrating the advanced 0.19.2 target, the instruction patch remained
unchanged. The preserved worktree's own quick/full verification then passed all
four/ten declared checks under Node 22.23.2; an exact committed standalone clone
also passed both profiles. The integrated two-brain contract passed all 10 tests.
A fresh independent read-only review found no integration conflict: upstream
idle reporting, plan sizing and native GO resumption remained intact. These
checks covered the integrated source before this evidence-only update; the
final focused contract and diff checks were rerun afterward. The earlier
prerequisite failure remains historical, not a current readiness failure.

### Live steam gate before GO

Release 0.19.7 called a `LuaEntity` method that Factorio 2.0.77 does not have,
and the offline mocks supplied it, so every steam or powered component in debug
cycle 7 was refused. Strict offline mocks now reject members absent
from the vendored 2.0.77 runtime list, but they still cannot prove
native values or behavior.
an earlier issue exposed a different native-value mismatch in 0.19.8: successful
`get_fluid_segment_id` and `get_fluid_segment_contents` reads return `nil` for
offshore-pump and separate-pipe boiler output boxes, and for a `pump`'s single
box (volume 400, `production_type` none, carrying both its input and output
connections). Their products, filters, temperatures, own buffer stock and
directed connections remain readable. The retained sampler preserves that
absence without inventing a segment or stock; a failed or half-present read
still refuses the sample. `get_capacity` is the box's own capacity, while a
segment's contents include every member box (a boiler's water input reads its
own 200 plus its pipes). Private validation therefore balances fluid
domains: a segment's native contents, or an out-of-segment box's own buffer,
joined to the segment on its exact proven pipe connection. A segment's
capacity is the sum of its sampled member boxes, and an engine still accepts
steam while it generated last tick, because an inline pump refills its segment
to exactly full.

Electric network `output_counts` records generation, one tick ahead of
`energy_generated_last_tick`; attribution allows only the native counter
rounding (1/65536 J per increment, or float32 precision of the observed
amount). Exact electrical dependents remain separate material components, but
their private energy observations establish delivery by the supplying plant. A
supplied consumer's buffer can read full every tick, so a positive,
nondecreasing buffer under a positive native drain, or on a working drain-free
consumer (an electric mining drill) while its network's consumption for its
prototype rose, proves consumption and replacement; empty or draining buffers,
or a drain-free idle buffer, do not. Three
consecutive 120-tick bursts allow low-demand boiler transformation to exceed
the retained mass reserve (one unit per member segment of the domain, for the
documented uint32 contract). A boiler unproven only in a shortened burst (a
window under 7 s, or a burst clamped after a recovered flicker) while its
input domain held is evidence naming a strictly longer window; at 300 s it is
a throughput row with no suggestion. An external dependent idle throughout at
a full drain-free buffer (an output-blocked drill) is neutral for its supplying
plant. Shared producers, disconnected paths, aliased
samples and finite starter fluid, fuel or electricity remain insufficient
evidence.

Before each fresh run's `GO`, the supervisor therefore proves the steam path on
the native runtime and records the result in `supervision.json` under
`steam_gate`. `GO` waits until the gate passes.

The strict offline mocks model these native facts, but still cannot prove
native values or behavior.

The validator is bound to the companion character's surface and charted chunks,
so it cannot validate a temporary surface of the live run. Building the fixture
on the run's own surface would also change the comparison save. Run the gate
instead as an isolated engineering fixture, following the occupied-belt and
burner-inserter fixtures below:

- Use a separate dedicated server with the run server's Factorio executable and
  version, and its own write-data directory and fresh peaceful save with enemy
  bases disabled. Bind it to loopback only, on an OS-assigned port, with no RCON
  listener, no LAN or public advertisement, and no client. It never touches the
  run's server, save, recorder, or ledger.
- Load an instrumented copy of the exact release mod archive. The fixture block
  appended to its `control.lua` binds the companion accessor to a fixture
  character. If the disconnected server does not chart, substitute
  generated-chunk checks for chart checks in that copy only, and record the
  substitution. Record the SHA-256 of the release archive and of the
  instrumented archive.
- On dry ground beside fixture water, build an offshore pump and pipes to a
  boiler. An electric mining drill on a coal patch fills a chest, and an
  electric inserter feeds the boiler from it, so the fuel has physical
  provenance and the plant component holds electric consumers (a hand-stocked
  coal chest is correctly refused: starter coal alone cannot establish the
  retained fuel provenance or replenishment proof, and a load in another
  component cannot make `native_power_required` true). The boiler feeds a
  steam engine. Poles also power a load in its own components: two electric
  furnaces fed from chests of finite ore and unloaded into chests with space
  (about 480 kW). An engine with no demand is not delivering power.
- After a change to fluid, pump, power or burst code, also run the
  `pump-low-load` variant: the engine two tiles further on behind an inline
  `pump`, primed with steam so it can power that pump, and no furnace load
  (about 90 kW on its steam domain, so only a long consecutive burst clears
  the mass reserve). It must also prove.
- Run the release's real `validate_factory_component` with the component's
  positions and `duration_seconds: 120`. The outcome must be
  `FACTORY_COMPONENT_AUTONOMY_PROVEN` with `native_power_required: true`,
  `power_delivery_samples >= 3`, and `fluid_activity_samples >= 3`.
- When the plan reaches a terminal status (`completed` when proven), empty the
  ore chests and bar the coal chest full, so every consumer on the network
  idles with a charged buffer and the engine serves only the consumers' native
  idle drain (zero generation when there is no drain). A `map_summary` read must still show
  the plant's power component `autonomous_end_to_end` with no `blocked_output`
  among its blockers. Record it as
  `standby: {autonomous_end_to_end, blocked_output}`.
- On the same fixture entities, probe once that `fluidbox.get_prototype`,
  `get_fluid_source_fluid`, and `neighbours` exist and return without error.
  Use the boiler, the offshore pump, and a pipe-to-ground pair. This probe only
  reads.
- Write the outcome and probe receipts to the fixture's script output. Then
  delete the fixture surface, confirm in a later receipt that it is absent, stop
  the server, and remove its write-data directory. That is cleanup verified.

Record the validation outcome, the standby read, the probe results,
`cleanup_verified`, and the
executable, version, and archive identities. Use the supervisor tooling's
`supervision_record.py steam-gate` command, which recomputes `passed` from the
thresholds above. If any condition fails, hold `GO` and report the failing
fields. Never weaken the fixture or the thresholds to make it pass. A fixture pass is engineering
evidence of the native steam path only. It proves neither gameplay steam
autonomy nor the fuller live steam-power confirmation above, and it is never
benchmark evidence.

The isolated engineering fixture passed on 2026-10-03 with Factorio
**2.0.77, build 84539, linux64 headless**, using the bundled Space Age mod set.
The material source candidate was based on
`31704489973c1affabb42ef2268c7c154c279205`. Executable and archive SHA-256 receipts:

- Executable: `c9ac91d318bdbcce5afaac30d48f4b71dc38af257712a5d4d4c4feb625737198`.
- Release 0.19.8 archive: `42378f29ad1e133a343769a9f6932dee8e9d7977754f9b4ec9157d7cb05d4957`.
- Instrumented archive: `fa034396ad109cfa1a9839a8bd7f558e23005e8407ac2d4ddf9ef93294a1904b`.

Every released source file matched the candidate mod. Instrumentation was
limited to the appended fixture block and the documented generated-chunk
substitution. A burner coal drill with a splitter and separate self-fuel and
feeder branches replenished the finite coal chest. Earlier underfed fixture
attempts failed provenance and were cleaned up; their failures were not treated
as validation passes.

The real request ran from tick 601 to 7801, exactly 7,200 ticks, and returned
`FACTORY_COMPONENT_AUTONOMY_PROVEN`, `native_power_required:true`,
`power_delivery_samples:360` and `fluid_activity_samples:3`, with no blockers
or character transfers. After all 500 finite plates left the source chest,
the final transfer settled, the hand was empty, and the inserter remained in
native `waiting_for_source_items` status for 120 ticks. Its positive buffer
held about 1,054.22 J, while generation of 8.33333 J/tick matched its observed
native idle drain. The tick-12180 read reported `autonomous_end_to_end:true`
and `blocked_output:false`. All three API-member probes returned without error.
The surface was deleted and confirmed absent at tick 12181; the owned server
exited with status 0, no owned Factorio process remained, and its separate
write-data directory was removed and its absence verified.

The 0.19.9 merged mechanism (fluid domains over native segment absence,
summed member capacities, drain or drain-free working delivery, 120-tick
bursts) passed the same isolated runtime on 2026-10-03 with the redesigned
drill-fed plant above. Archive SHA-256
`40b9f6fedbb42a107cf3767f311bcb6af4b73cca812c02e27e622c7e81e5c8f3`; after the
external-dependent and burst-evidence fixes the rebuilt archive
`665cb760a921ed65a6b008a63b09638ba12230769133c1a75ba94b410fd9dab0` returned the
same results in both variants. The
`standard` and `pump-low-load` variants each returned
`FACTORY_COMPONENT_AUTONOMY_PROVEN` over 7,200 ticks with
`native_power_required:true`, `power_delivery_samples:360`,
`fluid_activity_samples:3` and no blockers; the standby reads reported
`autonomous_end_to_end:true` and `blocked_output:false`, all three probes
returned, and cleanup was verified. A preceding candidate with only the drain
rule failed both variants on the drain-free electric mining drill
(`bounded_power_delivery_not_observed`), which is why the working drain-free
rule remains.

These receipts cover the exact isolated engineering archive above. They do not
record installation into a gameplay run, a supervisor `GO`, gameplay autonomy,
or benchmark results. Any subsequent gameplay deployment still needs its own
fresh supervised run and matching runtime receipts, including that run's
native steam gate. Node 22 offline verification and independent source review
supplement these receipts; neither substitutes for native behavior.

### Native resumption after the stop rehearsal

Use the existing connected app-server session controls for each exact role,
not a new session or gameplay path. Discover the installed protocol with
`codex-real app-server generate-json-schema --experimental --out <scratch-dir>`
and use the role daemon's existing connection (or `codex-real app-server proxy
--sock <role-daemon-socket>`). Initialize the JSON-RPC connection with
`capabilities.experimentalApi=true`. Retain the exact `threadId` from the role
session and every returned `turn.id`; names, the latest roster entry, and a
supervisor's own thread are not substitutes. The installed 0.159.2 protocol
provides `thread/resume`, `thread/goal/get`, `thread/goal/set`, `thread/read`,
`thread/queue/add`, `thread/queue/list`, `thread/queue/start`, `turn/steer`,
`turn/interrupt`, and `turn/started` / `turn/completed` notifications. A
connection receives a thread's turn notifications only after `thread/resume`
subscribes it to that thread. Recheck the installed
schemas when the runtime changes; a schema establishes capability, not success.

1. Preserve the rehearsal's physical stop, goal pause, turn interruption,
   settled task-owned commands, stopped Astra ledger writes, and fresh physical
   quiescence. Read back each exact paused goal and interrupted/completed turn.
   Pause may itself settle a turn: if an interrupt reports no active turn,
   inspect that exact turn before deciding whether anything remains to stop.
   An interrupt response alone does not prove settlement; retain the matching
   `turn/completed` notification and current thread readback.
2. While each role's goal is still paused, subscribe that exact thread with
   `thread/resume` on the connection that will release GO, and keep that
   connection open through GO. On a thread whose goal is active, with a
   queued GO, `thread/resume` can itself start a turn that consumes the GO; the
   later `thread/queue/start` then fails with `-32600` ("thread already has an
   active or pending turn", 2026-10-02).
   Resume each existing goal with `thread/goal/set` using
   `{threadId, status: "active"}`. Resume can immediately start a continuation
   turn. Interrupt that exact resumed turn as part of the rehearsal and await
   its settlement; it must perform no pilot physical action. Read back the
   active goal and idle thread. Do not start a separate reconciliation turn to
   test readiness. First prove this release procedure on disposable
   non-gameplay sessions through the same native connection mechanism, with
   no Factorio tools; preserve the exact-role capability checks above.
3. Start the recorder and obtain its baseline before releasing either role.
   Submit one `GO` per role with `thread/queue/add` using
   `{threadId, clientUserMessageId, input: [{type: "text", text: <GO>}]}`.
   The pilot's GO text names Astra's exact thread ID, as does any replacement
   pilot's assignment, so the pilot never reads threads to address reports.
   Each role's GO text also carries this line: "Never call list_threads,
   read_thread or wait_threads; after any compaction re-read your goal file and
   SKILL.md (Astra: also notebook/README.md)." No configuration or
   `session-launcher` option filters those coordination tools per action, so
   this text rule is the control.
   Choose and retain one unique client message ID for each role's GO. The
   response's `queuedSubmission.id` proves acceptance only. Read
   `thread/queue/list` for that thread to identify the pending submission;
   queued delivery is not consumption and does not prove a turn will start.
4. At GO, release each pending submission with `thread/queue/start` using
   `{threadId, queuedSubmissionId: <returned id>}`. This consumes the existing
   GO; do not send another GO or an empty `turn/start` reconciliation request.
   Record the common GO timestamp at the first release dispatch, plus each
   role's actual start receipt and recorder tick. Record any assigned absolute
   stop deadline once from that GO boundary. Retries, delayed role starts,
   resumption, and recovery never reset or extend it. If the deadline arrives
   during recovery, execute the explicit-stop sequence, not another release.
   If a connection must subscribe after the goals are active, treat its
   `thread/resume` as a possible start. Read the thread and
   `thread/queue/list` before releasing. If a started turn's `userMessage`
   carries the GO `clientId`, record that as consumption and do not release
   it again. Otherwise interrupt that exact turn, await its `turn/completed`,
   confirm the GO is still listed, and only then release it.
5. Match the returned turn ID and `turn/started` notification to that thread.
   Confirm the pending submission disappears from `thread/queue/list` and the
   turn's `userMessage` item contains the same `clientId` and GO text; retain
   the role's response acknowledging consumption. These are distinct receipts
   for acceptance, pending delivery, consumption, and turn start. Before any
   retry after a timeout or uncertain effect, read the goal, thread, queue,
   and exact turn history (`thread/read` with `includeTurns:true`, or the
   installed paginated turn/item reads). If GO was consumed or a turn started,
   do not enqueue or start it again. If an active/pending turn is reported,
   resolve its identity and settlement before release; never overlap role
   turns or treat an idle roster sample as proof that no start is pending.
6. Observe a later native goal continuation turn after the GO turn ends while
   the milestone remains open. The supervisor does not assign every batch.
   Keep exactly the two persistent roles, one body and FIFO lane: Luna alone
   writes gameplay, Astra keeps its read-only surface and alone writes the
   ledger. The supervisor's native session control is not a gameplay writer.

**Verification evidence and limits (2026-10-02).** The installed Codex CLI
0.159.2 generated the experimental native schemas. Disposable persistent
app-server sessions, using native stdio and connected Unix WebSocket JSON-RPC
transports with every configured MCP server disabled and a read-only sandbox, exercised
`gpt-6-luna` / low and `gpt-6.1-sol` / medium separately. Both rehearsed pause,
interruption, resume, and interruption of the automatically resumed turn.
Their goals read active and threads idle, yet each GO remained in
`thread/queue/list`. Exact `thread/queue/start` removed that submission,
returned a turn ID, emitted the matching `turn/started`, and recorded a
`userMessage` with the submitted client ID. Both answered `GO_CONSUMED`,
completed that turn, and then automatically started and completed a distinct
native goal continuation answering `CONTINUATION`, without another start
request. In the stdio samples, rehearsal/resume interrupted-turn durations
were 6/8 ms for Luna and
4/13 ms for Sol; these disposable timings do not establish live-role stop
latency. Cleanup read both goals paused and threads idle, archived the test
sessions, and observed the test app-server processes exit successfully.

This proves native session resumption and continuation over those transports,
not the running human daemon, live gameplay, physical stop latency, recorder
behavior, or ledger quiescence. Rehearse through the actual connected role route before a live GO.
The release 0.19.1 cycle-2 queued-GO incident is the reported motivation, not
new live validation evidence. Claim live success only after an authorized
supervised run records both roles consuming GO and subsequent pilot physical
work through the ordinary lane. No mod release or deployment is required for
this documentation correction.

For the 0.19.0 role split, measure at `GO+20m` against the 0.18.0 baseline in
`docs/AGENT-PLAY-PERFORMANCE.md`: first `queue_plan` within 3 minutes of `GO`
(was 13.6); pilot model time under 60% of wall time (was 96%); body busy (active
task or queue depth) at least half the time after the first package; at most 3
pilot `find_placement` calls and no identical empty retry; at least 80% of
packages passing pilot revalidation; at least 6 machines and 4 physical edges
(was 2 and 1); no supervisor nudge; and no Sol-to-pilot message.

The parent is the debug supervisor and may diagnose or recover through its
separate surfaces. That authority does not pass to the pilot. Record each
intervention and obtain a fresh structured observation before ordinary play.
Mirror every intervention that touches the game process into the recorder's
events with `runs mark-assisted <run-id> --reason <text>`, the existing
intervention event. That includes raw RCON or console, a temporary surface,
emergency `stop`, teleport, and server or client replacement. Pre-`GO`
interventions made before the recorder exists stay in `supervision.json` only.
The supervisor yields its own turn between recorder checkpoints and records the
structural-growth deltas defined in `AGENTS.md` at each one. No single
supervisor tool call waits longer than 15 s (`write_stdin` included), and a
checkpoint turn ends as soon as its checkpoint is recorded. A steer reaches a
busy turn only at its next step boundary.

For an explicit the owner stop, record each step: call factorio `stop` (cancels the
active task and every queued plan within seconds); in each role TUI run
`/goal pause` and read back the paused state; interrupt any active role turn
with the native TUI stop control or app-server `turn/interrupt` for that role's
exact `threadId` and `turnId`, and read back the interrupted turn; check
separately that no task-owned command or job is still running; confirm Astra
makes no further ledger write; then run recorder FINISH and
`server stop <run-dir>`. The debug supervisor of this contract may use these
native controls on its own role sessions as recorded interventions. A steered
`CANCEL` reaches a busy role at its next step but stops nothing by itself.

Deliver deadline-sensitive or the owner-relayed instructions, such as a stop or a
keep-running decision, with native `turn/steer`
`{threadId, expectedTurnId, input, clientUserMessageId}`. Address the exact
target's current active turn, read with `thread/turns/list` (limit 1). On an expected-turn
mismatch, re-read and steer the new turn; if no turn is active, start one with
that input. Queued delivery waits until the target's turn ends.
`session-status send` has no steer option: for a Codex target it runs
`codex queue`, which is `thread/queue/add`. On 2026-10-02 a keep-running
instruction waited 10.5 minutes behind a busy supervisor turn and arrived after
the stop it was meant to prevent. In debug cycle 7, the owner's stop took 94.5 s to
reach the supervisor and 114.6 s to reach factorio `stop`.

The setup session therefore relays the owner's instructions with the supervisor
tooling's `relay_steer.py`. It resolves the target's daemon socket and thread
from the same managed session status that `send` uses, and keeps the same
`<agent_peer_message>` envelope. It reads the active turn with
`thread/turns/list` and steers it with that `expectedTurnId`. It re-reads once
on a mismatch, and uses `turn/start` only when no turn is active. The relayed
text carries `owner_message_at` and `relay_sent_at`. Confirm delivery by the
`clientUserMessageId` in that turn's `userMessage`. An unconfirmed relay is
read back before any resend.

For an explicit stop, record these fields on the supervisor's `stop_steps`:

- `owner_message_at` and `relay_sent_at`, from the relayed text;
- `delivered_at`, the supervisor's receipt time;
- `factorio_stop_at`, the factorio `stop` receipt;
- `roles_interrupted_at`.

The target is under 30 s from the owner's message to factorio `stop`. Before `GO`,
the setup session steers one no-op token into the supervisor while a tool call
is running. Record its consumption within 15 s in `capability_evidence`. Add no
control file or message store for this.

### Supervisor stall and replacement validation

Follow the authoritative stall contract in `AGENTS.md`; this is a manual
supervised procedure gated by one observation helper, not an executable
supervisor. Before `GO`, record a
confirmed message delivery from the current supervisor to the exact pilot
session. Verify interrupt/retirement and observable inability to resume using
a disposable non-gameplay session with the same session mechanism; confirm
that the route is available for the exact pilot. Do not retire the prepared
pilot as a capability test. Missing delivery or retirement capability must be
resolved before `GO`.

While milestone goals remain open, use fresh valid `observe_local.character`:
`active_task` absent, numeric `queue_depth == 0`, and numeric
`crafting.queue_size == 0` together prove idle. A missing character or required
queue/crafting field, malformed response, stale sample, or failed call is
uncertain, not idle. An absent `active_task` in an otherwise valid complete
character observation is the normal no-task representation. Parked waiting
plans and predecessor-blocked queued plans count as pending work. Inspect a
known plan only with its exact `plan_id`; `plan_status {}` is invalid.

Record receipt timestamps and character position, carried inventory,
task/queue state, and crafting state/progress in existing run evidence. Retain
the last evidenced physical-change/idle-transition timestamp that establishes
the current idle interval across unchanged samples. Advancing ticks and
unrelated factory output do not reset it. If the transition is unknown, such
as between an active sample and an idle sample, report a conservative observed
lower bound starting at the first valid idle sample, not an invented exact
start or the next unchanged sample. Renewed activity resets timing and the
single-nudge state; a run change or uncertain observation invalidates timing.
Re-establish a fresh lower bound after uncertainty rather than counting the gap.

The supervisor's observation helper is the only nudge and replacement gate;
never dispatch on an inline idle predicate. Pipe every fresh `observe_local`
result and its receipt time through the helper, in the same step that may
dispatch. The helper compares the full physical signature (position, carried
inventory, `active_task`, `queue_depth`, crafting state) with the retained one
and keeps the conservative idle lower bound across unchanged samples. It
returns `eligible_nudge` only when the signature has stayed unchanged for at
least 120 s from that bound and no nudge was sent in this interval. It returns
`eligible_replace` from 300 s, under the conditions below.
Reserve the interval's single nudge in the helper (`nudge_sent`, set
atomically) immediately before dispatch, send its unique interval token, and
record the delivery receipt. Failed or uncertain delivery is a capability
problem; read back delivery state before retrying the same nudge and do not
claim a nudge succeeded.

Delivery is not consumption. A `steered:<id>` receipt names the target's
active turn, not a message, and a steer reaches the pilot only at that turn's
next step boundary. Record consumption only when the token appears in a
`userMessage` of the exact pilot turn (`thread/read` or its rollout). At five
minutes, replacement requires either recorded consumption of the token or,
first, one recorded `turn/interrupt` of the exact stale pilot turn. After that
interrupt, native goal continuation starts a fresh turn that sees the queued
nudge, and replacement waits a further 120 s with the signature still
unchanged. Then freshly revalidate continued idleness, interrupt and retire the
old pilot, and confirm it cannot resume gameplay writes. Settle any in-flight
physical call: wait for its definitive outcome or resolve uncertainty
through structured state before proceeding. Interruption does not roll back
committed plans. If emergency cancellation is necessary, record `stop` and its
effects. Then freshly prove absent active work, zero queued work, and zero
crafting. Without both retirement proof and physical quiescence, do not launch
the replacement. Preserve Astra, the one body/FIFO/write path, invalidate affected
state, and give the replacement latest structured state and the open milestone.
Record all interventions; assisted progress and timing are not benchmark proof.

Validate these scenarios against the schema offline, then exercise live
delivery/replacement only in an authorized supervised run:

| Scenario | Required result |
| --- | --- |
| Open goals, no active task, queue depth 0, crafting queue size 0 | Valid fresh evidence starts or continues the idle interval. Closed goals do not trigger intervention. |
| Active work, even with queue depth 0 | No idle claim or intervention; reset the prior interval. |
| Character crafting with no active task or queued plans | No idle claim; crafting queue size greater than 0 is work. |
| Parked waiting plan or predecessor-blocked queued plan, body still | Queue depth greater than 0 means pending work; no idle claim. Read status only with a known exact plan ID. |
| Repeated unchanged character samples while ticks/factory output advance | Retain the original idle timestamp. For an evidenced idle transition at 00:00, unchanged samples at 02:03 and 03:12 report 123 s and 192 s; they do not restart timing. |
| Unknown transition, first idle observation at 02:03 and unchanged sample at 03:12 | Report at least 69 s observed idle, not an exact start before 02:03. |
| Renewed movement, carried-inventory, task/queue, or crafting activity | Reset idle timing and nudge state; a later interval needs fresh evidence. |
| Missing, malformed, failed, stale observation, or run change | Invalidate timing; no intervention based on the uncertain interval. |
| Body moved after the last eligible sample, before dispatch (2026-10-02 13:05) | No nudge: the helper sees the changed signature on the fresh sample and restarts the interval at its receipt. |
| Failed or uncertain exact-pilot message delivery | Record a capability problem, never successful nudge evidence; establish delivery state before retry. |
| Nudge delivered (`steered:<turn id>`) but its token is in no pilot `userMessage` at five minutes | No replacement. Interrupt the exact stale turn once, then replace only after a further 120 s of unchanged idle. |
| Interrupted pilot without confirmed retirement, or unresolved physical call/work | No replacement writer starts. Obtain retirement proof, settle the call, and freshly prove all three idle fields first. |
| Consumed nudge or recorded exact-turn interrupt, confirmed retirement and fresh physical quiescence after five idle minutes | Record replacement intervention; preserve strategist/body/FIFO, invalidate affected state, and resume from latest structured evidence. |

Offline verification proves neither message delivery nor live
retirement/replacement. Claim live behavior only with an authorized supervised
validation and confirmed delivery and retirement receipts.

The native `/goal` owns continuation. Waypoints, batches, plans, and progress
reports are nonterminal. While later-tick milestone proof is absent, immediately
continue whenever productive work or bounded recovery exists. Keep the current
plan and one grounded successor when safe, and end the turn at report
checkpoints with work queued; native goal continuation starts the next batch.
Growth, automation, and packet-sizing policy lives in
`.agents/skills/factorio-player/SKILL.md`; a progress report states the measured
capacity change or quantitatively justifies a short manual bridge.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent ticks are acceptable, then revalidate the newest
state before mutation. Do not add another body, lane, RCON path, raw Lua/console,
teleport, hidden state, or free resources. `stop` is emergency cancellation, in the cases `AGENTS.md` lists.
If a pilot goal terminates after an intervention, retire it before starting one
replacement; never keep two pilots active.

Use the current public schema shown by `tools/list`. Keep the same persistent
pilot across packets. An empty intermediate turn or report does not satisfy the
goal and must not add another action writer.

Watch the run through the ordinary couch viewer client, which the mod makes a
characterless spectator that follows Codex, not through the native `Codex`
client window. The `Codex` client's own character is moved by the mod, and
Factorio client latency hiding mispredicts script-driven walking of a client's
own character, which shows as stutter and snapping on that window only. The
`Codex` client can stay minimized; it must remain connected. During a debug
run, keep the couch client log's `Latency changed to (N)` values below 60 ticks;
a spike to the 254-tick ceiling marks a long server tick.

## Historical Candidate B R7 verified live result

R7 ran the immutable baseline SHA-256
`616de9daf11ffdc03f946dd1f76732f4544539801f0f28db62959bcf8f1eea8e` with
deployed commit `80a5874eabc8d9822e7c8d24dd36b68ece4e26e6` and archive SHA-256
`d8d3600e4eb0a1d0087d1c9810070e514c4491c7abf05e63f01f14f58b3a2106`.
`GO` was `2026-09-03T06:26:52.063455112Z` at tick `23015`; the deadline was
`2026-09-03T06:46:52.065339056Z`. The last ordinary action completed at
`2026-09-03T06:46:24.228Z`, before the deadline. The first read-only frozen sample
completed at `2026-09-03T06:47:08Z` with `source_tick=95498`. No post-deadline
gameplay occurred, and the 15.9-second collection latency grants no grace
or attribution to the deadline.

The frozen sample recorded carried `iron-plate=40`, `copper-plate=10`,
`copper-ore=8`, and `wood=2`, plus `iron-plate=10` in furnace output. Queue
depth, active task, and crafting queue were respectively `0`, `null`, and `0`.
The pre-deadline inspection at `2026-09-03T06:46:16.362Z`, 35.7 seconds before
the cutoff, showed furnace output `iron-plate=9` and one active craft at
progress `0.73`; earlier completed extracts had already established 40 carried
plates. Thus the exact cutoff lower bound is 49 processed iron plates.
Accepted copper and iron drill-to-chest extraction, `copper-plate=10`, and
Electronics were proved before the deadline.

The tenth furnace plate and Steam Power are collection-confirmed. Passive
pre-cutoff processing makes them overwhelmingly likely to reflect work already
underway before the cutoff, but the late snapshot alone is not exact-deadline
proof. Retain 49 as the cutoff lower bound unless tighter master-ledger tick
attribution is established. This remains satisfactory automation-first progress
relative to R5/R6, not a completed rocket objective.

Residuals were manual tree-fuel travel, manual chest/furnace transfers, one
recovered trapped layout, and master ledger/message lag that caused stale
envelopes and false post-deadline attribution. General follow-up remains
state-driven: validate access and accepted output before scaling, use measured
utilization to select the next bottleneck, and derive snapshot attribution only
from authoritative timestamps, ticks, and frozen structured evidence. For a
mining drill, nil `drop_target` before production means runtime binding is still
unknown; a matching non-nil target becomes authoritative after first output.

Current commit `c56a5f5149f381fd0cc88860a24259f3f9b62e89` was published during
R7. It retains the live-proven geometry behavior and adds explicit
pending-first-output plus fueled `build_plan` waiting semantics, but it was not
deployed or benchmarked in R7. This result used no map-coordinate evidence,
fixed route or order, screenshot, raw console, or gameplay cheat.

## Prior verified 0.8.0 live result

- `doctor` passed the complete config, authenticated RCON, protocol, and mod
  checks on Linux Factorio 2.0.77. `connect_status` reported app/mod 0.8.0.
- One `connect_status` call took 109 ms and one radius-30 `observe_local` call
  took 244 ms, 352 ms together. The initial structured state was position
  `(37.5859375, -63.4765625)`, stone 4, and iron plate 2.
- One three-step `run_plan` took 24.392 seconds and completed 3/3: mine coal 5
  at `(37.5, -63.5)`, walk to `(43.5, -68.5)`, and mine iron ore 5 at
  `(43.5, -70.5)`. Its final observation reported position
  `(42.671875, -68.1171875)` and inventory coal 5, stone 4, iron ore 5, and
  iron plate 2.
- `inspect_entity` with `positions: [{x: 31, y: -56}]` took 2.114 seconds and
  reported a healthy stone furnace with status `no_ingredients` and coal 1 in
  its fuel inventory. A packet using obsolete `targets` was rejected by the
  schema before runtime.
- One smelting `run_plan` took 19.458 seconds and completed 3/3: insert iron ore
  5, wait for five iron plates in output, and extract iron plate 5. Its final
  observation reported position `(37.62890625, -63.37109375)` and inventory
  coal 5, stone 4, and iron plate 7.

Each plan was one bounded milestone packet and exactly one MCP call. The pilot
used the plan's final observation without a redundant read. These are completed
live results, not a claim of ongoing gameplay. Gameplay used no screenshots,
raw console, Lua, cheats, or teleportation.

Post-run screenshots are permitted only after the scored run is frozen and only
when structured MCP evidence is insufficient for review. Review all relevant
map areas where items or machines were placed, but treat images as
non-authoritative: they must not contribute coordinates, routes, tactics, or
durable knowledge, and they never support live perception, navigation,
targeting, placement choice, or action selection. Revalidate every finding that
could affect a later run through structured in-game MCP data. This permission
does not authorize couch GUI control or expand the Windows-MCP boundary.

## Observed two-machine setup

The following was verified during the September 2026 live run. Treat the LAN
addresses as runtime inputs, not permanent configuration: confirm them with
`ip address`/DHCP leases before each session.

- The Linux workstation hosted Factorio on its LAN address `192.0.2.117`
  and game UDP port `34197`.
- The couch PC was `COUCH-PC` at `192.0.2.119` and connected with
  Steam's Factorio launch argument `--mp-connect 192.0.2.117:34197`.
  `--connect-to-server` is not a valid Factorio argument.
- The Linux firewall must allow UDP `34197` from the trusted LAN. The tested
  rule was `ufw allow from 192.0.2.0/24 to any port 34197 proto udp`.
  Apply this only through the workstation's supervised firewall procedure;
  do not change router DHCP settings for this validation.
- The prior verified couch install used `agentic-companion_0.8.0.zip` in
  `%APPDATA%\\Factorio\\mods` and an enabled `agentic-companion` entry in
  `%APPDATA%\\Factorio\\mods\\mod-list.json` before joining. The verified couch
  ZIP matched the server archive hash, was enabled, and joined successfully.
- The server's RCON remains private and local: `127.0.0.1:19015`. It is not
  the address the couch client uses.
- Factorio dedicated-server process arguments contain the RCON secret. Never
  print or read full arguments through `ps` full args, `/proc` command-line
  data, WMI `CommandLine`, or an equivalent process-inspection surface. Verify
  health through user-service state, PID, executable basename, and `doctor`
  only, and keep all reported output secret-redacted.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the couch client. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before Steam will launch a fresh connection. Wait for
`factorio.exe` to exit completely before replacing the ZIP: Windows briefly
retained a lock on the old archive during the verified rollout.

Before upgrading an existing 0.9.x save, stop the server and retain an exact
copy of both the save and its matching 0.9.x mod archive. Validate 0.19.9 on a
copy first. Rollback means stopping the server, restoring that paired save and
archive, and confirming the restored version through `doctor`; never open the
only rollback save with the newer mod.

An ordinary SSH `Start-Process` did not place Steam in the interactive console
session. The verified fallback used one limited, interactive, one-shot
Scheduled Task to launch Steam, then removed that task. Without screenshots,
confirm that the Factorio client process has `SessionId 1` and that its log
reaches `InGame`.

The couch display runs at `3840x2160`, and `scripts/launch-native-client.ps1`
renders the isolated client at that native 16:9 size. A recorder may downscale
the captured window to `1920x1080`, but it must fit the complete source without
cropping or enlarging a lower-resolution viewport. Before a timed recording,
verify the live Factorio client area, capture-source dimensions and aspect
ratio, crop/transform state, and representative framing. A non-black Factorio
frame alone is not sufficient evidence of usable framing.

## Viewer-only couch session

The exact `Codex` client must join first. Every other connected identity is
made characterless and placed in spectator mode by the mod; there is no second
body and no administrator or console step. The current mod makes each connected
spectator camera follow the sole Codex body automatically. Codex itself still
walks physically; only the characterless viewer camera follows. Confirm the
normal couch identity has no body or inventory and remains aligned with Codex
during a physical `walk_to` action.

## Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below were collected before release 0.19.9. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.19.9. Complete the fresh run above after installing 0.19.9 before recording a
current-release result.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A 0.19.9 run must instead report protocol v22 and mod/app 0.19.9.
- A fresh MCP process should be used after rebuilding the CLI. The tested
  sequence was `connect_status`, `observe_local`, then an exact-coordinate
  `mine`; the successful physical result increased Codex inventory and
  completed the task. This historical cleanup advice does not authorize pilot
  cancellation: only the supervisor uses `stop` in the cases `AGENTS.md` lists;
  an active task alone is not a reason for ordinary recovery to cancel it.
- If an action reports `empty response from the game` while `observe_local`
  still shows the task, the supervisor restarts the CLI from the build containing
  the RCON response-order fix. Restarting the CLI does not settle physical work.
  Obtain fresh structured state, inspect exact known task or plan IDs through
  the appropriate surface when available, account for pending work and committed
  effects, and resume only the safe remainder. Do not assume that an empty
  response means the enqueue did not mutate state or retry a pending mutation.
- Physical mining requires the selected entity to be updated before
  `mining_state` is enabled. A task that approaches indefinitely with no
  inventory gain indicates a stale mod build; reinstall the current archive
  and restart Factorio.
- The observed couch launch reached `InGame` and the server logged the join.
  A successful network join alone does not prove spectator mode; verify the
  controller in the Factorio UI as described above.

## Optional couch UI navigation layer

For semantic Windows UI navigation, the couch PC was tested with
[CursorTouch Windows-MCP 0.8.5](https://pypi.org/project/windows-mcp/0.8.5/).
This is an optional fallback for non-game couch UI, administration, or
reconnection steps that SSH cannot perform, alongside the existing
AutoHotkey-based `couch-ui` fallback. Neither UI path controls Factorio through
the Codex MCP server. The gameplay pilot remains MCP-text-only: Windows-MCP's
Screenshot capability must never be used for Factorio perception or play.

The tested deployment details are:

- Python 3.12 and `windows-mcp==0.8.5` installed for the Windows user.
- A per-user Scheduled Task named `windows-mcp-server`, running at logon with
  limited (non-elevated) privileges.
- Streamable HTTP bound only to `127.0.0.1:8000`; never expose this listener
  directly on the LAN. If remote use is needed, carry it through the existing
  authenticated SSH connection with a local port forward.
- Telemetry disabled with `ANONYMIZED_TELEMETRY=false` and an empty
  `POSTHOG_API_KEY`.
- The launcher passes this explicit UI-only allowlist:
  `Screenshot,Snapshot,Click,Type,Scroll,Move,Shortcut,Wait,WaitFor,DisplayInventory,App`.
  PowerShell, FileSystem, Registry, Process, Clipboard, Scrape, Notification,
  MultiSelect, and MultiEdit are excluded. Screenshot remains unavailable to
  the Factorio gameplay pilot regardless of this UI administration allowlist.

The installer rewrites `~/.windows-mcp/start-server.cmd`; apply the allowlist
to that launcher after installation and restart only the `windows-mcp-server`
task. If using `config.toml`, write it as UTF-8 without a BOM: Windows
PowerShell's default UTF-8 writer can otherwise cause `Invalid statement` at
startup. Verify with a local MCP `initialize`/`tools/list` request and confirm
exactly 11 tools before adding the server to a client.

The tested endpoint reported Windows-MCP 4.0.1 internally even though the
installed package was 0.8.5; use the package version for pinning and retain
the scheduled-task launcher as the source of the effective runtime options.

## Occupied-belt placement agreement (2026-10-02)

An isolated Factorio **2.0.77** headless reproduction establishes a manual
replacement-check mismatch in the retained shared helper. It does not reconstruct
all state changes or earlier steps in the original 0.19.6 science-inlet incident
at `9138e78c53a4b12e7e6a01b2e479154853dd8340`.

The [2.0.77 LuaSurface API](https://lua-api.factorio.com/2.0.77/classes/LuaSurface.html)
provides `can_place_entity.build_check_type` (default `ghost_revive`) and a separate
`create_entity.fast_replace` option (default false). The physical actions never
request fast replacement. On an unchanged coal-carrying transport belt, the
engine returned these results at both its exact center and an unsnapped supplied
position on the same tile:

| Proposed entity | Manual check | Script check | Ghost-revive check | Ordinary creation |
| --- | --- | --- | --- | --- |
| transport-belt | false | false | false | nil |
| fast-transport-belt | true | false | false | nil |
| underground-belt | true | false | false | nil |
| inserter / burner-inserter | false | true | false | entity |

Clear neighboring tiles passed all three checks and creation. The check and
creation agreed on normal grid snapping in these samples. A script check alone
would admit overlaps forbidden by ordinary manual building. The repair therefore
retains manual admission and additionally requires ghost-revive clearance in
`placement_geometry.can_place`; all existing consumers retain that single owner.
The helper reports its actual engine-query count internally so placement search
accounts for the additional check. MCP fields, range/list limits, FIFO routing,
body checks, reach and item requirements remain unchanged. Occupied-footprint
explanations use at most 65 local entity rows.

### Isolated physical comparison and limits

Two fresh peaceful saves with enemy bases disabled loaded separate instrumented
copies of the predecessor and candidate scripts. Each dedicated server bound
only to loopback with an OS-assigned UDP port, no RCON listener, no public/LAN
advertisement and no connected gameplay client. Both servers exited after their
receipts. No existing run, installed mod, client or pilot was upgraded or stopped.

The engineering fixture generated dry ground, created one real character with
known inventory and three connected east-facing belts, and placed one coal on
the middle belt. It bound the isolated companion accessor to that character.
Because this disconnected fixture did not process player chart requests, a
recorded fixture-only wrapper admitted generated chunks for the path-start chart
check. It retained engine collision masks, geometry, tile queries, normal build
reach and item consumption, excluding only the fixture's own body from its proxy
query as the original code excludes its body by identity. These are assisted
engineering results, not a native-client gameplay run or benchmark evidence.
No such wrapper is part of the candidate mod.

At tick 60 the fixture called the actual `spatial.can_place`, `build.place`
start/tick and `build_plan` start/tick modules. The precheck and occupied attempt
ran on the same world state and tick, before any other placements:

| Structured outcome | Predecessor | Candidate |
| --- | --- | --- |
| Occupied underground-belt precheck | `can_place:true`, `reason:placeable` | `can_place:false`, `reason:blocked by transport-belt` with position |
| Single occupied physical placement | `status:failed`, unexpected creation failure | `status:failed`, named occupied-belt refusal |
| Neighboring underground-belt | Precheck true; `status:done` | Precheck true; `status:done` |
| Two committed belts, occupied third step, fourth clear step | `status:failed`, `placed 2/4`, step 3 unexpected failure, stop-on-error | `status:failed`, `placed 2/4`, step 3 occupied refusal, stop-on-error |
| Initially clear tile occupied by package step 1 | Both initial checks true; step 2 fails after `placed 1/2` | Both initial checks true; step 2 refuses after `placed 1/2` |
| Belt on ore and a ground coal item | Precheck true; physical `status:done` | Precheck true; physical `status:done` |

All three original belt unit numbers, positions, directions, coal counts and
input/output neighbor IDs were identical before checking, after single refusal
and after the partial package. Single refusal left inventory exactly at ten
transport belts and five underground belts. The clear-neighbor success consumed
one underground belt; the partial package then consumed exactly two transport
belts, leaving eight and four respectively. The refused third step consumed
nothing and created nothing; the fourth step was not executed. At tick 120 the
same belt identities and links remained, total carried coal was still one, and
it had moved from the middle belt onto the final belt. This proves preserved
transport in the fixture as well as same-tick item conservation.

Prechecks observe current state; they reserve nothing. The earlier-step conflict
case demonstrates execution revalidation, not transactionality or rollback.
The original incident's exact intervening state remains unknown.

### Source and archive identities

Predecessor source: `65a61fa962a175fb0ab65d6b73a7055bafa406a0`, version 0.19.6.
The candidate's exact mod content is identified by its source archive and helper
SHA-256 below; source publication and active installed runtime remain separate.
The instrumented archive identities snapshot the mod directories actually loaded
by the fixture, including its replacement control script and fixture identity.
Their action and placement modules match the corresponding source archive.

| Artifact | SHA-256 |
| --- | --- |
| Downloaded official 2.0.77 headless archive | `c4efc11529f74d37c96933e291e0db73fd9f5aa4738913d9301b24680b3e947f` |
| Predecessor source mod ZIP | `fd31448db9558b1184d91f70fee4ddca79017f0510399cbd1f15b3cb030f3d4a` |
| Candidate source mod ZIP | `eebf4465e160dd3b009e01a07b78b60141ce3a8f9fb972ffc68dd5f4bed0e6a1` |
| Predecessor instrumented fixture ZIP | `1917580020ca97f64c2a9f897fba388c1aea93d7d2f99a346ab1f74c4604cfd9` |
| Candidate instrumented fixture ZIP | `722829a7c283246b8c6896364ab3845baefe47e80b0aeb7036bc243b93fc1837` |
| Candidate `scripts/placement_geometry.lua` | `88d5f3cbcb647ec761cd2c7c99cf05bd82a672097e8d4600a9faddd2804aa2c6` |

The Lua regression models occupancy shared by checks and creation rather than
an unconditional engine answer. Against the predecessor it fails occupied
precheck, refusal-before-creation, partial-package conservation and earlier-step
revalidation assertions; it passes with the repaired helper. The existing search
harness additionally rejects replacement-only candidates while retaining clear
neighbors, and the range harness still verifies rejection before any engine
queries for invalid or out-of-range requests.


## Adjacent burner-inserter fuel feed (2026-10-02)

Isolated Factorio **2.0.77** headless fixtures reproduced the exact reported
producer `(46.5,-40.5)`, direction `12`, and recipient `(47.5,-40.5)`,
direction `8`. The native drop position was `(47.69921875,-40.5)`.
The recipient collision box was `[(47.3515625,-40.6484375),
(47.6484375,-40.3515625)]`; its rotated selection box was
`[(47.1015625,-40.94921875),(47.8984375,-40.15234375)]`.
Its prototype collision box was `[-38/256,38/256]` on both axes;
prototype selection corners were `(-102/256,-89/256)` and `(102/256,115/256)`.
The producer prototype drop vector was `(0,1.2)` before rotation.

At tick 600, native `drop_target` exactly matched the original recipient unit,
its fuel inventory had risen from zero to **five coal**, and the source chest
had declined from ten to five. The producer began with five legitimate fixture
coal as starter fuel. Separate cardinal copies gave the same later-tick binding
and five-coal transfer, with no character transfers during the measured interval:

| Producer direction | Runtime drop relative to producer | Recipient relative to producer | Recipient direction |
| --- | --- | --- | --- |
| 0 | `(0,1.19921875)` | `(0,1)` | 12 |
| 4 | `(-1.19921875,0)` | `(-1,0)` | 0 |
| 8 | `(0,-1.19921875)` | `(0,-1)` | 4 |
| 12 | `(1.19921875,0)` | `(1,0)` | 8 |

### Native recipient query and limits

Collision-box containment rejects these fuel edges: the drop overhang is
`13/256`, exceeding the predecessor's `1/128` rounding allowance. Selection-box
containment is also insufficient to describe the native query. Custom-vector
probes moved only diagnostic endpoints and measured binding without claiming
item transfer. Burner inserters and chests remained targets up to the last
1/256 position before the next tile; selection boxes differed between them.

The engine intersects collision boxes with the endpoint tile inset by
**12/256 tile**, including touching edges. Tiny off-grid chest collision boxes
of half-width `1/256`, with much larger selection boxes, discriminate the inset:
for endpoint `(1,y+0.5)`, target centres `1.0390625` and `1.9609375` did not bind,
while `1.04296875` and `1.95703125` bound at the exact closed edges.
Same-tile location and selection overlap alone therefore do not suffice.
This agrees with the [Factorio staff explanation of the inset query](https://forums.factorio.com/viewtopic.php?p=703599#p703599);
the measurements here independently establish it for 2.0.77.

The existing shared resolver now applies this query to inserter pickup/drop
geometry. Mining-drill point containment retains its measured rounding allowance
and the existing cardinal drill/furnace boundary regressions. Planned recipient
search, batch relations, and existing/earlier-planned build targets use the same
geometry; physical collision and placement clearance remain separate.
Multiple eligible recipients stay ambiguous, and burner inserters remain
ineligible pickup inventories. Preflight remains provisional: neither binding
nor geometry proves acceptance of an arbitrary item, factory connectivity, or
autonomy. Later-tick exact runtime identity still determines physical success;
nil, wrong or invalidated inserter targets fail while committed effects remain.

### Fixture identity and source readiness

The minimal diagnostic mod depended only on base 2.0.77. It created peaceful dry
ground with enemy bases disabled, test entities and finite fixture inventory.
No gameplay client participated. Each owned server bound only to loopback on
port zero, with no RCON, public or LAN advertisement, and exited after its
receipt. No active save, installed companion, gameplay writer or client was
modified or restarted. These are assisted engineering results, not gameplay
or benchmark evidence.

The final comparison evaluated 78 later-tick native cases. The candidate query
agreed with native target identity in all 78; the predecessor rejected all five
adjacent fuel-feed examples. Entity counts and recipient fuel counts were
unchanged across every read-only query. The resolver context used the source's
position and actual native force/surface, without introducing a gameplay body.
Because disconnected headless fixtures do not process player chart requests,
the comparison copies substituted generated-chunk checks for chart checks.
That fixture-only substitution is absent from source; force ownership and all
collision geometry remained native. Initial unmodified checks honestly reported
`uncharted`; they were not counted as successful geometry comparisons.

Source baseline: `0777538bb4eaadef6bea89eb18b44d5fbcf27845`, version 0.19.7.
The following hashes identify the final candidate mod snapshot and the exact
instrumented fixture loaded for comparison. Source publication and deployment
are separate; the candidate companion archive was packaged offline, not installed
in an active run.

| Artifact | SHA-256 |
| --- | --- |
| Official 2.0.77 headless archive | `c4efc11529f74d37c96933e291e0db73fd9f5aa4738913d9301b24680b3e947f` |
| Candidate source mod ZIP | `3f605743123c9c4e07aad842b23c2220c7f6b85739967470f5381b6fae419da7` |
| Candidate source endpoint helper | `a4ac02fd5253b5d6d3aed52352124262e75ff47d6fad9dbf4763a127f73feb1c` |
| Instrumented diagnostic mod ZIP | `f9500a3c8423635777dcf973a6b4f8350fe6cb040001662ffff004d143aa964d` |
| Fresh comparison seed save ZIP | `204872c122ed655a384d3305f705562b67b5fbf9afd7783e956b3094d4e17684` |

The new Lua regression fails against the predecessor for all four existing and
planned adjacent fuel arrangements and the discriminating inset-edge cases.
Physical-action regressions retain exact later-tick binding failures and item
consumption for existing and earlier-planned narrow recipients in every cardinal
rotation. The old action fixture was shifted to tile centres so its synthetic
one-tile inventories no longer straddle four native query tiles.
Review regressions additionally cover bounds at adjacent chunks, mixed existing
and planned ambiguity, and same-name replacement of an earlier committed pickup
or drop recipient. Build plans retain that exact created entity and refuse a
replacement before committing the producer; prior effects remain recorded.

## Release 0.19.7 cycle-7 accidental pilot cancellation

The captured incident evidence for an earlier issue reports a supervised debug run on
release 0.19.7, source commit `0777538bb4eaadef6bea89eb18b44d5fbcf27845`.
The pilot invoked `stop` during ordinary gameplay without a the owner stop request.
The native completed result at `2026-10-02T18:45:04.326Z` was `cancelled2`;
the pilot then reported plans 31/32 cancelled. A subsequent fresh structured
character observation at tick `141409` showed pending physical work and resumed
continuation. These are attributed incident facts, not a new live reproduction
or proof of physical quiescence. The run remains assisted; its progress and
timing are excluded from benchmark evidence.

The source guidance offered ambiguous cues: the shared skill said “Stop only
on an explicit the owner request,” while the tool description suggested cancellation
after a TUI interruption. Those are instruction defects; whether either caused
this model's tool selection is a hypothesis, not established by the cancellation
receipt. The correction reserves the tool to the supervisor, prohibits its
ordinary pilot use, and directs recovery to fresh state, exact known plan IDs,
retained effects, and remaining safe FIFO work without rollback.

Offline verification covers contract consistency and retained cancellation
mechanics, not improved live model behavior. Review ordinary continuation,
monitoring timeout, and partial-plan recovery as non-cancelling pilot paths;
review explicit the owner stop, pre-`GO` retained-work reconciliation, and emergency
replacement as the existing recorded supervisor paths. Startup still loads the
role goal and hard skill; after compaction roles re-read them before other calls.

Source publication, loaded role guidance, installation, and observed gameplay
results are separate evidence. This instruction/tool-description correction
requires no mod deployment, server replacement, or active-run restart. Any live
effectiveness validation requires an authorized fresh supervised run recording
exact loaded source/runtime identity and all interventions; it remains excluded
from benchmark evidence. Publishing corrected source does not establish that
an existing role or MCP process has loaded it.
