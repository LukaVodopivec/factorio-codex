# Live validation

This runbook validates release **0.26.0**. Prior live evidence remains historical
until the 0.26.0 run is recorded. The Linux workstation has no dedicated
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
   Console-backed RCON disables achievements for the save. Play reaches
   every planet: rockets, remotely built space platforms, and the body's own
   trips by rocket, platform and landing pod.
4. From the couch PC, run
   `scripts/launch-native-client.ps1 -Address <server:port>` to connect the
   isolated native client (highest graphics quality at 3840x2160) as the real
   player named `Codex`, before
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

For the 0.22.3 release (other planets), record these observable checks
(offline fixtures cover them; none is live evidence yet):

- `ping`, `fifo` and `factory_status.body` report the body `state`
  (`on_surface`, `aboard_platform`, `in_transit`, `dead`) and its surface;
  `connect_status` stays connected while the body is aboard or in a pod.
- `set_platform_route` sets a platform's stops and wait conditions at once
  with the body unmoved; `platform_status` reads back the schedule, trip,
  speed and `paused`, and a locked location is `LOCATION_LOCKED`.
- `travel {to: "platform:<n>"}` waits for a ready rocket, walks to the silo
  and rides up; `travel {to: "<planet>"}` waits aboard until the platform is
  at that planet and lands by pod. `next_event` reports each `travel_phase`,
  `platform_arrived` and `body_surface_changed`; the travel step counts in
  `queue_depth` throughout, and `stop` during the wait leaves the body aboard.
- After a surface change, an unfinished plan for the old surface ends with
  `SURFACE_LEFT` and leaves `queue_depth`; work queued after the `travel`
  step runs on arrival. The strategist's package for another surface shows
  `waiting_surface` in `orders` until the body is there; a package holding
  `travel` is rejected by `ledger-apply`.
- On another planet, `factory_status` details that planet and lists Nauvis
  in `elsewhere`; `factory_status {surface: "nauvis"}` and `map_summary`
  read Nauvis in full; upkeep and charting act only on the body's planet.
- Labs are fed only with packs of the active research they accept; a lab and
  pack that took nothing are not retried for 600 ticks; with no research
  active no lab is fed and `factory_status` shows a `research_idle` problem.
- `find_placement` with `fluid` finds offshore pumps on lava or the
  ammoniacal ocean; `build_block` `power` refuses with
  `NO_WATER_ON_SURFACE` on Vulcanus; a building whose surface conditions
  fail reports `SURFACE_CONDITION`; `production_requirements` lists
  `roots` per planet.
- Upgrading a 0.22.1 or 0.22.2 save keeps its queued plans and jobs, and a
  ledger package stored before protocol 28 is read as `nauvis`.

For the 0.22.2 release (rocket and space platform), record these observable
checks (offline fixtures cover them; none is live evidence yet):

- `platform_status` lists every platform at no cost; `detail: "full"` for one
  platform returns its foundation rows, hub contents and requests, entities
  and `ghosts.missing`, and works on the strategist's read-only surface too.
- `create_platform` answers at once with a platform `waiting_for_starter_pack`
  over the body's planet; a second platform of the same name is `NAME_TAKEN`.
- `launch_rocket` with no ready rocket fails at once with `ROCKET_NOT_READY`
  and the part count, before the body moves; with a ready rocket it fetches the
  cargo, walks to the silo and launches, and `next_event` then reports
  `rocket_launched`, `platform_state_changed` and `cargo_delivered`.
- `set_requests {target: {platform}}`, `set_recipe`, `configure_entity` and
  `build_layout` with `platform` leave the body where it stands; the direct
  `set_requests`, `set_recipe` and `configure_entity` tools with a platform
  answer at once (also during a human hold), and plan steps with `platform`
  complete when the FIFO reaches them.
- `get_items` takes items from a cargo landing pad; `inspect_entity` on a
  silo shows its rocket's parts, cargo and weight, and on a landing pad its
  stock and requests.
- `ping` shows no `world_policy_errors` after a platform is created, and the
  platform surface keeps its asteroids (no world-policy write reaches it).
- `progression_status` trigger technologies carry a `hint` (for
  `space-platform`: create_platform, then launch_rocket the starter pack).

For the 0.22.1 release, record these observable checks (offline fixtures
cover them; none is live evidence yet):

- From a body standing on a shoreline (its centre on the walkable margin of a
  water tile, `path_start` `state=blocked`), an `insert_items` and a
  `build_layout` step whose target is far away walk there and finish. Record
  the body position and the step's diagnostics `route.phase` each second: the
  body may step to a dry tile centre first, then follows the native path along
  the shore without stopping at each margin tile.
- A start no direction clears fails its step in a few seconds with
  `START_COLLISION` (the outcome names `path_start`, the body position and the
  `escape_targets` tried), never with `plan exceeded its ... active budget`.
- A step whose body position, inventory, hand-crafting, mining and step state
  stand still for 60 seconds of game time fails with `STEP_STALLED`, naming
  the action and its phase, and the next queued plan starts. `wait_for_item`,
  `wait_for_research`, a hand-crafting queue that advances and a human hold
  never produce it; a `STEP_STALLED` on a step that was making real progress
  is a defect to record with the step's action and phase.
- A step in flight when a 0.22.0 save is loaded with 0.22.1 finishes or fails
  with a code; it does not raise a script error.

For the 0.22.0 release, also record these observable checks without
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
- Neither role calls a thread-reading tool after `GO`, each role's notebook
  folder is non-empty, the pilot sends no reports, and the ledger is never
  read by shell.
- A package the strategist writes starts within about 5 s with no pilot turn: its plan
  appears in `activity_log` with source `package:<id>`, and a package the mod
  check rejects appears as `package_failed` in `next_event`.
- `factory_status` stays under about 6 KB and costs under about 8 ms of Lua
  time at 300 machines (60 UPS holds); `since_tick` returns only changed lines
  and problems. Each line's `state` matches what the machines do: starve a
  line, stop its fuel, block its output, and cut its power in turn.
- Frame time: the game log carries one `rpc <method> Duration: …` line per
  RPC and one `on_tick 600 ticks Duration: …` line per 600 ticks (Lua time,
  logged only). On the upgraded save, `factory_status.registry_ready` and
  `patches_ready` turn true within about a minute of load; after that no
  `factory_status`, `event_state` or `activity_log` line exceeds about 8 ms,
  and the 600-tick aggregate averages well under 8 ms a tick at 200 machines.
- `build_layout` and each `build_block` kind (`mining`, `smelting`, `assembly`,
  `power`, `labs`) build end to end from a dry run that matched; auto-supply
  takes from a chest and from a belt before crafting, and placement clears
  trees and rocks in the footprint.
- Heavy reads run as jobs: a `map_summary`, a full `observe_local`, a route
  search and a `build_block` dry run inside the factory each return one result
  (a site or a definite no-site answer, never `SITE_SEARCH_INCOMPLETE`) while
  no game-log `rpc` line for them exceeds about 8 ms.
- Blueprints: `blueprint_capture` of a working block lists its entities and
  cost and changes nothing in the world; `blueprint_place` with `check_only`
  names collisions, missing items and the nearest free position; in mode
  `hand` the body builds it with real walking, reach and inventory; in mode
  `ghosts` it places only ghosts and no items appear. A package that starts
  with `blueprint_capture` captures after its `after_package_id` package ends.
- `move_entity` moves an own furnace or assembler with its fuel, ingredients,
  recipe and direction restored; `explore` toward a resource stops once a
  patch is charted in view; one `connect_entities` call lays a route of more
  than 25 pieces with an underground hop past an obstacle.
- `craft_items` returns at once and the body walks while crafting; a later
  step that needs the item waits for it. `start_research` with a list queues
  it in order, and `next_event` reports `research_finished`.
- Every cancel appears in `activity_log` and the server log with its
  `origin` (`stop/<role>`, `<tool>/run_plan-abort`,
  `<tool>/direct-task-timeout` or `<tool>/<role>`), where the role is the one
  its MCP process was started with (`--role`); `unknown` means a session was
  started without it.
- Loading a copy of a 0.21.1 save that still has queued plans and running
  jobs (taken before any stop) with 0.22.0 keeps them queued and finishes the
  jobs, and removed actions complete as `REMOVED_ACTION`. The live upgrade
  procedure still stops first.
- `factory_status` line causes name the fluid, `no_recipe`,
  `recipe_not_researched` or `burnt_result`; `no_heat` and `disabled` appear
  where a machine is cold or disabled. Each power row splits production by
  source; while demand exceeds `sustained_w` it gives `add_to_cover`, and
  building what it names makes `headroom_w` non-negative. `sections:
  ["logistics"]` lists robot networks under about 900 bytes and the default
  read omits it.
- `configure_entity` sets a filter inserter's filters and a chest's slot limit
  with the body walking into reach; repeating it returns `changed: []`.
  A `build_layout` entity with `settings` comes out configured,
  `inspect_entity` shows the settings, `move_entity` keeps them, and a
  blueprint placed as ghosts carries them.
- `place_tiles` with `check_only` counts the items an area needs; laying
  landfill takes one item per tile, nearest tiles first, walking along, skips
  tiles that already have it, and names the item to use for a tile it cannot
  cover. No game-log `rpc` or `on_tick` line exceeds about 8 ms while it runs.
- `set_requests` on a requester chest outside roboport coverage returns
  `network: null`; inside coverage only robots deliver, and the body's
  inventory does not change.
- `extract_items` with `inventory: "fuel"` or `"modules"` takes only from that
  inventory, and a role the building lacks fails `INVENTORY_NOT_PRESENT`
  listing those it has. A `flush_fluid` step empties a pipe system;
  on a crafting machine it fails `NOT_FLUSHABLE`. An `equip` step wears armor
  and fits equipment from the inventory, which loses those items.
- None of the new tools or steps starts a `human_control` hold: nothing uses
  the cursor or opens a GUI.
- `inspect_entity` reads up to 64 positions and counts the rest as omitted; a
  long `find_placement` search returns its result, not a pending marker.
  Blueprint tools work before construction robotics is researched and say so.
- With the FIFO empty, or holding only a parked wait, and a plan finished
  since the last stop, a dry burner machine, or a working one on its last
  fuel item, is refuelled by `upkeep` within about 60 s while coal is in
  stock, and a queued plan takes over at the next step boundary. Beside a
  parked wait the upkeep plan ends with a walk back to where the body stood,
  taken before a queued plan gets the body.
  Right after the rehearsal stop, upkeep waits for the first plan to finish.
- Both roles' reasoning summaries and messages appear in chat and in the panel
  within about 10 s, and the panel does not start a takeover hold.
- `map_summary` `include` sections (`stockpiles`, `sites`, `patches`, `power`,
  `problems`, `flows_all`) name a site and its stock beyond 30 tiles from the
  body and nothing in an uncharted chunk; `inspect_entity` there returns
  `remote: true`, and a mutation at that position still fails on reach.
- `pickup_items` on a plain transport belt is an exact conserved transfer from
  the targeted belt tile, not native picking: with the body within
  `item_pickup_distance` of the belt's centre, exactly the requested count
  leaves that tile's lines and the same count enters the main inventory; a
  count that cannot fit, a body out of distance, or any other belt type is
  refused before removal, with no spill. Ground stacks use native picking.
- Hand-mining a resource that an own drill mines returns `drill_produced: true`
  with `drills` and, when available, `stockpile_total`.
- An underground belt pair placed with `belt_to_ground_type` `input` then
  `output` reports the output end paired with the input end; the offline
  fixtures do not verify the output end's direction. A `belt_to_ground_type`
  on any other item fails before walking.
- Read-only results carry `fifo`; after more than 30 s of idle body the pilot's
  next read shows the `body idle` hint and the pilot queues work before reading
  further.
- Growth is input first: from the run recorder's samples at `GO+20m` and
  `GO+60m`, record machines by entity, lines (running, self-sustaining,
  hand-fed), and ore and plates produced per minute. Cycle-10 targets (cycle 9
  in brackets): 40 or more machines at `GO+60m` (about 14); body busy 60% or
  more of the time (6% at `GO+20m`); pilot calls per machine built under 8
  (about 25); validation waits 0 (5); pilot reports 0 (31); ledger reads by
  shell 0 (30); no dry burner machine for more than 60 s while coal is in
  stock; server at 60 UPS with no client drops. Science is not hand-crafted
  while plate production per minute is below its consumption. Report both the
  last 5-minute interval, where a stall shows as 0, and the average since the
  recorder baseline. Take the sample captured nearest `GO+20m` and `GO+60m` by
  wall clock: the recorder baseline precedes the `GO` receipt by about 20 s.
  Recorder flow rows are capped and must be labelled partial.
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
- A `wait_for_item` beyond 30 tiles reads its target remotely when it is an
  own-force machine in charted land. Otherwise it fails immediately instead of
  consuming its timeout and never walks: `WAIT_TARGET_GONE` when it read its
  target before and the charted spot holds no own machine any more, else the
  physical-distance correction. An insertion that accepts only
  part of a request terminates as `partial`, reports requested/inserted/remainder
  counts, preserves the useful accepted amount, and does not execute dependent
  steps.
- Queue and plan responses carry a self-describing `terminal` state and exact
  `next_action`; a terminal continuation handle is never waited a second time.
- A plan with `observation_detail=none` returns compact outcomes, execution
  metadata, and inventory deltas without an embedded observation. An explicit
  compact request retains bounded detail and omission counts; a terminal
  observation is never full (call `observe_local` for that).
- A bounded `plan_status` wait returns on a meaningful step outcome, waiting
  state, or terminal result. A monitoring timeout does not cancel the plan and
  returns a self-describing continuation.

## Persistent two-brain, one-writer contract

The dedicated server and agent session run on the headless workstation, while
the exact `Codex` client and characterless spectator/follower run only on the
couch PC. Do not launch a local GUI as a recovery shortcut.

The fresh supervised-debug topology has exactly two persistent reasoning
sessions and one physical writer. Start the sole gameplay pilot as
`gpt-6-luna` with `low` reasoning and fast mode enabled. Start the persistent
strategist as `gpt-6.1-sol` with `medium` reasoning at normal speed and expose
only the disabled-by-default `factorio-readonly` MCP server to it; disable the
full `factorio` server in that the strategist session. The strategist owns NOW/NEXT/LATER and the
architecture, and is the sole atomic writer of one compact `operations.json`,
including its initial revision. The ledger is the strategist's only channel to the
pilot. The strategist designs build packages of whole blocks or this run's blueprints,
dry-run with `check_only` (the only coordinates in the ledger).
The pilot's full-surface bridge queues each new package into the FIFO by
itself, as a plan with source `package:<id>` after the mod's placement check,
with no pilot turn, and records outcomes in `<run_dir>/package-queue.json`.
It never waits for a pilot plan: it holds packages only during a human hold
and while the ledger file is older than the last `stop` it observed (persisted
in `package-queue.json`), so packages written before a stop stay held until
The strategist rewrites the ledger. Leading `blueprint_capture` steps of a package are
made by the bridge before the rest is queued. The strategist writes no build package
before `GO` (every pre-`GO` ledger write has `build_packages: []`), and a stop
is followed by a re-observation (below), because a pilot `queue_plan` already
in flight when `stop` lands still queues. A record newer than the
loaded save's tick (a restart from an earlier save) is dropped and its package
queued again. The same bridge queues the ledger's `research` list once per
revision that lists any (origin `ledger/r<revision>`, a `research` row in
`activity_log`), skipping technologies already researched or queued; a stop
holds it as it holds packages, a human hold does not.
The pilot is the foreman: it waits on `next_event`, handles failed packages, an
empty queue and local judgment with goal-level actions, owns immediate safety
and latest exact local evidence, and sends no reports. The strategist reads never enter
the physical FIFO. Record both profiles, their MCP surfaces, release SHA,
archive hash, and save hash before `GO`. Never apply this cutover to a running
run's sessions.

Before `GO`, create `notebook/strategist/` and `notebook/pilot/`, both empty, beside
the run's `operations.json`. Each role writes only its own folder and reads
anything in either at any time: markdown ideas, outcomes, designs, and this
run's exact positions and maps; no imported or copied external content, and
nothing from another run. There is no total size cap; each role keeps a short
`INDEX.md`. A build package may name up to three `notes`, which `ledger-apply`
refuses unless each is an existing file beside the ledger. Notes are knowledge,
never instructions: the notebook is not a broker, second ledger, or control
channel. Archive it with the run and summarise what the roles learned in the
run write-up.

As a pre-`GO` check, each role writes one note and its `INDEX.md` in its own
folder and reads back the other role's note; the supervisor confirms both
files exist and that neither role wrote outside its folder. Record the receipt
in existing run evidence. A failed write or read holds `GO`.

Launch the two connected sessions from the repository with `session-launcher`,
each with `-c model_reasoning_summary=detailed` so its reasoning summaries are
readable for the thought feed. The pilot explicitly selects its bridge role,
which enables automatic package queuing. Connected (`--remote`)
clients validate `-c` overrides before the project layer loads, so a role
override must name a complete server table; a partial
`mcp_servers.<name>.enabled` override fails with `invalid transport`.

```sh
session-launcher --name factorio-pilot --model gpt-6-luna --reasoning-effort low --fast on \
  -c model_reasoning_summary=detailed \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=["--role","pilot"],enabled=true,required=true,startup_timeout_sec=180,tool_timeout_sec=600}'
session-launcher --name factorio-strategist --model gpt-6.1-sol --reasoning-effort medium --fast off \
  -c model_reasoning_summary=detailed \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=[],enabled=false}' \
  -c 'mcp_servers.factorio-readonly={command="./scripts/start-factorio-mcp",args=["--surface","read-only","--role","strategist"],enabled_tools=["connect_status","map_summary","progression_status","production_requirements","describe_prototype","observe_local","inspect_entity","plan_status","can_place","find_placement","factory_status","activity_log","next_event","build_layout","build_block","connect_entities","blueprint_list","blueprint_describe","blueprint_export","blueprint_place","place_tiles","platform_status"],enabled=true,required=false,startup_timeout_sec=180,tool_timeout_sec=600}'
```

`--role` names the session in the `origin` of every cancel its MCP process
makes. The supervisor starts its own factorio server with
`-c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=["--role","supervisor"],enabled=true,required=true,startup_timeout_sec=180,tool_timeout_sec=600}'` before it rehearses
`stop`; a server started without one reports `unknown`.

Before relying on the feed, confirm on a throwaway session that `gpt-6-luna`
and `gpt-6.1-sol` emit reasoning summaries with that setting, and record the
setting in the role-profile evidence. If a model emits none, its assistant
messages are the feed.

The launch flags express requested settings. `--fast on` requests
`service_tier="priority"` plus `features.fast_mode=true`; `--fast off` requests
normal service. Neither a launch flag nor a successful update is role-profile
confirmation. Follow the native readback procedure below before `GO`.
Start each with its checked-in role goal; the pilot takes no physical action
before `GO`. Confirm the strategist lists exactly the twenty-two configured read-only tools
(`build_layout`, `build_block`, `connect_entities`, `blueprint_place` and `place_tiles` there are dry runs only) and cannot list any
movement, transfer, crafting, placement, research mutation, plan
enqueue/run/cancel, or stop tool before `GO`, and that the pilot has the full
surface and no read-only server.

Before `GO`, verify the requested fresh save and release hashes, permanent
peaceful mode/enemy bases disabled, exact native player, viewer, and one
body/lane/writer. Archive the previous run's `operations.json` and
`package-queue.json` into that previous run's directory and verify the current
destinations are absent. The bridge reads the ledger at
`<run-dir>/operations.json` of the server `server start` started. Give the strategist
that absolute path and the exact `run` object (`id`, `release_sha`,
`baseline_save_sha256`, `save_identity`, `created_at`, `roles` per the ledger
schema: `{"pilot":{"model":"gpt-6-luna","reasoning":"low","fast":true},`
`"strategist":{"model":"gpt-6.1-sol","reasoning":"medium","fast":false}}`; a ledger
written before 2026-10-05 keeps its recorded `gpt-6-astra`), and
have the strategist create it by piping an
`{"init": true, "run": <that object>, "source_tick": null, "update": ...}`
envelope to `node_modules/.bin/tsx companion/src/cli.ts ledger-apply --ledger
<absolute operations.json path>` from its worktree. Fill `update` with the
mutable fields (`phase`, `bottleneck`, `latest_measured_capacity`, `task_list`
with NOW/NEXT/LATER, `assumptions`, and `build_packages: []` (required for
every write before `GO`; every later update restates the list). Verify the
receipt returns `status: "applied"`, revision 1, and the submitted source
tick, that the persisted schema-2 ledger has mode `0600` and an empty
`build_packages`, and that `<run_dir>/package-queue.json` is absent or has no
records. Initialization refuses every
existing destination without replacement. Later updates use the
`{run_id, save_identity, source_tick, update}` envelope and require a newer
tick. Never hand-seed the ledger: The strategist is its sole atomic host writer.

Rehearse the stop sequence below on the live role sessions without stopping the
server; a role turn must end within about five seconds of pause plus
interrupt. Then resume both role goals through the native procedure below,
pass the notebook check above and the takeover rehearsal below or its recorded
skip, and only then start the recorder; an active goal plus an idle thread
does not prove that queued `GO` will start a turn. At `GO+20m` record the GO+20
recorder checkpoint as the run's comparison snapshot without stopping
anything; assisted debug progress is still not benchmark evidence. Continue
past 20 minutes toward the assigned milestone (currently sustained Nauvis
production: lines that `factory_status` reports `running` and
`self_sustaining` at the next two recorder checkpoints, plus research consuming
produced science); Candidate B and R1-R7 freeze rules are historical unless
The owner starts a benchmark.

### Resume with a mod upgrade

To continue a run's factory with a new release instead of a fresh map:

1. Stop the old run with the explicit-stop sequence below (factorio `stop`,
   both goals paused, active turns interrupted, recorder finished, `server
   stop <run-dir>`), recording each step. Its final `save.zip` holds the
   factory.
2. Build the new release (`npm ci && npm run build && npm run package:mod`)
   and create a new run directory with `server create <new-run-dir>`, which
   installs the new mod into its run-local mod directory. Replace its
   `save.zip` with the old run's final save, unchanged, and copy the old run's
   `notebook/`. The supervisor tooling's resume path (`--resume <old-run-dir>
   --allow-upgrade`) does exactly this and refuses an upgrade it was not told
   to allow.
3. Update the couch `Codex` client to the same mod version, then
   `server start <new-run-dir>`; it refuses a protocol or mod version mismatch.
   Confirm `connect_status` versions and that `observe_local` shows an idle
   body. A plan step saved by an older release that no longer exists completes
   as a no-op with code `REMOVED_ACTION`; treat every pre-upgrade plan ID as
   invalid for `after_plan_id`. If an active task or queue depth remains, call
   `stop` and re-observe until idle.
4. The old run's `operations.json` and `package-queue.json` stay archived in
   its directory. The strategist initialises the new run's ledger from fresh reads
   (packages from the old ledger are not queued again); the copied notebook
   continues, because a resumed save of the same factory continues its run.
5. Spawn the role sessions with this release's settings (for 0.22.3:
   `-c model_reasoning_summary=detailed` and the twenty-two read-only tools
   above) and their updated goal files, redo the role-profile readback, start
   the recorder with `--pilot-rollout` and `--strategist-rollout` (a later
   replacement writes its rollout path to `<run_dir>/rollouts.json` as
   `{"pilot": path, "strategist": path}`, which the recorder follows), and release
   `GO` through the native procedure below. Record the upgrade as an
   intervention.

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
transport to the supervisor; the strategist's only channel to the pilot remains the ledger.
All required profile fields fit this compact projection. If fuller native output
is needed, the supervisor reads it through the existing session transport and
records it in existing run evidence; do not add a store or channel.

If preparation changes a role profile, retain the update receipt, end that
turn, and obtain a fresh native read in the subsequent turn. Require both
`current_turn` and `next_turn` to match the pilot / low / Fast (`priority` in the
validated runtime) or the strategist / medium / normal (`default` in these probes,
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
| the pilot, 01:14:15 | the pilot / low / priority | the pilot / low / priority | true / false | Pilot selected Fast profile confirmed; no GO while Sol report absent. |
| Sol delayed until 01:14:42 | Sol / medium / default | Sol / medium / default | true / false | Both reports now consumed; normal tier and true flag retained separately, not classified as a bug. No gameplay GO was sent. |
| Sol requests the pilot/low/fast:true, 01:14:49; same-turn read | Sol / medium / default | the pilot / low / priority | true / false | `changed:true`, `effective:next_turn`; preparation incomplete despite update success. |
| Subsequent turn, 01:14:54 | the pilot / low / priority | the pilot / low / priority | true / false | Fresh native read confirms application after the turn boundary. |
| Requests Sol/medium/fast:false, 01:14:56; same-turn read | the pilot / low / priority | Sol / medium / default | true / false | Disabling Fast selects default for next turn while selection capability remains enabled. |
| Subsequent turn, 01:15:00 | Sol / medium / default | Sol / medium / default | true / false | Fresh normal profile consumed; true flag is capability evidence. |
| Separate session with features.fast_mode=false, 01:15:05 | Sol / medium / null | Sol / medium / null | false / false | Controlled feature-off probe changes the enabled flag; null tier remains qualified, not normal-profile confirmation. |

The supervisor withheld profile approval while Sol's report was outstanding
for 27 seconds, then consumed both structured reports. The delay was controlled
by requesting Sol's read after the pilot's; it does not test transport congestion.
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

### The owner takeover rehearsal before GO

The owner may take the Codex body over by mouse and keyboard at any time, through
the native `Codex` client window on the couch PC. Real control input on that
client while it is in its character (movement, mining, building, rotating,
crafting, item transfers, opening a GUI, holding an item in the cursor) parks
the FIFO dispatcher, and the mod writes no walking, mining, or picking state.
Mouse hovering, camera movement, and looking around in map or remote view do
not. Plans are not cancelled and keep their order, `queue_plan` is still
accepted, and hold ticks are charged to no plan or wait deadline. About 5 s
(300 ticks) after the last such input, with no GUI open and the cursor empty,
the dispatcher resumes, and a step that depended on the body position re-plans
from the current position. `afk_time` is not the signal: on native 2.0.77 the
bot's own walking resets it whenever the view scrolls under a resting mouse
cursor.

The rehearsal needs the owner's real input, so it runs only when the supervisor's
assignment says in so many words that the owner has agreed to do the takeover
rehearsal now; "The owner is watching" is not that. This applies to fresh and
resumed runs alike. Otherwise the supervisor verifies
`character.human_control: false` on one fresh `observe_local`, records `human_idle_ticks` and the rehearsal as skipped in
existing run evidence, and does not hold `GO`; the takeover acceptance item
stays unproven for that run. Never simulate the owner's input.

When it runs, rehearse it once before that run's `GO` on the live server with the supervisor driving the plan, since the pilot acts only
after `GO`:

1. Queue one harmless bounded plan (a short `walk_to` and return) and confirm
   `fifo.human_control: false`.
2. The owner moves the character in the `Codex` client. Within about one second an
   `observe_local` shows `character.human_control: true`, a small
   `human_idle_ticks`, the plan still queued or active, and no position change
   the mod caused.
3. Queue a second plan during the hold; it is accepted and queued.
4. The owner releases input. Within about ten seconds `human_control` is false and
   both plans finish in order, with `human_control` on their results and
   neither lost, cancelled, or failed.

Record the four receipts in existing run evidence and hold `GO` on any miss of
a rehearsal that ran. End it with one recorded factorio `stop` and a fresh
`observe_local` showing no active task and queue depth 0. A `run_plan` that returns nonterminal with
`human_control: true` is not a failure, in the rehearsal or during a run: the
plan is still queued or active behind the hold, so read it with `plan_status`
after release instead of requeueing it. A direct tool call that fails with a
human-hold reason is retried after the hold.
During a run a hold is the owner input, not idleness: the supervisor records it,
never nudges or replaces during it, and restarts idle timing from fresh
evidence afterwards.

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
   settled task-owned commands, stopped the strategist ledger writes, and fresh physical
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
   The pilot's GO text names the strategist's exact thread ID, as does any replacement
   pilot's assignment, so neither role reads threads to find the other; the
   pilot still sends the strategist no reports.
   Each role's GO text also carries this line: "Never call list_threads,
   read_thread or wait_threads; after any compaction re-read your goal file and
   SKILL.md, then your notebook INDEX.md." No configuration or
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
   Keep exactly the two persistent roles, one body and FIFO lane: the pilot alone
   writes gameplay, the strategist keeps its read-only surface and alone writes the
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
were 6/8 ms for the pilot and
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

Measure each run at `GO+20m` and `GO+60m` against the cycle-10 targets in the
release checklist above and the earlier cycles in
`docs/AGENT-PLAY-PERFORMANCE.md`.

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
separately that no task-owned command or job is still running; confirm the strategist
makes no further ledger write; wait at least 2 s (more than one 1 s bridge
tick), call `observe_local`, and if it shows an `active_task` or
`queue_depth > 0` (a pilot `queue_plan` in flight before the interrupt lands
after `stop`), call factorio `stop` again and
re-observe until idle; only then run recorder FINISH and
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
`active_task` absent or with `source: "upkeep"`, numeric `queue_depth == 0`,
and numeric `crafting.queue_size == 0` together prove idle, and only while
`human_control` is false: a hold is the owner playing, never idle. Upkeep is the
mod's own refuelling, not pilot work; a package plan (`source:
"package:<id>"`) is work. A missing character or required
queue/crafting field, malformed response, stale sample, or failed call is
uncertain, not idle. An absent `active_task` in an otherwise valid complete
character observation is the normal no-task representation. Parked waiting
plans, predecessor-blocked queued plans, and queued packages count as pending
work. A pilot waiting on `next_event` while a package runs is not idle. Inspect a
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
never dispatch on an inline idle predicate. In the same step that may
dispatch, pipe every fresh `observe_local` result together with a fresh
`activity_log` read (`limit: 64`) and its receipt time through the helper
(`{"observe_local": ..., "activity_log": ...}`). The helper compares the full
physical signature (position, carried inventory, `active_task`, `queue_depth`,
crafting state) with the retained one and keeps the conservative idle lower
bound across unchanged samples. It discounts position, inventory and task
changes when either sample shows an `upkeep` task, or when every
`activity_log` plan overlapping the ticks between the two samples was an
`upkeep` plan (an upkeep refuel that started and ended between samples is
visible only there); any other plan in that window is activity. It
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
the replacement. Once it runs, write its rollout file to `pilot` in
`<run_dir>/rollouts.json` so the thought feed follows it. Preserve the strategist, the one body/FIFO/write path, invalidate affected
state, and give the replacement latest structured state and the open milestone.
Record all interventions; assisted progress and timing are not benchmark proof.

Validate these scenarios against the schema offline, then exercise live
delivery/replacement only in an authorized supervised run:

| Scenario | Required result |
| --- | --- |
| Open goals, no active task, queue depth 0, crafting queue size 0 | Valid fresh evidence starts or continues the idle interval. Closed goals do not trigger intervention. |
| Active work, even with queue depth 0 | No idle claim or intervention; reset the prior interval. |
| Character crafting with no active task or queued plans | No idle claim; crafting queue size greater than 0 is work. |
| Only an `upkeep` plan active (the mod refuelling), no queued plans or crafting | Idle evidence continues: upkeep is not pilot work, and its movement or inventory changes do not reset the interval. |
| A package plan (`source: "package:<id>"`) active or queued while the pilot waits on `next_event` | No idle claim; the body is working. |
| Parked waiting plan or predecessor-blocked queued plan, body still | Queue depth greater than 0 means pending work; no idle claim. Read status only with a known exact plan ID. |
| Repeated unchanged character samples while ticks/factory output advance | Retain the original idle timestamp. For an evidenced idle transition at 00:00, unchanged samples at 02:03 and 03:12 report 123 s and 192 s; they do not restart timing. |
| Unknown transition, first idle observation at 02:03 and unchanged sample at 03:12 | Report at least 69 s observed idle, not an exact start before 02:03. |
| Renewed movement, carried-inventory, task/queue, or crafting activity | Reset idle timing and nudge state; a later interval needs fresh evidence. |
| Missing, malformed, failed, stale observation, or run change | Invalidate timing; no intervention based on the uncertain interval. |
| `human_control: true` (the owner playing the body) | No idle claim, nudge, or replacement. Record the hold as the owner input, invalidate timing, and require fresh idle evidence after it. |
| Body moved after the last eligible sample, before dispatch (2026-10-02 13:05) | No nudge: the helper sees the changed signature on the fresh sample and restarts the interval at its receipt. |
| Failed or uncertain exact-pilot message delivery | Record a capability problem, never successful nudge evidence; establish delivery state before retry. |
| Nudge delivered (`steered:<turn id>`) but its token is in no pilot `userMessage` at five minutes | No replacement. Interrupt the exact stale turn once, then replace only after a further 120 s of unchanged idle. |
| Interrupted pilot without confirmed retirement, or unresolved physical call/work | No replacement writer starts. Obtain retirement proof, settle the call, and freshly prove all three idle fields first. |
| Consumed nudge or recorded exact-turn interrupt, confirmed retirement and fresh physical quiescence after five idle minutes | Record replacement intervention; preserve strategist/body/FIFO, invalidate affected state, and resume from latest structured evidence. |

Offline verification proves neither message delivery nor live
retirement/replacement. Claim live behavior only with an authorized supervised
validation and confirmed delivery and retirement receipts.

The native `/goal` owns continuation. Waypoints, batches, and plans are
nonterminal. While later-tick milestone proof is absent, immediately continue
whenever productive work or bounded recovery exists. Keep the current plan and
one grounded successor when safe; native goal continuation starts the next
batch. Growth and gameplay policy lives in
`.agents/skills/factorio-player/SKILL.md`.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent ticks are acceptable, then revalidate the newest
state before mutation. Do not add another body, lane, RCON path, raw Lua/console,
teleport, hidden state, or free resources. `stop` is emergency cancellation, in the cases `AGENTS.md` lists.
If a pilot goal terminates after an intervention, retire it before starting one
replacement; never keep two pilots active.

Use the current public schema shown by `tools/list`. Keep the same persistent
pilot across packets. An empty intermediate turn does not satisfy the
goal and must not add another action writer.

Watch the run through the ordinary couch viewer client, which the mod makes a
characterless spectator that follows Codex, not through the native `Codex`
client window. The `Codex` client's own character is moved by the mod, and
Factorio client latency hiding mispredicts script-driven walking of a client's
own character, which shows as stutter and snapping on that window only. The
`Codex` client must remain connected; it is also the window the owner takes the
body over from, so any real input in it parks the FIFO. During a debug
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
copy of both the save and its matching 0.9.x mod archive. Validate 0.22.3 on a
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

The successful observations below were collected before release 0.22.3. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.22.3. Complete the fresh run above after installing 0.22.3 before recording a
current-release result.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A 0.22.3 run must instead report protocol v28 and mod/app 0.22.3.
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

## burner fuel delivery versus plate cargo

The 2026-10-03 isolated Factorio **2.0.77, build 84539, linux64 headless**
comparison reproduced the suspected validator defects at predecessor
`8f2f5e14b611b7fd836371f1ba33185e87b3abf5` (0.19.9). This establishes the
mechanism in the fixture; it does not retroactively prove autonomy of the
original failed gameplay windows.

A fresh peaceful save with enemy bases disabled contained one fixture character,
a self-fuelling coal drill and belt return, a surplus coal chest feeding a coal
belt, a burner iron drill delivering directly to a stone furnace, and a burner
inserter carrying plates into a wooden chest. Native coal feeders supplied the
iron drill, furnace and plate inserter. All entities, fuel and resources were
created before validation as recorded engineering setup. During the windows,
normal native mining, burning, swinging and smelting supplied all progress;
there were no character transfers or scripted replenishments.

The plate inserter at `(6.5, 2.5)` bound its pickup to the furnace and its drop to
the plate chest at `(7.5, 2.5)`. Its fuel feeder at `(6.5, 3.5)` bound its pickup
to the coal belt at `(6.5, 4.5)` and its drop to that inserter's fuel inventory.
The fixture captured these native target identities and positions, physical
stock and burner observations, full private validator samples, and per-tick
plate arrivals and recipient fuel draws/refills. The topology signature remained
`6cd5ddcf14d50687`; every validator sample reported complete transfer history.

| Window | Ticks | Plate chest | Processor cycles | Observed source cycles | Predecessor acceptance | Candidate acceptance |
| --- | --- | --- | --- | --- | --- | --- |
| 180 seconds | 1800–12600 | 6 → 51 | 45 | 40 | 0 | 45 |
| 216 seconds | 12601–25561 | 51 → 105 | 54 | 49 | 0 | 54 |

Both predecessor windows were topology-ready, had unblocked endpoints and zero
character transfers, yet failed on downstream acceptance and starvation at the
plate inserter's fuel feeder. The predecessor expected both `item:iron-plate`
and `item:coal` in the plate chest. Coal delivered to the inserter's fuel
inventory never reached that chest. The 216-second predecessor window also
reported intermediate coal-buffer outflow missing while the fuel line was
waiting on adequately stocked burners.

The recipient drew one coal at tick 2127 and received a native refill at 2166
in the first window, then drew at 16518 and refilled at 16560 in the second.
Its fuel stock changed 5 → 4 → 5 in each window. The feeder was waiting in
377/380 and 453/456 samples respectively, with its three working samples near
each refill. Continuous energy remained available. Per-tick receipts recorded
45 and 54 separate plate arrivals, rather than relying on the final chest total.

The candidate follows an inserter's pickup edge for cargo products and
stops fuel-path traversal at a burner receiving another inserter's drop. It
extends the retained demand, stock and unique-inlet refill attribution to
externally fuelled inserters, while retaining the existing cargo proof for
self-fuelling coal-carrying inserters. Both native windows returned
`FACTORY_COMPONENT_AUTONOMY_PROVEN` with no blockers. Offline regressions
additionally cover a supplied short refill missed between
samples, stopped and competing feeders, incompatible and unreadable fuel, a
full endpoint, a topology change and a recorded character transfer. The existing
coal-loop, mixed-cargo and starter-stock rejection cases remain in the suites.
Offline stubs are separate evidence from this native comparison.

Each comparison used its own write-data directory and save, base-only mods,
loopback binding on an OS-assigned port, no RCON listener, no advertisement and
no gameplay client. The instrumented copy replaced the control script to bind
the fixture character and invoke the real FIFO validator. Generated-chunk checks
substituted for chart checks only in that copy. Native simulation ran at
`game.speed = 100`; durations above are game ticks, not wall-clock benchmark
measurements. No active server, save, installed mod, recorder or pilot changed.

| Snapshot | SHA-256 |
| --- | --- |
| Official headless archive | `c4efc11529f74d37c96933e291e0db73fd9f5aa4738913d9301b24680b3e947f` |
| Predecessor source mod snapshot ZIP | `b3a9f3c496db754f59104ea5cbf3f1fafaf725b026445a6d8b14a749ad47f82a` |
| Candidate source mod snapshot ZIP | `b30ed480afcd3ef17454b6295bda05a1435563ad2c2228c76ce77ca65e6e6f37` |
| Predecessor instrumented fixture ZIP | `296799ec4830be47b0ddc287c92bdf61186df0ce4409067f541d90b3014eac33` |
| Candidate instrumented fixture ZIP | `dc9dca8787fb38a6a8320fd5b5295691507ab33db90fdb1893d6c459397cb13e` |
| Candidate map-summary source | `c6fffaef3342ae6bdfe1aefcf6ea24f91dfe5bc6a0a71abb89abbe9a1edddf61` |

Both final comparison fixtures requested surface deletion after the second
window and verified its absence at tick 25562. The owned servers then exited
with status zero. Their write-data directories were removed after retaining
comparison receipts and archive identities. Earlier fixture attempts exposed a
surplus pickup ahead of the coal return and premature same-tick deletion
checking; those attempts are diagnostic evidence, not the final comparison.
These are isolated engineering results, separate from source publication,
active installation, gameplay autonomy and benchmark evidence.

### Native negative controls

The same candidate source was loaded into five fresh peaceful fixture saves.
The short case used a one-second window without a gameplay intervention. The
other cases recorded a fixture-only intervention: select a full recipient
burning phase before the twenty-second window, disable the fuel feeder or
fill the plate endpoint before validation, or rotate the fuel feeder during
validation. These controls are assisted engineering tests.

| Control | Result | Decisive evidence | Surface absence verified at tick |
| --- | --- | --- | --- |
| One-second window, ticks 1800–1860 | Autonomy not proven | No endpoint/processor/source events; `fuel_return_not_yet_exercised` and `fuel_demand_not_yet_exercised` evidence | 1861 |
| Twenty-second window, ticks 1800–3000, recipient burning phase set before baseline | Autonomy not proven | Five distinct plate arrivals, five processor cycles and four observed source cycles; recipient `fuel_return_not_yet_exercised`, suggested 260 seconds | 3001 |
| Fuel feeder disabled before window | Preflight refused | Structural `nonproductive_status:disabled` at the exact feeder | 1801 |
| Plate chest filled before window | Preflight refused | `blocked_output` at the exact endpoint | 1801 |
| Fuel feeder rotated at tick 2000 | Window rejected | `component_topology_changed_during_validation` and missing recipient fuel provenance | 2030 |

| Negative instrumented fixture | SHA-256 |
| --- | --- |
| Short window | `ab6994f65bab1086b06e635f5dcda25cb7ab0580ef0768e295dd6b535743eca5` |
| Twenty-second unexercised refill | `656bcacb5ac3be0a0e82fedf890e8fe06daca96c8f9f84527741e6ae6f13dea8` |
| Disabled feeder | `2e9ecb0e8c1d57cd154291608e91039a9b6e458942331289839bcaf298bcb670` |
| Full endpoint | `bfcc6c3c552962a46cf069361c55ec0077a4ec63d042927c464f744dcfb2f917` |
| Changed topology | `b400bff9353d28246b6fb809015ae8c63c354521f0e22b78425df58caf56e606` |

Every negative fixture produced a later-tick surface-absence receipt, its owned
server exited zero, and its separate write-data directory was removed and
absence verified. Native negative controls do not replace the broader offline
rejection cases or prove a gameplay milestone.

### Offline verification and review

Both affected Lua suites passed with the repository-supported `texlua` runner.
The full `scripts/agent-app verify --profile full` profile passed all ten checks,
covering application contract tests, dependency consistency, TypeScript,
companion tests, all Lua tests, offline writable and read-only MCP smoke tests,
build, built MCP smoke and mod package layout. These checks remain offline.
A local Semgrep MCP candidate scan with `p/default` reported all three changed
Lua files scanned, with no findings, errors or skipped rules. The workspace
scan route could not resolve its managed key; the temporary local adapter used
Semgrep MCP 0.8.0 and reported Semgrep 1.135.0.

A fresh independent read-only review checked the complete candidate and native
receipts, independently reran both Lua suites, and reported no code finding.
It found an incorrect topology signature in this appendix; the identifier was
corrected to the final receipts' `6cd5ddcf14d50687`. Review did not perform live
gameplay or publication. Source publication and exact remote readback belong
to the trusted host completion path; no active-run installation is requested.
