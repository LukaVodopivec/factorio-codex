# Live validation

This guide validates release **0.38.1** against a real Factorio game: start a
test server, connect a client, and check the tools and plans live. Offline
tests (`npm test`) cover the same contracts with fixtures; only a live run
shows the engine's own behaviour. Earlier live evidence below stays historical
until a 0.38.1 run is recorded.

The reference setup uses two machines. The server machine has no dedicated
GPU and is permanently headless: it runs only the dedicated server, the Node
bridge, and the agent sessions, and never a Factorio GUI or client.
Both visual Factorio processes run exclusively on the couch PC, a separate
Windows machine on the same trusted LAN. The `scripts/launch-native-client.ps1`
entrypoint is for that Windows client; the repository provides no Linux
visual client launcher. Any equivalent split works, as long as the server
machine stays headless.

## Headless live smoke suite

`npm run test:live` (or `scripts/agent-app verify --profile live`) checks the
real mod against the real engine with no client and no body, in about a
minute. It is opt-in and never part of `npm test` or CI. It needs Node 22 and a
Factorio 2.0.x executable, found through `FACTORIO_BIN` or a standard Linux
Steam install; without one it skips with a message (the agent-app profile sets
`FACTORIO_LIVE_REQUIRED=1`, which turns the skip into a failure).

The suite creates a throwaway peaceful save on seed 747930220 in a temp dir
with its own config, write dir and random free loopback ports, so it never
touches your Factorio data, and removes the dir and the server on success and
failure. Through the repository's `RconClient` and `Bridge` it runs scenario
console commands (`/silent-command __agentic-companion__ ...`) that build
entities with `create_entity` and call the mod's modules and RPCs:

- line sampling of a powered assembler line and a dry boiler, and a
  `consumption_above_production` watch firing;
- `inspect` belt lanes;
- a `build_layout` dry run on a space platform with `belt_joins` and
  `port_fluids` rows;
- NaN-safe JSON through `rpc.to_json`;
- `items.move` keeping durability and quality;
- `inspect` `area` refusing uncharted land, then listing own entities as
  compact rows;
- `run_snapshot` and `production_requirements` on a mid-game state (red and
  green research, 60 machines), each answered pending and read through
  `get_job`, with every tick of their work within 8 ms;
- mirrored and plain oil refineries and chemical plants whose live pipe
  connections match `fluid_connections.ports` at every direction;
- the physical scenarios on a real character (ground stacks taken up by
  `place_entity`, `blueprint_capture` origins).

Then it asserts that `ping` shows no `handler_errors`, the server log has no
script errors, every profiler `rpc` line and the `rpc` lines and job work of
each tick together stay within 8 ms, and each 600-tick `on_tick` window
averages within 8 ms a tick. The setup times job work (jobs advanced on_tick)
per tick itself and marks a tick in which the Lua garbage collector freed
memory (its time counts in that tick); other tick handlers are logged only per window, so one slow tick of
theirs inside a quiet window is not caught. A headless
server has no Codex player and charts nothing, so the suite's own setup
command patches only that throwaway server's live Lua state: a stand-in body
on nauvis, every chunk counted as charted for the mod's chart rule, and the
registry marked ready.
The mod carries no test flag or path; chart checks the engine answers itself
(planet layouts and routes) still need a client run below.

### Hand-crafting result capacity

The live suite uses the real character and native crafting queue to reproduce
a full inventory in which an iron-chest craft consumes eight plates from a
stack without freeing a slot. It checks explicit completion waits, a background
craft followed by placement, and placement's nested auto-supply. A completed
head that remains unchanged across distinct ticks ends the waiting step with
`CRAFT_OUTPUT_BLOCKED`, releasing the same FIFO. No storage destination is
selected, and no native recipe is cancelled by this failure.

Craft results distinguish acceptance from carried product evidence:

- `source_tick` identifies the readback;
- `crafts_started` is the number accepted by `begin_crafting`, when the step
  owns that acceptance snapshot;
- `products` contains each item's expected fixed output, when known, and
  `carried_delta` since acceptance. This is inventory evidence, not a claim
  that products could not have been moved during a human hold;
- `queue` reports native progress, size, retained entries and an explicit
  omitted-entry count after the first 32 rows. Consumer failures report the
  current queue; auto-supply also retains its last craft's acceptance facts
  under its existing `last_action`, at that snapshot's own source tick.

Individual cancellation, watchdog failure and plan-budget expiration retain
native crafting and report its queue, preserving unrelated background recipes
without refunds. Emergency `stop` still cancels the entire native queue using
the engine's refund behavior. Surface changes continue to retain crafting.
Dispatcher-ended capacity waits run the owner's cleanup hook, including the
restoration or accounting of entities held by nested escapes.

The native recovery scenarios transfer existing plates into an existing buffer
through an `insert_items` plan, then require both the blocked chest and an
unrelated queued gear to finish with exact item accounting and an empty queue.
Other scenarios require successful delivery when ingredients free a slot or an
existing result stack has room, and failure followed by FIFO recovery when a
free slot is filled after acceptance. Offline regressions cover multi-output
recipes, partially delivered batches, bounded queue reporting, exact terminal
codes, predecessor failure propagation and owner cleanup.

Observed on 2026-10-25 with the official Factorio **2.0.77, build 84539,
linux64 headless** build:

| Case | Observed accounting and queue state |
| --- | --- |
| Native full-inventory trigger | 9,000 plates became 8,992; no chest; one queued recipe at progress 1.0333333333333332. |
| Explicit wait, asynchronous consumer, nested supply | Each ended `CRAFT_OUTPUT_BLOCKED` with two recipes retained. FIFO recovery left 8,790 plates carried and 200 buffered, one chest, one gear, and no queued recipes. |
| Ingredients free a slot | Completed with one chest and no queued recipes. |
| Existing result stack | 49 chests became 50, with 8,892 plates and no queued recipes. |
| Slot filled after acceptance | Ended `CRAFT_OUTPUT_BLOCKED`; FIFO recovery delivered one chest with 8,892 plates carried, 100 buffered, and no queued recipes. |
| Emergency stop after acceptance | 8,990 plates became 9,000 through native refunds; no products and no queued recipes. |

## Start a test server and connect a client

1. On the Windows client machine, install the full standalone Factorio 2.0.x
   Space Age build under `%LOCALAPPDATA%\factorio-codex\standalone-space-age`,
   or pass its executable as `-FactorioBinary`. The Steam build is
   intentionally rejected for the Codex client because it replaces the
   isolated LAN identity with the Steam account identity.
2. On the server machine, run
   `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Host a dedicated Space Age fresh freeplay save from one run directory with
   permanent peaceful mode and enemy bases disabled:
   `node companion/dist/cli.js server create <run-dir>`, then
   `node companion/dist/cli.js server start <run-dir> [--bind <lan-address>]`.
   The run directory owns its save, logs, PID, and a run-local mod directory
   with base, elevated-rails, quality, space-age, and the companion enabled, so
   stale global mods never load. `server start` refuses a protocol or mod
   version mismatch before `GO`; `server stop <run-dir>` saves over RCON and
   shuts the server down at the run boundary instead of leaving it idle. Server
   and clients run the identical Space Age mod set.
   Console-backed RCON disables achievements for the save. Play reaches
   every planet: rockets, remotely built space platforms, and the body's own
   trips by rocket, platform and landing pod.
4. Allow the game's UDP port `34197` through the server
   machine's firewall from the trusted LAN only. RCON stays private on
   `127.0.0.1:19015`; it is never the address a client uses.
5. Build the mod archive on the server (`npm run package:mod`, which needs
   bash and `zip`), copy `dist/agentic-companion_<version>.zip` into the
   client checkout's `dist\` folder, and run
   `scripts/launch-native-client.ps1 -Address <server-host>:34197`. `-Address`
   is required; there is no default server address. The launcher connects the
   isolated native client (highest graphics quality at 3840x2160) as the real
   player named `Codex`, with its write-data and mod profile only in
   `%LOCALAPPDATA%\factorio-codex\native-client`. Then start the ordinary
   Factorio client as the viewer. A manually installed client instead needs
   the mod ZIP in `%APPDATA%\Factorio\mods` and an enabled `agentic-companion`
   entry in `%APPDATA%\Factorio\mods\mod-list.json`; the ZIP must match the
   server archive hash. `--mp-connect <host:port>` is the Factorio launch
   argument (`--connect-to-server` is not valid).
6. On the server machine, run `node companion/dist/cli.js doctor`, start Codex
   at the repository root, then call `connect_status` and `observe_local`.
   Confirm the mod refuses an absent or wrong player instead of creating a
   standalone character.

Factorio dedicated-server process arguments contain the RCON secret. Never
print or read full arguments through `ps` full args, `/proc` command-line
data, WMI `CommandLine`, or an equivalent process-inspection surface. Verify
health through user-service state, PID, executable basename, and `doctor`
only, and keep all reported output secret-redacted.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the clients. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before a fresh connection. On Windows, wait for
`factorio.exe` to exit completely before replacing the mod ZIP: Windows briefly
keeps a lock on the old archive.

Before upgrading an existing save, stop the server and keep an exact copy of
both the save and its matching mod archive. Validate the new release on a copy
first. Rollback means stopping the server, restoring that paired save and
archive, and confirming the restored version through `doctor`; never open the
only rollback save with the newer mod.

A recorder may downscale the 3840x2160 client window to `1920x1080`, but it
must fit the complete source without cropping or enlarging a lower-resolution
viewport. Before a timed recording, verify the live client area, capture-source
dimensions and aspect ratio, and representative framing; a non-black frame
alone is not evidence of usable framing.

## Check tools and plans live

1. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
   Verify `mine` count repeats cycles only on its initial exact resource and
   that `observe_local` reports resources as connected patches with an exact
   `nearest_target`, not duplicate entity rows. Observe an exact `ground_items`
   stack, call `pickup_items` with its unchanged position/item/count, and verify
   ordinary walking/ticks, target depletion, and the matching inventory delta.
2. Run a two-or-more-step `run_plan`. Confirm ordered fail-fast outcomes, no
   later enqueue after failure, and a final observation on completed, failed,
   and cancelled paths. Confirm Codex walks at ordinary Factorio speed and no
   global game-speed setting changes. Every failed or partial step and
   `activity_log` row names a `code`, and no error message (there, in a tool
   error, or in `connect_status`'s `handler_errors`, which appears only once a
   mod handler raised one) names a `.lua` source location.
3. In the supervisor's recorded emergency-quiescence rehearsal, interrupt a
   long action in the TUI, observe retained work, then have the supervisor call
   `stop` if cancellation is required. Verify active tasks, queued plans, and
   character crafting are cancelled and re-observe physical quiescence. The
   interruption alone grants no cancellation authority to the pilot; ordinary
   recovery retains committed effects and reconciles pending work.
4. Exercise `find_placement` at a shoreline; confirm `map_summary` reads only
   force-charted chunks; verify deterministic production arithmetic and
   ambiguity refusal. Find a cardinal inserter placement with an exact
   `output_target`, physically place it with that target, and distinguish its
   live output point's valid 1×1 recipient geometry from runtime binding. A nil
   `drop_target` before first output must remain explicitly pending, not fail or
   claim binding; a non-nil different target must fail. For a mining drill,
   include legitimate starter fuel in the same build-plan step and confirm the
   plan waits until actual output flow exposes the exact runtime recipient, or,
   when the drill has not output within two of its mining cycles plus a second
   (a backed-up belt, a full or refusing recipient), places the step with its
   runtime target explicitly pending first output instead of stalling.
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
5. If bootstrap items are absent, use another fresh built-in freeplay save.
   Gameplay roles never use console commands, editor mode, spawned items, or
   teleporting. A debug supervisor may use those surfaces only for recorded
   diagnosis or the smallest recovery intervention, after which the pilot must
   re-observe authoritative MCP state.

## Release checklists

For the 0.38.1 release (a walk out of a spot the pathfinder refuses, from
trial 0013), record this observable check:

- A body pressed into a lava or water corner, where Factorio's pathfinder
  refuses every path that starts at its exact position, steps by ordinary
  walking to the nearest free tile centre and walks on from there; only a
  second refusal ends the walk, and its `PATH_NOT_FOUND` or `BODY_ENCLOSED`
  diagnostics name the `start_step` it tried.

For the 0.38.0 release (travel recovery, live orders, supply and inventory
facts, from trial 0013), record these observable checks:

- A `travel` step waiting aboard re-checks the route: a platform whose
  schedule no longer names the destination ends it `NO_ROUTE`, and one with no
  working thruster that stands still away from the destination ends it
  `PLATFORM_CANNOT_MOVE`. `plan_status`, `travel_phase` and
  `observe_local.active_task` show the platform's state, speed, location,
  working thrusters and the wait's deadline tick.
- `travel` up waits for a platform whose next stop is the body's planet
  instead of failing `PLATFORM_NOT_IN_ORBIT`; `LAND_REFUSED` carries the
  platform's state, location, paused flag, hub and schedule record.
- `cancel_plan {plan_id}` on the pilot surface cancels only a pilot plan
  (`NOT_YOUR_PLAN`, `PLAN_NOT_PENDING` otherwise), logs origin
  `cancel_plan/pilot`, and a launch or landing under way finishes.
- A package whose every step names a platform runs beside a waiting travel
  step, and the travel step still polls between its steps.
- `next_event`'s body block has `packages_open`, `idle_seconds` and
  `idle_since_tick`; `orders` shows each package's live plan outcome; a cargo
  pod landing on a planet rides along in `space_events` without waking.
- `observe_local.character` and the `factory_status` body show
  `free_slots`; a fetch on a full body says "not looked for: inventory full",
  and upkeep skips what the body cannot carry.
- Supply smelting passes over furnaces an own inserter or loader serves, and
  a shortfall lists `rejected_furnaces` and `untried_holders`.
- `progression_status` lists `queueable_after_queued` and
  `queue_eta_seconds`; the game accepts a technology behind its queued
  prerequisites.
- `platform_status` counts turrets and thrusters by name with ammo state,
  never truncated; `describe_prototype` describes asteroids and ammo.
- Ticks stay within 8 ms at about 230 machines, including `plan_status` and
  `run_snapshot`.

For the 0.37.0 release (make the obvious moves visible), record these
observable checks:

- `queue_plan` returns `hand_craft` `{total_s, items}` when its needs would
  be hand-crafted from current stock, and leaves it out when none would.
  While a step runs, `plan_status` `diagnostics` carries `supply` (`stage`
  `get_items`, `auto_supply`, `target` or `before_supply`) and `crafting`
  `{recipe, count, queue_s}`; `observe_local` `character.crafting.queue_s`
  matches the queue's remaining seconds.
- A plan past its active budget fails `PLAN_BUDGET_EXCEEDED` with the same
  `supply` and `crafting` in its outcome, its detail names the hand-crafting
  seconds still queued, and those crafts keep running.
- `get_items` reports `crafted_s` when it queued hand-crafts; with
  `craft: false` it takes, smelts and gathers only and ends
  `SUPPLY_SHORTFALL` with `hand_craft` and an unchanged crafting queue.
- `mine` waits only on queued crafts that make or use the mined products.
- Refusals carry their codes (`MISSING_INGREDIENTS`, `NOT_HAND_CRAFTABLE`,
  `INVENTORY_FULL`, `NOTHING_TO_TAKE`, `AREA_INVALID`) and do not raise
  `run_snapshot` `handler_errors`; each failed or partial plan writes one
  server-log line with its detail.
- `run_snapshot` `body_time` carries `phases` (`walk`, `mine`, `smelt_wait`,
  `craft_wait`, `other`), `tiles` and the `waiting` state, the recorder's
  strict schema accepts them, and the manifest's `telemetry.body` gives their
  window deltas; `waiting` time is a state share, never a gap.
- `explore` without `direction` for a resource the force has charted within
  `max_distance` ends `PATCH_FOUND` at once (`walked` 0, `charted_before:
  true`, `distance` to the patch's bbox, 0 inside); with `direction` it
  scouts that way; `EXPLORE_NOT_FOUND` names `nearest_charted`
  or `none charted`, and never `none charted` while `charted_unknown` is
  true.
- `production_requirements` for a technology gives each missing technology's
  `unit_time_s`, and `time_estimate.lab_seconds_at_speed_1` and, while labs
  progress, `lab_seconds`; `progression_status` technologies list `modifiers`
  `{type, modifier}` (for example laboratory speed).
- A placement refused by a remnant or ghost names the real blocker, an
  offshore pump refusal names the water-edge reason, and a dry run lists
  `drill_ore` for each drill over charted resource.
- With about 180 machines, `factory_status` and a large `check_only` take
  no tick over 8 ms; a read that spent its share of the tick budget names the rest in
  `unread_sections`.
- An `output_full` machine whose output only backs up leaves the
  `next_event` wake tick unchanged and stays in `factory_status`.
- A hand `blueprint_place` of poles joined by copper wires reports
  `wires_ignored` in its dry run and its outcome, and the built poles read
  back connected; circuit wires still refuse hand mode.
- A partial ghost `blueprint_place` lists `missing_ghosts` (`name`, `x`, `y`,
  `blocked_by`) and `missing_ghost_count`.
- An approach that settles off belts by a routed walk ends within reach of
  its target, never just beyond it.
- `next_event` waits at most 25 s; `ledger-apply --schema` prints the
  envelope, update fields and numeric bounds, and an applied update names
  the unqueued packages it dropped (`omitted_unqueued`); `tool_outcomes.jsonl`
  takes a plan's code from its first non-completed outcome; a debug run's
  campaign row has no score fields.

For the 0.36.0 release (recording and telemetry), record these observable
checks:

- `run_snapshot` carries `milestones` (`rocket_ready_tick`,
  `rocket_launch_ordered_tick`, `rocket_launched_tick`, and `research`: each
  technology's first finish tick), `holds` (`count`, `total_ticks`, `recent`:
  the last 16 episodes with `start_tick`, `end_tick` and `cause`) and
  `handler_errors`. "First rocket launched" is the mod's `on_rocket_launched`
  tick: the final manifest's `telemetry.milestones.rocket_launched` gives it
  with `elapsed_s` from `GO` (the baseline tick), so the supervisor reads it
  from the recorder or `run_snapshot`, never by polling the raw console.
  `telemetry.holds` and `telemetry.handler_errors` count the window's human
  holds and caught handler faults.
- `next_event` delivers `rocket_launch_ordered` when launch is pressed and
  `rocket_launched` when the rocket leaves the silo.
- A failed plan's `activity_log` row keeps `summary` short and carries
  `detail`, the full reason up to about 800 bytes, cut at a character
  boundary.
- `tool_outcomes.jsonl` rows carry `ok`, `next_event`'s `event`, and a
  `summary` of at most 200 characters on failed calls and statuses other than
  `ok`, `completed` or `running`; a failed dry run is `not_ok` with its code or
  its first `failed` row's.
- Every queued package's record in `package-queue.json` gets `plan_ended_tick`
  and `plan_status`, also without `verify`; a failed or cancelled plan's
  verify is `not_measured` with reason `plan <status>` and no
  `package_unmet`; a partial plan's `NO_LINE` row carries `plan_status`.
- `ledger-apply` appends one row per call to `ledger-history.jsonl` beside the
  ledger, applied or discarded.
- The manifest's `telemetry.roles` carry `model_calls`, `mcp_calls`,
  `wait_ms` (`next_event` and `plan_status` waiting, out of `tool_ms`),
  `reasoning_items` and
  `reasoning_summarized`; `telemetry.body.busy_share` counts `pilot`,
  `package` and `crafting`, not `upkeep`.
- `campaign record` of a debug run of a screened configuration keeps its
  unscored row, with the final sample's milestones, and takes that
  configuration out of `screening_queue`.

For the 0.35.0 release (facts and the tick budget), record these observable
checks:

- No tick's RPC and job work together goes over 8 ms: `run_snapshot` runs in
  phases and its result arrives through `get_job`, `production_requirements`
  is a job whose recipe index spreads across ticks (its resource catalogue
  and recipe facts are read into storage at init, never in a tick), and
  large dry runs yield. Profiler RPC lines carry the tick.
- `factory_status` lines carry `line_counts` (with `by_state`) for every line
  of the surface beside the ten worst rows; an output-full drill or inserter
  whose drop target takes no more shows cause `drop_blocked` with `drop_into`;
  lab, recipe-less and silo states fall into named status buckets.
- `inspect_entity` with `area` lists the own entities of a charted area of at
  most 64 by 64 tiles, and a silo's centre reads the silo, not its rocket.
- `get_items` crafts in rounds up to its stated cap and says when the cap
  stopped it; `explore` searches the 128 tiles it charts; mirrored refineries
  and chemical plants get `port_fluids` rows; a partial silo starter insert is
  reported with its totals as `PARTIAL_INSERT`.
- Request refusals of `get_items` and `production_requirements` are refusals,
  not handler faults.

For the 0.34.0 release (gameplay unblockers), record these observable checks:

- Placing a building over item stacks lying on its footprint takes them into
  the body's inventory first and reports them as `picked_up` with exact
  positions; a stack that does not fit fails with `GROUND_ITEMS_NO_ROOM` and
  stays on the ground. A dry run over a footprint holding only such stacks is
  ok with a `ground_items` note; a drill with no ore under a lying stack is
  still refused for the ore.
- A fetch whose walk is enclosed by the factory steps out through the named
  own blocker (up to three nested blockers, each put back) and retries once;
  otherwise the step fails `BODY_ENCLOSED` with `step_out`, never
  `SUPPLY_SHORTFALL`.
- `move_entity`, `insert_items`/`extract_items` and `pickup_items` refusals
  carry their own codes (`MOVE_*`, `TRANSFER_TARGET_MISSING`,
  `GROUND_STACK_CHANGED`, `PICKUP_COUNT_MISMATCH`), and tool errors keep a
  leading code instead of `TOOL_ERROR`.
- A captured blueprint describes an `origin` with small `dx`/`dy`; placing it
  at `position = origin` in hand or ghosts mode rebuilds it in place.
- One machine flapping in the same problem class wakes `next_event` at most
  once in five minutes; its `factory_status` rows are unchanged.
- `ledger-apply --schema` prints the package contract; duplicate or stale
  ledger updates are discarded as `*_UPDATE` with the tick they must exceed.

For the 0.33.0 release (the harness), record these observable checks:

- A pilot's MCP process claims a writer generation; once a replacement
  pilot claims the next one, the old pilot's writes return `WRITER_RETIRED`
  while its reads still work, and `doctor` shows the newest generation. The
  supervisor's `--role supervisor` session still drives rehearsals, and an
  unstamped `stop` always runs.
- A `queue_plan` whose answer was lost is retried once with the same
  `client_key` and returns the same plan (`duplicate: true`); a write whose
  outcome cannot be read returns `OUTCOME_UNKNOWN`, never a silent retry.
- Large replies arrive in one piece (up to 256 KiB a part), well inside the
  tick budget.
- The documented role launch lines turn off built-in web search, multi-agent
  and memories.
- The recorder writes `tool_outcomes.jsonl`, splits each role's time into
  thinking, tool calls and compaction, reports body-busy share and idle gaps
  by plan source, and marks a run assisted when game speed, cheat mode, the
  controller, the mod list or unexplained bonuses deviate.
- `npm run test:live` runs the headless smoke suite against an installed
  Factorio and passes.

For the 0.32.0 release (can it keep up), record these observable checks on
a copy of a running factory's save:

- `factory_status` line rows carry `max_per_min` (full-duty output with
  modules, beacons, quality and research productivity), `utilisation`, and
  `share_10m` once a line was not running nearly all of the last ten
  minutes; burner and steam lines carry `fuel_s`; a row short of power names
  its network's generating lines in `supply_states`.
- `production_requirements` with `per_minute` gives each stage's
  `standing_per_min`, `standing_lines` and `short_per_min`; the research
  section gives `packs_per_minute_made` and `labs.starved_by`.
- `describe_prototype`, dry-run inserter rows and `inspect_entity` give an
  inserter's `max_items_per_second`; dry-run materials carry `in_stock`,
  `made_per_min`, `short`, `minutes_at_rate`, the hand-craft split and a walk
  lower bound; `queue_plan` returns `needs` and the fifo block shows
  `queued_demand` and `short_by`.
- `set_watch`/`clear_watch` (both surfaces, 16 a role) fire `watch_fired`
  through `next_event` once per crossing, re-arming after hysteresis.
- `connect_entities` fails typed (`ROUTE_TOO_LONG`, `ROUTE_BLOCKED`,
  `SEARCH_BUDGET`), routes through bot-chosen `via` waypoints, and a pipe
  dry run reports its segment against the pipeline extent.
- `next_event` delivers `entities_lost`, `repeat` and `recent_draws` on
  outcomes, and package `verify` metrics as `package_verified` or
  `package_unmet`; `activity_log` reads the change journal; patches carry
  `minutes_left` and `remaining_fraction` (crude oil `yield_percent`);
  `factory_status` shows the game's own alerts when the Codex player has
  them.

These 0.32.0 behaviours were exercised live on a headless 2.0.77 server
(line capacity and utilisation, a dry boiler's fuel and supply states, watch
firings, an own building destroyed, patch depletion, package verify).

For the 0.31.0 release (why a machine stops), record these observable checks
on a copy of a running factory's save:

- A dry boiler or starved machine's `factory_status` row and its
  `new_problem` event carry `feed`: the inserters dropping into it, what each
  holds, what its pickup carries per belt lane, and a class (`foreign_item`,
  `source_empty`, `inserter_bound`, or none when a feeder is not working). It
  is read once per stall and again after each line refresh.
- A fluid-starved crafter names the fluid it lacks and, when its inlet meets
  another fluid, `meets` that fluid.
- `inspect_entity` gives belt `lanes` with `lane_mix` (empty, pure,
  separated, mixed), inserter `holding`, crafter port `takes`/`meets`, and
  with `trace: up|down` the items along a belt and their sources, capped and
  stopping at uncharted chunks.
- Layout, blueprint and route dry runs list `belt_joins` (straight, side-load
  or drop, per lane, with `mixes`) and layout and blueprint dry runs list
  `port_fluids` (each crafter port's recipe fluid, what it meets, `mismatch`).
  Neither row fails a dry run.

These 0.31.0 behaviours were exercised live on a headless 2.0.77 server (a
boiler fed from a copper-ore belt, a crude-starved refinery whose inlet holds
heavy oil, side-loads, splitter halves, fluidbox port mapping).

For the 0.30.0 release (honest moves and plain failures), record these
observable checks on a copy of a running factory's save:

- Inserting or taking a partly used science pack, a magazine with spent
  rounds, a half-spoiled stack or a rare-quality item keeps its durability,
  ammo, spoil and quality, and no move creates items; a belt pickup of
  several items takes them off the line one stack at a time.
- Overflow is spilled onto the ground, never onto a belt and never marked for
  deconstruction, and the step outcome names the spilled count and position.
- `can_place` refuses a footprint that reaches into an uncharted chunk with
  `UNCHARTED`, revealing nothing about that terrain; a placement blocked by a
  belt names the belt instead of "water or otherwise unbuildable".
- Every failed step carries a code (else `STEP_FAILED_UNCLASSIFIED`), no
  message contains a Lua source location, and `connect_status` counts recent
  handler errors. A tool call with an unknown key is rejected.
- A walk that ends on a belt tries the native path off it before
  `BODY_ON_CONVEYOR`; stepped off but still out of reach is `PATH_STALLED`.

These 0.30.0 behaviours were exercised live on a headless 2.0.77 server
(stack moves, partial and refused moves, belt pickup, spills).

Dry-run `belt_joins` rows (`build_layout`, `blueprint_place`, belt
`connect_entities`) follow lane rules measured on a headless 2.0.77 server:
transport line 1 is the left lane; a belt from behind, or the one side input
of a belt with nothing behind it, keeps lanes; a side input of a belt with
something behind it side-loads both source lanes onto the near lane; onto an
underground entrance only the source lane over its back half passes (an
exit: its front half); a splitter output joins like a belt; an inserter or
drill drop lands on the lane on its side of the centre line, the right lane
on the line. To recheck, build each case, dry-run the joining piece, then
place it and read the receiving belt's transport lines.

An inserter's `adds` in those rows reads its pickup the way the game's
endpoint does (`get_recipe()` products of a standing assembler or furnace,
the chest inventory's `get_contents()`, a belt's transport lines, a planned
assembler's recipe products), then applies the planned inserter's whitelist
or blacklist filters. A planned belt piece identical to one standing there
(name, position, direction, underground end) counts as standing (its lanes
now count in `items` and `adds`): a standing
belt's `belt_neighbours.inputs` on a planned tile count before the build only,
and a join between two standing belts is listed only when the build changes
its kind. Inputs on uncharted chunks are not read. A belt `connect_entities`
build (not a dry run) skips the join scan. To recheck, list a standing belt
that feeds a standing curve in a dry run (no rows), then add a planned belt
behind the curve (one side-load row from the standing piece).

For the 0.29.2 release (the bots do the thinking), record these observable
checks on a copy of a running factory's save:

- A hand-written steam layout (offshore pump, boiler, two steam engines,
  poles) dry-runs with no `open_fluid_ports` row; a gap in its water line
  reports the open port.
- A layout that puts a furnace or chest on ore reports it in `on_ore`, and a
  drill on two resources in `mixed_ore`; neither fails the dry run.
- `factory_status` patch rows carry a `bbox` outline, `find_placement` lists
  candidates nearest first, and a short power row's `add_to_cover` lists both
  `steam` and `solar`.
- `build_block` is gone from both MCP tool lists and from `queue_plan` steps.

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
  ammoniacal ocean; a building whose surface conditions
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
  `rocket_launch_ordered`, `rocket_launched` (once the rocket has left),
  `platform_state_changed` and `cargo_delivered`.
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
  the action and its phase, and the next queued plan starts; a step-out
  stalled mid way puts its taken-up entity back or names it in the
  outcome's `cancelled` note. `wait_for_item`,
  `wait_for_research`, a hand-crafting queue that advances while the step
  waits on its output, and a human hold never produce it; background crafts
  (and the items they add) do not keep a step that waits on anything else
  from stalling. A `STEP_STALLED` on a step that was making real progress is
  a defect to record with the step's action and phase.
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
  owned blocker (on the line toward the target first). A plan step or layout
  placement recovers once by itself: the body takes that blocker up, walks
  out through the opening and puts the same entity back with its direction,
  recipe, settings and contents (the step's detail names it); never by
  teleport. It walks out until the body stands off any belt, and reports
  `ESCAPED` only with the body still outside once the entity is back. A
  plan that ends mid step-out (cancel, stop, budget) puts the entity back
  when the body can; otherwise the cancelled step's result names it in the
  inventory.
- A successful walk or approach never leaves the body on a belt: it steps
  to a clear off-belt tile (reported as `settle`), within 4 tiles, or for an
  approach within 8 tiles and still in reach of its target, else anywhere in
  that reach (searched over a few ticks). A step that ordinary walking cannot
  finish in time (even one stopped a few tenths short), or cut short by a
  blocked start, or a tile beyond those rings, is walked to once by a native
  path to the tile centre itself, before any `BODY_ON_CONVEYOR`. A layout retries
  once, after its last step, a placement whose approach failed
  `BODY_ON_CONVEYOR` or `START_COLLISION`. `BODY_ON_CONVEYOR` leaves
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
- Frame time: the game log carries one `rpc <method> tick <tick> Duration: …`
  line per RPC (sum a tick's lines for its RPC time) and one `on_tick 600 ticks Duration: …` line per 600 ticks (Lua time,
  logged only). On the upgraded save, `factory_status.registry_ready` and
  `patches_ready` turn true within about a minute of load; after that no
  `factory_status`, `event_state` or `activity_log` line exceeds about 8 ms,
  and the 600-tick aggregate averages well under 8 ms a tick at 200 machines.
- `build_layout` builds end to end from a dry run that matched; auto-supply
  takes from a chest and from a belt before crafting, and placement clears
  trees and rocks in the footprint.
- Heavy reads run as jobs: a `map_summary`, a full `observe_local`, a route
  search and a `build_layout` dry run inside the factory each return one result
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
  `origin` (`stop/<role>`, `cancel_plan/<role>`, `<tool>/<role>/abort`
  or `<tool>/<role>/direct-task-timeout`), where the role is the one
  its MCP process was started with (`--role`); `unknown` means a session was
  started without it.
- Loading a copy of a 0.21.1 save that still has queued plans and running
  jobs (taken before any stop) with 0.22.0 keeps them queued and finishes the
  jobs, and removed actions complete as `REMOVED_ACTION`. The live upgrade
  procedure still stops first.
- `factory_status` line causes name the fluid, `no_recipe`,
  `recipe_not_researched` or `burnt_result`; `no_heat` and `disabled` appear
  where a machine is cold or disabled. Each power row splits production by
  source; while demand exceeds `sustained_w` it gives `add_to_cover` with
  both `steam` and `solar` counts, and building either one makes
  `headroom_w` non-negative. `sections:
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
  Right after the rehearsal stop, upkeep waits for the first plan to finish,
  and the fifo block and `queue_empty` say `upkeep_off_since_tick`; after a
  `stop` with `keep_upkeep: true` it does not wait.
- Between back-to-back plans, a burner within 96 tiles of the body or of one
  of the last four sites where pilot or package plans began
  (`upkeep_selection.sites`) that has been dry for a minute gets one upkeep
  plan (`upkeep_selection.room` `boundary`) before the next plan starts; near
  those sites it serves only dry burners, not low-fuel burners or labs; it moves no item the next plan
  names, runs to its end, walks back, and the next plan starts after it. With
  the FIFO empty, a dry machine within 96 tiles of one of the last four sites
  where pilot or package plans began (`upkeep_selection.sites`) is served even
  when the body stands further away, also after several plans began at a far
  site.
- The ledger writer's (the strategist; the pilot in a solo trial) reasoning
  summaries and messages appear in the panel within about 10 s, never in chat;
  every role's lines are in `thoughts.jsonl`; the panel does not start a
  takeover hold.
  After a rollout pointer handoff, complete replacement history and retired
  pending thoughts are evidence only (`said_at: null`), so a newly appended
  live thought is offered on the next available tick without preparation ahead
  of it. Check that hidden-role history, overflow beyond 200 live chunks,
  failed sends and pending chunks at orderly shutdown each remain in the
  evidence exactly once. Shutdown settles any in-flight send before closing RCON.
  Compare source `ts` to successful acknowledgement `said_at` for feed latency;
  null means no successful acknowledgement was recorded; a lost reply can
  leave game acceptance unknown. Record supervisor
  dispatch time separately: dispatch-to-rollout delay is outside this queue.
- `map_summary` `include` sections (`stockpiles`, `sites`, `patches`, `power`,
  `problems`, `flows_all`) name a site and its stock beyond 30 tiles from the
  body and nothing in an uncharted chunk; `inspect_entity` there returns
  `remote: true`, and a mutation at that position still fails on reach.
- `pickup_items` on a plain transport belt is an exact conserved transfer from
  the targeted belt tile, not native picking: with the body within
  `item_pickup_distance` of the belt's centre, exactly the requested count
  leaves that tile's lines and the same count enters the main inventory; a
  count that cannot fit, a body out of distance, or any other belt type is
  refused before removal, with no spill. A belt that is still short after
  30 s in reach (or that carries a body unable to step off out of reach three
  times) ends the step with the count picked. Ground stacks use native picking.
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
  more of the time (6% at `GO+20m`; from 0.36 the recorder's busy share is
  directed work only, without the mod's upkeep); pilot calls per machine built under 8
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
  A queued or running plan's `next_action` is a `next_event` whose `since_tick`
  is one tick before the queue or read, so a plan that ends before the wait
  starts still returns `plan_ended`, not `queue_empty`.
- A plan with `observation_detail=none` returns compact outcomes, execution
  metadata, and inventory deltas without an embedded observation. An explicit
  compact request retains bounded detail and omission counts; a terminal
  observation is never full (call `observe_local` for that).
- A bounded `plan_status` wait returns on a meaningful step outcome, waiting
  state, or terminal result. A monitoring timeout does not cancel the plan and
  returns a self-describing continuation.

## Two-brain live run

`AGENTS.md` owns the two-brain contract (roles, ledger, packages, upkeep,
idleness, stop, notebook). This section is the live procedure for one
supervised run. The dedicated server and the agent sessions run on the
headless server machine; the exact `Codex` client and the characterless
spectator run only on the client machine. Do not launch a GUI on the server
machine as a recovery shortcut.

### Roles and the one-writer lane

The supervised-debug topology has exactly two persistent reasoning sessions
and one physical writer. Start the sole gameplay pilot as `gpt-6-luna` with
`low` reasoning and fast mode enabled. Start the persistent strategist as
`gpt-6.1-sol` with `medium` reasoning at normal speed and expose only the
disabled-by-default `factorio-readonly` MCP server to it; disable the full
`factorio` server in the strategist session. The strategist owns
NOW/NEXT/LATER and the architecture, and is the sole atomic writer of one
compact `operations.json`, including its initial revision. The ledger is the
strategist's only channel to the pilot. The strategist designs build packages
of its own layouts or this run's blueprints, dry-run with `check_only` (the
only coordinates in the ledger).

The pilot's full-surface bridge queues each new package into the FIFO by
itself, as a plan with source `package:<id>` after the mod's placement check,
with no pilot turn, and records outcomes in `<run_dir>/package-queue.json`.
It never waits for a pilot plan: it holds packages only during a human hold
and while the ledger file is older than the last `stop` it observed (persisted
in `package-queue.json`), so packages written before a stop stay held until
the strategist rewrites the ledger. Leading `blueprint_capture` steps of a
package are made by the bridge before the rest is queued. The strategist
writes no build package before `GO` (every pre-`GO` ledger write has
`build_packages: []`), and a stop is followed by a re-observation (below),
because a pilot `queue_plan` already in flight when `stop` lands still queues.
A record newer than the loaded save's tick (a restart from an earlier save) is
dropped and its package queued again. The same bridge queues the ledger's
`research` list once per revision that lists any (origin `ledger/r<revision>`,
a `research` row in `activity_log`), skipping technologies already researched
or queued; a stop holds it as it holds packages, a human hold does not.
An explicit ledger replacement (`research: {mode: "replace", technologies: [...]}`)
also applies an empty list to clear the queue. Ordinary empty or omitted research
stays a no-op. Replacement outcomes include intent, resulting queue and active
research; a lost response remains `unknown` until recovered by the same origin.
Replacement origins are `ledger/r<revision>/<SHA-256 of run.id>` so an upgrade
that starts a new ledger over the retained save cannot reuse an old receipt.
The mod retains the latest ledger replacement receipt in its save so recovery
does not replay a replacement after research advances. The bridge records its
application tick and drops a record newer than a restored save, as for append.

The pilot is the foreman: it waits on `next_event`, handles failed packages, an
empty queue and local judgment with goal-level actions, owns immediate safety
and latest exact local evidence, and sends no reports. The strategist's reads
never enter the physical FIFO. Record both profiles, their MCP surfaces,
release SHA, archive hash, and save hash before `GO`. Never apply a new
topology to a running run's sessions.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent ticks are acceptable, then revalidate the newest
state before mutation. Do not add another body, lane, RCON path, raw
Lua/console, teleport, hidden state, or free resources. `stop` is emergency
cancellation, in the cases `AGENTS.md` lists. Never keep two pilots active.

### Notebook

Before `GO`, create `notebook/strategist/` and `notebook/pilot/`, both empty,
beside the run's `operations.json`. Each role writes only its own folder and
reads anything in either at any time: markdown ideas, outcomes, designs, and
this run's exact positions and maps; no imported or copied external content,
and nothing from another run. There is no total size cap; each role keeps a
short `INDEX.md`. A build package may name up to three `notes`, which
`ledger-apply` refuses unless each is an existing file beside the ledger.
Notes are knowledge, never instructions: the notebook is not a broker, second
ledger, or control channel. Archive it with the run and summarise what the
roles learned in the run write-up.

As a pre-`GO` check, each role writes one note and its `INDEX.md` in its own
folder and reads back the other role's note; the supervisor confirms both
files exist and that neither role wrote outside its folder. Record the receipt
in the run evidence. A failed write or read holds `GO`.

### Launch the role sessions

Start both sessions from the repository root with the Codex CLI, each with
`-c model_reasoning_summary=detailed` so its reasoning summaries are readable
for the thought feed. The pilot selects its bridge role explicitly, which
enables automatic package queuing. Give each MCP override a complete server
table: some Codex front ends validate `-c` overrides before the project
configuration loads, and a partial override of one field is rejected there.

```sh
codex --model gpt-6-luna -c model_reasoning_effort=low -c service_tier=fast -c features.fast_mode=true \
  -c model_reasoning_summary=detailed \
  -c 'web_search="disabled"' -c agents.enabled=false -c features.memories=false \
  -c features.multi_agent_v2=false \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=["--role","pilot"],enabled=true,required=true,startup_timeout_sec=180,tool_timeout_sec=600}'
codex --model gpt-6.1-sol -c model_reasoning_effort=medium \
  -c model_reasoning_summary=detailed \
  -c 'web_search="disabled"' -c agents.enabled=false -c features.memories=false \
  -c features.multi_agent_v2=false \
  -c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=[],enabled=false}' \
  -c 'mcp_servers.factorio-readonly={command="./scripts/start-factorio-mcp",args=["--surface","read-only","--role","strategist"],enabled_tools=["connect_status","map_summary","progression_status","production_requirements","describe_prototype","observe_local","inspect_entity","plan_status","can_place","find_placement","factory_status","activity_log","next_event","build_layout","connect_entities","blueprint_list","blueprint_describe","blueprint_export","blueprint_place","place_tiles","platform_status","set_watch","clear_watch"],enabled=true,required=false,startup_timeout_sec=180,tool_timeout_sec=600}'
```

The isolation overrides remove the built-in web search, multi-agent and
memory routes: `web_search="disabled"` removes the web tool (it wins over
`--search` and the legacy web-search toggles), `agents.enabled=false` removes
the multi-agent tools (`spawn_agent`, `send_message`, `wait_agent` and the rest
of that set), and `features.memories=false` stops stored memories from being
injected. `agents.enabled=false` alone does not cover `multi_agent_v2`: a user
configuration that enables it brings the same tools back, so
`features.multi_agent_v2=false` is set too. Shell, `apply_patch` and goals
stay, so the strategist keeps `ledger-apply`. On Codex CLI 0.159.2
`features.multi_agent=false` left the multi-agent tools in place, so it is not
used. The flags do not close every route: the shell can still read earlier run
folders, and no documented key turns off `list_threads`, `read_thread` and
`wait_threads`. Not reading earlier runs and not calling thread tools stay
instruction rules. Recheck these keys when the Codex runtime changes.

Fast mode is `service_tier=fast` (read back as the `priority` tier) with
`features.fast_mode` enabled;
the strategist keeps the default (normal) tier. `--role` names the session in
the `origin` of every cancel its MCP process makes. The supervisor starts its
own factorio server with
`-c 'mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=["--role","supervisor"],enabled=true,required=true,startup_timeout_sec=180,tool_timeout_sec=600}'`
before it rehearses `stop`; a server started without one reports `unknown`.

Before relying on the feed, confirm on a throwaway session that both models
emit reasoning summaries with that setting, and record the setting in the
role-profile evidence. If a model emits none, its assistant messages are the
feed. With `model_reasoning_summary=detailed` a model may still leave most
reasoning items without a summary (trial 0011: the strategist summarized 108
of 1424); the shown role's own messages are then most of the feed. The
manifest's `telemetry.roles.<role>.reasoning_summarized` against
`reasoning_items` shows the share.

Start each session with its checked-in role goal; the pilot takes no physical
action before `GO`. Confirm the strategist lists exactly the twenty-one
configured read-only tools (`build_layout`, `connect_entities`,
`blueprint_place` and `place_tiles` there are dry runs only) and cannot list
any movement, transfer, crafting, placement, research mutation, plan
enqueue/run/cancel, or stop tool before `GO`, and that the pilot has the full
surface and no read-only server. Neither role may list a web search or
multi-agent tool.

### Role-profile readback

Launch flags express requested settings; neither a flag nor a successful
settings update confirms a profile. Before `GO`, each role calls native
`execution_settings({})` and sends the supervisor a compact projection copied
verbatim from the result, under 1,000 bytes: the `current_turn` and
`next_turn` model, reasoning effort and service tier, plus
`fast_mode_enabled` and `fast_inherited_from_root` when available. Keep four
kinds of evidence apart:

- **Requested:** launch flags or the exact update values.
- **Current turn:** the native current model, effort and tier; an update does
  not change the turn that made it.
- **Next turn:** the native next-turn values; an update with
  `effective:"next_turn"` applies from the following turn.
- **Availability/inheritance:** the fast-mode flags, recorded verbatim. In
  the runtime validated so far, `fast_mode_enabled` follows the selection
  feature, not the selected tier, so judge normal speed by the tiers.

If preparation changes a profile, end that turn and read again in the next
one. Require both turns to match pilot / low / `priority` and strategist /
medium / default tier. Missing, stale, malformed or contradictory reports hold
`GO`; a sent report is not a consumed one. These tiers describe the selected
settings, not provider processing; never infer the latter from latency or a
flag. Recheck the field semantics when the Codex runtime changes (see the
[Codex configuration reference](https://developers.openai.com/codex/config-reference)).

### Initialise the ledger

Before `GO`, verify the requested fresh save and release hashes, permanent
peaceful mode/enemy bases disabled, exact native player, viewer, and one
body/lane/writer. Archive the previous run's `operations.json` and
`package-queue.json` into that previous run's directory and verify the current
destinations are absent. The bridge reads the ledger at
`<run-dir>/operations.json` of the server `server start` started. Give the
strategist that absolute path and the exact `run` object (`id`, `release_sha`,
`baseline_save_sha256`, `save_identity`, `created_at`, `roles` per the ledger
schema: `{"pilot":{"model":"gpt-6-luna","reasoning":"low","fast":true},`
`"strategist":{"model":"gpt-6.1-sol","reasoning":"medium","fast":false}}`), and
have the strategist create it by piping an
`{"init": true, "run": <that object>, "source_tick": null, "update": ...}`
envelope to `node_modules/.bin/tsx companion/src/cli.ts ledger-apply --ledger
<absolute operations.json path>` from its checkout. Fill `update` with the
mutable fields (`phase`, `bottleneck`, `latest_measured_capacity`, `task_list`
with NOW/NEXT/LATER, `assumptions`, and `build_packages: []` (required for
every write before `GO`; every later update restates the list). Verify the
receipt returns `status: "applied"`, revision 1, and the submitted source
tick, that the persisted schema-2 ledger has mode `0600` and an empty
`build_packages`, and that `<run_dir>/package-queue.json` is absent or has no
records. Initialization refuses every existing destination without
replacement. Later updates use the `{run_id, save_identity, source_tick,
update}` envelope and require a newer tick. Never hand-seed the ledger: the
strategist is its sole atomic host writer.

### Session control checks before GO

`AGENTS.md` requires the supervisor to prove, before `GO`, that it can deliver
a message to the exact pilot session and can interrupt and retire that session
so it cannot resume gameplay writes. Use whatever session mechanism launched
the roles (the Codex TUI, or the Codex app-server's thread and turn controls
for a connected session). Prove retirement on a disposable non-gameplay
session through the same mechanism, and only confirm that the route is
available for the exact pilot; never retire the prepared pilot as a test.
That disposable session must not start the factorio MCP with `--role pilot`
or inherit `FACTORIO_CODEX_ROLE=pilot`: a pilot-role process claims a new
writer generation and so retires the prepared pilot's writes.
Delivery is not consumption: a message counts as received only when its text
appears in a turn of the exact target session. Prove this with the exact
`userMessage` text and client marker. Admission of
explicit user input is separate from automatic Goal continuation: a paused
Goal does **not** hold `thread/queue/add` for a later `thread/queue/start`.
On the runtime tested below, adding to an idle subscribed thread starts a turn
automatically while its Goal remains paused; adding to a busy thread waits
until its current turn ends, then starts automatically. Neither pausing the
Goal nor subscribing with `thread/resume` is a dispatch barrier. For a stop or
other deadline-sensitive instruction, use the session mechanism's separately
proven active-turn steering or interrupt route; the queue is not an interrupt.

#### Native queue reproducer (no Factorio connection)

Run this after a native runtime change through the same session mechanism as
the roles. Use a disposable persistent thread in an empty scratch directory,
with every MCP server disabled, no Factorio configuration or
`FACTORIO_CODEX_ROLE`, and instructions to reply only with the requested text
without tools or Goals. Never use a prepared role as this test. Record the
native `--version`, binary identity, and the schema generated by
`app-server generate-json-schema --experimental --out <scratch-schema>` from
that exact binary. For a stdio app-server client, initialize with
`capabilities: {experimentalApi: true}`, then send `initialized`. Retain
request/receipt times and notifications; notifications and RPC responses can
interleave. The following are method/parameter examples, with `T` the returned
thread ID and distinct fresh markers `PREP`, `IDLE`, `BUSY`, and `RELEASE`:

1. `thread/start` with the isolated `cwd`, `approvalPolicy: "never"`,
   `sandbox: "read-only"`, and the no-tools instructions. Submit
   `turn/start {threadId:T, input:[{type:"text", text:"Reply exactly PREP"}]}`
   and await that exact turn's successful `turn/completed` and assistant text.
2. Set a harmless waiting objective directly to paused with
   `thread/goal/set {threadId:T, objective:"Wait for explicit test input",
   status:"paused"}`. Read `thread/goal/get {threadId:T}` back; do not briefly
   activate the Goal. Subscribe using `thread/resume {threadId:T}` and confirm
   the preparation turn is finished and the thread idle.
3. Submit **once**: `thread/queue/add {threadId:T, clientUserMessageId:IDLE,
   input:[{type:"text", text:"Reply exactly IDLE"}]}`. Record the returned
   `queuedSubmission.id`, its `clientUserMessageId` and input. Read
   `thread/queue/list {threadId:T}` and capture `turn/started`, `item/started`
   and `turn/completed`; do not call `queue/start` as a prerequisite.
4. Read `thread/items/list {threadId:T, turnId:<consuming-turn>}` and follow
   `nextCursor` until exhausted. Each `data` entry wraps `{turnId, item}`;
   match `item.type == "userMessage"`, its exact content and `clientId`.
   Confirm exactly one matching user message across the target's turns
   (`thread/turns/list` supplies pagination), and read the Goal back again.
   An assistant acknowledgement corroborates, but does not replace, that
   input evidence. Pending-queue absence alone proves neither consumption nor
   loss. On this runtime `thread/read {threadId:T, includeTurns:true}` also
   worked; use item pagination when history is not fully hydrated.
5. Only after proving consumption, exercise
   `thread/queue/start {threadId:T, queuedSubmissionId:<returned-id>}` as a
   diagnostic. Record a missing-submission response as queue-state evidence,
   **not** delivery failure. Never resubmit the marker. In real GO handoffs,
   inspect pending submission state and exact input consumption first after
   any missing-submission response, timeout, disconnect, or uncertain receipt;
   keep dispatch unresolved if neither settles it. Do not send another GO.
6. Check the busy case separately: start a harmless text turn, confirm its
   `inProgress` state, then immediately add the distinct `BUSY` marker once.
   Confirm its submission is pending while that turn runs, and that no
   `userMessage` containing it entered that active turn. Await completion and
   the subsequent automatically started consuming turn, read its exact input
   back, and check the queue and still-paused Goal. If the first turn ended
   before admission, this attempt did not test busy behavior; use a new
   harmless trial with a new marker, never resend an unresolved marker.
7. Rehearse the handoff ordering below using the prepared native rollout and
   existing `createThoughtFeed` / `rolloutResolver` exports. Use an offline
   baseline receipt and a stub `say` callback instead of a game connection.
   Start the feed following an empty retired fixture, atomically switch its
   pointer to the replacement's real preparation rollout, call `feed.tick()`,
   and require the unique `PREP` assistant row in its output with
   `said_at:null` before dispatch. Submit `RELEASE` once via `queue/add`, prove
   its single consuming user message, then tick again and check its assistant
   row. With a hidden pilot, all rows stay archival and the stub receives no
   calls; with a shown ledger writer, only post-adoption output is eligible
   for `say`. Stop the feed and await it. This tests ordering and source
   adoption, not a live game snapshot or panel acknowledgement.
8. Clear the disposable Goal, archive the thread through native controls,
   close its owned app-server and feed, and verify both exit. Keep the
   versioned outcomes in the validation evidence; remove owned scratch after
   all consumers stop. Unsupported methods or an unobserved case stay
   unverified, not inferred from a schema or a different runtime.

Validated on **2026-10-25 UTC**, `codex-cli 0.159.2`, installed generation
`0.159.2-70bf39f021b012290b57fd04`, binary SHA-256
`c65f92b2649aa41a9738214ac71c2dd9b34497fe294152b25a372dfc7875494b`.
The generated experimental v2 schema requires `threadId`, `input`, and
`clientUserMessageId` for `queue/add`; its response is a `queuedSubmission`
with `id`, `input`, and `clientUserMessageId`. `queue/list` returns `data` plus
`nextCursor`; `queue/start` takes `threadId` and optional
`queuedSubmissionId`, returning a `turn`. The schema exposes no admission-hold
parameter on these methods. These shapes identify the tested contract; schema
presence alone does not establish runtime scheduling. Native turn/item pagination
was also exercised with page size one; persisted readback confirmed one
matching input per marker, across two turns in the idle probe and four in the
handoff/busy probe. All disposable Goals were cleared, threads archived, and
the owned app-server/feed processes exited.

| Non-gameplay observation | Actual outcome |
| --- | --- |
| Finished preparation, paused Goal readback, `thread/resume`, one idle `queue/add` | Turn started automatically, exactly one matching `userMessage` and acknowledgement; Goal remained paused. Queue was already empty. |
| `queue/start` with that consumed submission's exact ID | Error `-32600`, `queued submission not found`; no resend. |
| Add while another text turn was active | Submission remained pending during that turn, then automatically entered a different turn exactly once after completion. The first turn contained only its original input; the final queue was empty and Goal still paused. |
| Replacement handoff with the existing feed and offline baseline | Baseline fixture at `23:03:01.364Z`, observed preparation-marker adoption at `23:03:01.367Z`, dispatch at `23:03:01.373Z`, admission receipt at `23:03:01.386Z`, native start observed at `23:03:01.391Z`, and exact single input consumption at `23:03:01.409Z`. Assistant rollout time was `23:03:02.366Z`, archive observed at `23:03:02.379Z`, with `said_at:null` and zero pilot display calls. No Factorio RPC or live panel check. |

These are version-limited observations, not a promise about another installed
Codex build, TUI queue, or remote transport. Repeat unsupported or changed
contracts before relying on them for GO.

### Stop rehearsal and GO

Rehearse the explicit stop sequence (below) on the live role sessions without
stopping the server; a role turn must end within about five seconds of pause
plus interrupt. Then resume both role goals. A resumed goal can start a
continuation turn by itself: interrupt that turn and confirm it did no
physical work. Pass the notebook check above and the takeover rehearsal below
or its recorded skip, on a resumed save repeat the retained-work
reconciliation (`stop` with `keep_upkeep: true`, see the upgrade steps below)
so the last `stop` before `GO` leaves upkeep on, and only then start the
recorder:

```sh
node companion/dist/cli.js runs record --ledger <run-dir>/operations.json --variant <name> --change <description> \
  --pilot-rollout <pilot rollout.jsonl> --strategist-rollout <strategist rollout.jsonl>
```

Treat dispatch through **any** route that can admit input immediately as the
release point. Before it, finish and record both role-profile readbacks,
notebook/rehearsal checks, and any replacement's old-writer retirement,
settled in-flight calls and fresh physical-quiescence checks. Preserve exactly
one body and gameplay writer. Confirm the recorder's persisted baseline sample
and startup receipt; its console `GO` line labels that baseline, not delivery
of a role's GO message.

For a replacement, have its completed preparation turn emit a unique harmless
assistant marker alongside its profile report. Record its exact rollout source
and preparation-line timestamp. Atomically update `<run_dir>/rollouts.json`
with `{"pilot": path, "strategist": path}`, preserving the other role's source.
A pointer-file write is only a request: before dispatch, confirm the running
recorder has adopted the new source by finding that exact marker, role and
rollout timestamp newly archived in `thoughts.jsonl` with `said_at:null`.
Record the pointer-write time and the receipt time of that adoption evidence
separately. Do not append synthetic lines to native rollouts, wait an assumed
one-second poll interval, or use the old source's output as proof. If adoption
cannot be proved, hold GO and diagnose the recorder/source while the
replacement remains prepared. On source change the feed archives the retired
pending chunks and the replacement's already-complete preparation lines;
only subsequently read lines are eligible for live display. Switching after
GO can therefore archive its acknowledgement instead of displaying it live.

After all applicable preparation and adoption evidence exists, submit exactly
one `GO` message per exact role session, with a unique client marker where the
route supports one. Record the target, dispatch time and submission receipt
before evaluating admission/start; a paused Goal is never the release barrier.
The pilot's GO text names the strategist's exact thread ID, as does any
replacement pilot's assignment, so neither role reads threads to find the
other; the pilot still sends the strategist no reports. Each role's GO text
also carries this line: "Never call list_threads, read_thread or
wait_threads; after any compaction re-read your goal file and SKILL.md, then
your notebook INDEX.md." No configuration filters those coordination tools
per action, so this text rule is the control. In the existing run evidence,
keep these distinct for each role:

- Recorder baseline time/tick, preparation completion, applicable retirement
  and quiescence receipts, source-pointer write and observed adoption receipt.
- GO dispatch and admission receipt (including submission/client identity),
  native turn start, and exact GO `userMessage` consumption in its target
  session and consuming turn. Reconcile uncertain delivery using both native
  submission state and exact input readback before any further dispatch action;
  neither an empty queue nor `queue/start` not-found authorizes a second GO.
- Assistant/reasoning rollout timestamps, recorder archival observation, and
  `thoughts.jsonl.said_at` when a successful `say` acknowledgement exists.
  A non-null `said_at` is the display RPC acknowledgement time, not the GO
  dispatch, input consumption, or exact screen-paint time. Null means no
  acknowledgement was recorded. The recorder archives both roles but shows
  only the ledger writer (strategist in a two-role run, pilot in a solo run);
  a two-role pilot's output needs no game-panel acknowledgement. User messages
  themselves are not thought-feed output.

A Goal's active/paused state and an idle session do not establish input
consumption. Read the exact session back instead of sending GO twice. Once
release is proven, ensure the role Goal is active and read that state back so
native continuation, not a supervisor message per batch, starts later batches.
Activation for released gameplay continuation can itself start a turn: do it
only after the same preparation is complete, without another GO submission.
The controlled pre-GO resume rehearsal above is a separate capability check;
it sends no GO, authorizes no physical work, and still requires interruption
and the no-physical-work readback before continuing preparation.

At `GO+20m` record the recorder checkpoint as the run's comparison snapshot
without stopping anything; assisted debug progress is still not benchmark
evidence. Continue past 20 minutes toward the assigned milestone (currently
sustained Nauvis production: lines that `factory_status` reports `running` and
`self_sustaining` at the next two recorder checkpoints, plus research consuming
produced science). A rocket milestone's time is the recorder's
`telemetry.milestones.rocket_launched.elapsed_s` (the mod's first
`on_rocket_launched` tick less the baseline tick, also in each sample's
`run_snapshot.milestones`). Measure each run at `GO+20m` and `GO+60m` against the
cycle-10 targets in the release checklist above and the earlier cycles in
`docs/AGENT-PLAY-PERFORMANCE.md`. Candidate B and R1-R7 freeze rules are
historical unless the owner starts a benchmark.

### Explicit stop

### Recorder loss and debug continuation

SIGINT and SIGTERM ask `runs record` or `runs continue` to settle its thought
feed, capture a final sample and close the manifest. Wait for `FINISH`.
Uncatchable process loss cannot do that; an open manifest and absent receipt
do not identify the disappearance cause. Preserve the existing evidence and
reconcile the actual recorder/role/game state before acting. Recorder loss
does not itself stop either role or the physical FIFO.

To resume observation of the same unfinished debug run, use
`factorio-codex runs continue <run-id> --ledger <run-dir>/operations.json`,
with the original rollout flags or the run's current `rollouts.json` pointer.
The ledger's complete run identity must match the manifest, which must remain
`recording` with null end fields and an intact original baseline. Use the same
companion, mod and Factorio versions and live factory; do not reset the mod's
body-time window. Linux util-linux `flock` is required. A live recorder holds
the run lock until its fd closes, including on SIGKILL. Concurrent recorders,
terminal recordings, mismatched ledgers and benchmark continuation are rejected.

The receipt is `CONTINUE`, not a new gameplay `GO`. Check the persisted
`recorder_continued` event and current `continuation` sample: the event names
the prior record and last successful observation, the elapsed resumption
boundary, the observation gap and missing checkpoint slots. Expect no samples
backfilled at old checkpoint times. Original samples, baseline counters and
start time stay intact; subsequent deltas and checkpoints retain that origin.
Crash-truncated unterminated JSON tails are preserved verbatim in sibling
`.truncated-*` artifacts and listed in the event. Complete corrupt records or
schema-invalid records are rejected without repair. Do not remove or reinterpret
earlier valid evidence to make continuation succeed.

Available current rollout history is recovered as archive only, with persisted
occurrences deduplicated and existing `said_at` values retained. Recovered lines
have null acknowledgements and are never replayed. The event reports source
availability; retired/unavailable sources and unusable timestamps may leave
missing history, and a lost acknowledgement remains unknown. Final role timing
coverage is explicitly partial from continuation onward; earlier timing, if
present, remains in continuation events. Verify a new live thought separately.

`runs interrupt <run-id> --reason <text>` closes an abandoned recording after
supervisor reconciliation and makes continuation ineligible. It does not stop
the FIFO or role sessions. For a mod upgrade or new recording, follow the
explicit-stop and upgrade/new-run procedure below, use a new run identity and
baseline, and redo pre-GO checks. Never use continuation to renew a benchmark
deadline or obtain a scored verdict across an observation gap. Source/offline
verification of continuation is separate from installed-companion and live-game
validation, which require their own observed receipts.

For an explicit stop by the owner, record each step: call factorio `stop`
(cancels the active task and every queued plan within seconds); in each role
session run `/goal pause` and read back the paused state; interrupt any active
role turn with the TUI stop control or the app-server `turn/interrupt` for
that role's exact thread and turn, and read back the interrupted turn; check
separately that no task-owned command or job is still running; confirm the
strategist makes no further ledger write; wait at least 2 s (more than one 1 s
bridge tick), call `observe_local`, and if it shows an `active_task` or
`queue_depth > 0` (a pilot `queue_plan` in flight before the interrupt lands
after `stop`), call factorio `stop` again and re-observe until idle; only then
run recorder FINISH (interrupt `runs record` and wait for its `FINISH` line)
and `server stop <run-dir>`. A steered cancel message reaches a busy role at
its next step but stops nothing by itself.

### Resume with a mod upgrade

To continue a run's factory with a new release instead of a fresh map:

1. Stop the old run with the explicit-stop sequence above, recording each
   step. Its final `save.zip` holds the factory.
2. Build the new release (`npm ci && npm run build && npm run package:mod`)
   and create a new run directory with `server create <new-run-dir>`, which
   installs the new mod into its run-local mod directory. Replace its
   `save.zip` with the old run's final save, unchanged, and copy the old run's
   `notebook/`.
3. Update the `Codex` client to the same mod version, then
   `server start <new-run-dir>`; it refuses a protocol or mod version mismatch.
   Confirm `connect_status` versions and that `observe_local` shows an idle
   body. A plan step saved by an older release that no longer exists completes
   as a no-op with code `REMOVED_ACTION`; treat every pre-upgrade plan ID as
   invalid for `after_plan_id`. Reconcile retained work: call `stop` with
   `keep_upkeep: true` once even when idle (upkeep stays on) and re-observe
   until idle. Repeat that call after the stop and takeover rehearsals, whose
   plain `stop` turns upkeep off until a plan finishes, so it is the last
   `stop` before `GO`.
4. The old run's `operations.json`, `package-queue.json` and
   `ledger-history.jsonl` stay archived in
   its directory. The strategist initialises the new run's ledger from fresh
   reads (packages from the old ledger are not queued again); the copied
   notebook continues, because a resumed save of the same factory continues
   its run.
5. Start the role sessions with this release's settings and their updated goal
   files, redo the role-profile readback, start the recorder with
   `--pilot-rollout` and `--strategist-rollout`, and send `GO` as above.
   Record the upgrade as an intervention.

### Takeover rehearsal before GO

The human player may take the Codex body over by mouse and keyboard at any
time, through the native `Codex` client window. Real control input on that
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

The rehearsal needs the human player's real input, so it runs only when the
supervisor's assignment says in so many words that the human player has agreed
to do the takeover rehearsal now; "the human player is watching" is not that.
This applies to fresh and resumed runs alike. Otherwise the supervisor
verifies `character.human_control: false` on one fresh `observe_local`,
records `human_idle_ticks` and the rehearsal as skipped in the run evidence,
and does not hold `GO`; the takeover acceptance item stays unproven for that
run. Never simulate the human player's input.

When it runs, rehearse it once before that run's `GO` on the live server with
the supervisor driving the plan, since the pilot acts only after `GO`. The
supervisor's factorio MCP runs with `--role supervisor` on the full surface:
its writes carry the supervisor label, which the writer fence lets through
after a pilot has claimed a generation, on a fresh or a resumed save:

1. Queue one harmless bounded plan (a short `walk_to` and return) and confirm
   `fifo.human_control: false`.
2. The human player moves the character in the `Codex` client. Within about
   one second an `observe_local` shows `character.human_control: true`, a
   small `human_idle_ticks`, the plan still queued or active, and no position
   change the mod caused.
3. Queue a second plan during the hold; it is accepted and queued.
4. The human player releases input. Within about ten seconds `human_control`
   is false and both plans finish in order, with `human_control` on their
   results and neither lost, cancelled, or failed.

Record the four receipts in the run evidence and hold `GO` on any miss of a
rehearsal that ran. End it with one recorded factorio `stop` and a fresh
`observe_local` showing no active task and queue depth 0. A `run_plan` that
returns nonterminal with `human_control: true` is not a failure, in the
rehearsal or during a run: the plan is still queued or active behind the hold,
so read it with `plan_status` after release instead of requeueing it. A direct
tool call that fails with a human-hold reason is retried after the hold.
During a run a hold is the human player's input, not idleness: the supervisor
records it, never nudges or replaces during it, and restarts idle timing from
fresh evidence afterwards.

### Idle evidence

While milestone goals remain open, a fresh valid `observe_local.character`
with `active_task` absent or with `source: "upkeep"`, numeric
`queue_depth == 0`, and numeric `crafting.queue_size == 0` proves the pilot
idle, and only while `human_control` is false. Upkeep is the mod's own
refuelling, not pilot work; a package plan (`source: "package:<id>"`) is
work. A missing character or required field, malformed response, stale sample,
or failed call is uncertain, not idle. Inspect a known plan only with its
exact `plan_id`; `plan_status {}` is invalid.

Time an idle interval from observation receipt timestamps for the current
pilot session and ownership generation, applying the ownership reset in
`AGENTS.md` before evaluating eligibility. Associate observations and intervention
receipts with that owner in the existing run evidence; an observation whose
ownership is uncertain cannot establish the replacement's idle baseline.
Compare each
sample's physical signature (position, carried inventory, `active_task`,
`queue_depth`, crafting state) with the last one, and keep the start of the
interval across unchanged samples. Discount position, inventory and task
changes when either sample shows an `upkeep` task, or when every
`activity_log` plan between the two samples' ticks was an `upkeep` plan (an
upkeep refuel that started and ended between samples is visible only there).
Nudge and replacement thresholds and steps are in `AGENTS.md`.

| Scenario | Required result |
| --- | --- |
| Open goals, no active task, queue depth 0, crafting queue size 0 | Valid fresh evidence starts or continues the idle interval. Closed goals do not trigger intervention. |
| Active work, even with queue depth 0 | No idle claim or intervention; reset the prior interval. |
| Character crafting with no active task or queued plans | No idle claim; crafting queue size greater than 0 is work. |
| Only an `upkeep` plan active (the mod refuelling), no queued plans or crafting | Idle evidence continues: upkeep is not pilot work, and its movement or inventory changes do not reset the interval. |
| A package plan (`source: "package:<id>"`) active or queued while the pilot waits on `next_event` | No idle claim; the body is working. |
| Parked waiting plan or predecessor-blocked queued plan, body still | Queue depth greater than 0 means pending work; no idle claim. |
| Repeated unchanged samples while ticks and factory output advance | Keep the original idle start; for an idle transition at 00:00, unchanged samples at 02:03 and 03:12 report 123 s and 192 s. |
| Unknown transition, first idle observation at 02:03 and unchanged sample at 03:12 | Report at least 69 s observed idle, not an exact start before 02:03. |
| Missing, malformed, failed, stale observation, or run change | Invalidate timing; no intervention based on the uncertain interval. |
| `human_control: true` (the human player playing the body) | No idle claim, nudge, or replacement. Record the hold as the human player's input, invalidate timing, and require fresh idle evidence after it. |
| A has exceeded five minutes idle and consumed its nudge; B takes ownership between otherwise unchanged idle samples | Reset timing, physical baseline, single-nudge state, consumption eligibility, and interrupt waiting before evaluating B. B's first fresh valid idle sample starts a conservative lower bound of 0 s; at 69 s later, report at least 69 s, with no eligibility inherited from A. Keep A's observations and intervention/delivery history. |
| Pilot session changes with the same generation, or generation changes within the same session | Either change independently resets the evidence used for eligibility. A predecessor's consumed token or elapsed stale-turn interrupt wait cannot authorize replacement of the current owner. |
| Ownership changes, but B's observation is missing, invalid, stale, failed, or not attributable to B | No idle lower bound or intervention eligibility for B; await fresh valid evidence belonging to B. A's last sample and quiescence proof cannot substitute for it. |
| Ownership changes during a human hold | Retain the hold and its history, reset predecessor eligibility, and make no idle claim or intervention. Start B's lower bound only from fresh valid idle evidence after release. |
| A's idle interval is interrupted by a human hold; B takes ownership after release | Preserve the human-control transitions as history. Neither A's pre-hold interval nor an A sample after release starts B's interval; require B's own fresh valid idle sample and evaluate only B's subsequent evidence and receipts. |

Offline tests prove neither message delivery nor live retirement or
replacement; claim live behaviour only from a supervised run with delivery
and retirement receipts.

### Writer fence on replacement

The pilot's MCP process (`--role pilot`, full surface) claims a writer
generation from the mod (`claim_writer`) when it starts, once per process,
and sends it with each of its writes: the gameplay writes (`enqueue`,
`queue_plan`, `start_research`, `travel`, the platform, request, settings,
recipe and blueprint writes) and `cancel`. Reads are never fenced. When a
replacement pilot's process claims the next generation, the mod refuses every
write that carries an older one with `WRITER_RETIRED`: the old pilot's write
tools fail with code `WRITER_RETIRED`, and its bridge stops queuing packages
and gives up the run's package lock, so the replacement's bridge queues them.
`ping` reports the newest `writer_generation`, and `factorio-codex doctor`
shows it with the tick it was claimed at, so a claim nobody expected shows.
The supervisor's process (`--role supervisor`, full surface) claims nothing
and labels its writes as the supervisor's; the fence lets them through, so
the supervisor can drive the takeover rehearsal and debug rescues. A write
with neither a generation nor that label (an older companion, or an
unlabelled full-surface session) passes only while no generation has ever
been claimed in the save; after that only `cancel` does, so the supervisor's
`stop` always works. A claim sends the host clock in seconds as a floor, and
the new generation is at least that, so after a save from before a claim is
reloaded the next claim on the same host is still newer than the one the
earlier pilot holds. A save loaded from before the newest claim also takes
the newer generation from the first write that carries it.

So once the replacement's process has connected (its `ping` shows its
generation as the newest), the old pilot can no longer write, whatever its
session does. The fence cancels nothing: plans the old pilot already queued
stay committed, so settle and observe them as above before the replacement
starts.

A transport fault during a write (an RCON timeout, or the connection closing
before the whole reply arrived) returns `status: "outcome_unknown"` with code
`OUTCOME_UNKNOWN`: the call may or may not have run in the game, and its
summary says to read `observe_local` (or `plan_status` for a known plan) to
see whether it did before repeating it. Nothing is
retried except the `queue_plan` tool, which sends the call once more with the
same `client_key`. The mod answers a key it has seen (it keeps the last 32)
with the plan that call queued (`duplicate: true`), so the retry never queues
a second plan.

### Supervisor interventions and watching

The supervisor may diagnose or recover through its own surfaces; that
authority does not pass to the pilot. Record each intervention and obtain a
fresh structured observation before ordinary play. Mirror every intervention
that touches the game process into the recorder's events with
`runs mark-assisted <run-id> --reason <text>`: raw RCON or console, a
temporary surface, emergency `stop`, teleport, and server or client
replacement. The supervisor yields its own turn between recorder checkpoints
and records the structural-growth deltas defined in `AGENTS.md` at each one.

Watch the run through the ordinary viewer client, which the mod makes a
characterless spectator that follows Codex, not through the native `Codex`
client window. The `Codex` client's own character is moved by the mod, and
Factorio client latency hiding mispredicts script-driven walking of a client's
own character, which shows as stutter and snapping on that window only. The
`Codex` client must remain connected; it is also the window the human player
takes the body over from, so any real input in it parks the FIFO. During a
debug run, keep the client log's `Latency changed to (N)` values below 60
ticks; a spike to the 254-tick ceiling marks a long server tick.

The gameplay pilot remains MCP-text-only: the screenshot capability of any
desktop or UI tool must never be used for Factorio perception or play.
Post-run screenshots are permitted only after the scored run is frozen and only
when structured MCP evidence is insufficient for review. Review all relevant
map areas where items or machines were placed, but treat images as
non-authoritative: they must not contribute coordinates, routes, tactics, or
durable knowledge, and they never support live perception, navigation,
targeting, placement choice, or action selection. Revalidate every finding that
could affect a later run through structured in-game MCP data. This permission
does not authorize desktop GUI control of the game.

### Viewer-only session

The exact `Codex` client must join first. Every other connected identity is
made characterless and placed in spectator mode by the mod; there is no second
body and no administrator or console step. The current mod makes each connected
spectator camera follow the sole Codex body automatically. Codex itself still
walks physically; only the characterless viewer camera follows. Confirm the
viewer identity has no body or inventory and remains aligned with Codex
during a physical `walk_to` action.

## Historical live evidence

### Historical Candidate B R7 verified live result

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

### Prior verified 0.8.0 live result

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

### Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below are historical 0.7.0 evidence and
diagnostic guidance, not live validation of the current release.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A current run reports the current protocol and mod/app version.
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
- The observed client launch reached `InGame` and the server logged the join.
  A successful network join alone does not prove spectator mode; verify the
  controller in the Factorio UI as described above.

## Engineering investigations

These engineering records explain retained mod and instruction behaviour.
None of them is gameplay or benchmark evidence.

### Underground direction, automatic pairing and completion readback (2026-10-25)

Underground direction and pairing were investigated against source
`c7539a47ebe7729ba7fac1d2b8b06ee747814906`, mod **0.38.1**, protocol **29**,
using official Factorio **2.0.77, build 84539, linux64 headless**. The downloaded
archive SHA-256 was
`c4efc11529f74d37c96933e291e0db73fd9f5aa4738913d9301b24680b3e947f`.
The live-state readback correction from
`40032d1a4786ed5553f69ed7f6f24bc26164752e` is already present: ground layout
completion reads the retained entity's actual direction, endpoint type and
partner, including a paid placement that failed configuration verification.

#### Native creation survey

An isolated copy of the existing live-test harness created a real character
and clear concrete ground. On clear ground, all eight combinations of native
direction `0`, `4`, `8`, `12` and explicit `input`/`output` preserved both
requested values and had no partner. In particular, a north-facing output
really has direction `0`; direction `8` is not a universal output convention.

A second survey held an earlier endpoint at `(162.5,29.5)` and created the new
endpoint three tiles north at `(162.5,26.5)`. It exercised all sixteen
combinations of earlier and new direction `0`/`8` and `input`/`output`:

| Earlier endpoint | New request | New native state | Pairing |
| --- | --- | --- | --- |
| `0 input` | `0 output` | `0 output` | Paired with earlier input |
| `0 input` | `8 input` | `0 output` | Paired with earlier input |
| `8 output` | `8 input` | `8 input` | Paired with earlier output |
| `8 output` | `0 output` | `8 input` | Paired with earlier output |
| Remaining twelve combinations | Requested direction and type | Both preserved | No partner |

The earlier endpoint retained its unit identity, direction and type in every
case; successful pairing added its reciprocal neighbor. Thus these samples
demonstrate automatic changes to the **new** endpoint, not a reversal of an
earlier endpoint. They do not establish that earlier-endpoint reversal is
impossible in other configurations. Existing final-readback protection remains.

#### Physical placement and ground-layout receipts

The physical comparison used the real `place`, `build_plan` and queued
`build_layout` paths, one character at `(160,30)`, and the new endpoint position
above, within build reach. Each single-placement case started with ten carried
underground belts. The nearby-endpoint case also had an existing `8 output` at
the earlier position. Every request explicitly asked for a `0 output`:

| Path | Clear ground | Near existing `8 output` | Inventory after either attempt |
| --- | --- | --- | --- |
| `place` | `done`, actual `0 output`, no partner | `failed`, `UNDERGROUND_CONFIGURATION_MISMATCH`, actual `8 input` paired with earlier output | 9 |
| `build_plan` | `done`, placed 1/1 | `failed`, `BUILD_PLAN_STEP_FAILED`, placed 1/1 with configuration mismatch | 9 |
| `build_layout` through FIFO | `completed`, `LAYOUT_BUILT`, row `0 output` | `partial`, `LAYOUT_PARTIAL`, retained placed row `8 input`, partner `8 output`, configuration mismatch in failed row | 9 |

Fresh inspection agreed with each completion's reported native state. The
nearby output kept its unit identity, direction `8` and type `output`; its new
partner remained valid and paid. No corrective rotation, refund or replacement
was performed. The layout's queue transitions were tick 98 to 99 on clear
ground and tick 108 to 109 beside the existing endpoint; each terminal read
reported an empty FIFO. These receipts exercise ordinary elapsed game ticks,
not offline substitutions for entity direction or type.

A separate physical input placement at the earlier position completed as
`0 input`, initially unpaired. A subsequent queued `0 output` layout completed
as `LAYOUT_BUILT`; the earlier input kept its unit identity, direction and type
and gained the output as its partner. Inventory went 10 to 9 to 8. A two-end
layout also completed as `LAYOUT_BUILT`, consumed exactly two belts, and
reported **both** reciprocal partners in its final placed rows, including the
earlier input whose partner was absent when it was first built.

The mismatching case changes endpoint type as well as direction: the requested
north-facing output becomes a south-facing input. This is an unmet explicit
configuration request, not merely a numeric direction discrepancy. Native
evidence therefore supports retaining the existing mismatch classification
and live readback; no production placement code change is justified.

#### Fixture limits

Both throwaway servers reused the harness's isolated config, copied mod,
random local ports, cleanup, and real-character setup. No gameplay server,
installed mod or client was upgraded or restarted. The raw creation survey
does not prove physical reach or material accounting; the physical cases above
supply that separate evidence. Test setup supplied inventory and cleared the
fixture site; this is assisted engineering evidence, not gameplay progress.

Disconnected headless servers do not process player chart requests. The
existing harness already substitutes its documented body and chart adapters.
For the physical comparison only, the **copied** `build_layout.lua` replaced
its corner-chunk chart query with the native generated-chunk query. This
admits the generated fixture ground while preserving placement geometry,
collision checks, real inventory, reach, FIFO execution and native pairing.
No chart substitution was made in repository source. Cases stayed within
reach and needed no walking or fetching; they do not validate chart admission,
remote logistics, human takeover, active deployment, or other endpoint geometries.

Verification passed: the focused underground and layout Lua tests, typecheck,
build, and `npm test` (20 unit-test files, 513 unit tests, mod tests and package
verification). The unmodified `FACTORIO_LIVE_REQUIRED=1 npm run test:live`
suite passed all 19 scenarios and its handler, script-error and timing checks:
145 RPCs, 174 job ticks, slowest measured RPC/tick 4.48 ms, and worst
600-tick average 0.266 ms/tick. Separate receipt assertions checked all 24
native creation cases and eight physical comparisons above. A fresh independent
read-only review compared the documentation, fixture adaptations, receipts and
placement code and found no actionable discrepancies. This is source evidence;
it does not assert validation of a deployed gameplay runtime.

### Occupied-belt placement agreement (2026-10-02)

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

#### Isolated physical comparison and limits

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

#### Source and archive identities

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


### Adjacent burner-inserter fuel feed (2026-10-02)

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

#### Native recipient query and limits

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

#### Fixture identity and source readiness

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

### Release 0.19.7 cycle-7 accidental pilot cancellation

The captured incident evidence reports a supervised debug run on
release 0.19.7, source commit `0777538bb4eaadef6bea89eb18b44d5fbcf27845`.
The pilot invoked `stop` during ordinary gameplay without an owner stop request.
The native completed result at `2026-10-02T18:45:04.326Z` was `cancelled2`;
the pilot then reported plans 31/32 cancelled. A subsequent fresh structured
character observation at tick `141409` showed pending physical work and resumed
continuation. These are attributed incident facts, not a new live reproduction
or proof of physical quiescence. The run remains assisted; its progress and
timing are excluded from benchmark evidence.

The source guidance offered ambiguous cues: the shared skill said “Stop only
on an explicit owner request,” while the tool description suggested cancellation
after a TUI interruption. Those are instruction defects; whether either caused
this model's tool selection is a hypothesis, not established by the cancellation
receipt. The correction reserves the tool to the supervisor, prohibits its
ordinary pilot use, and directs recovery to fresh state, exact known plan IDs,
retained effects, and remaining safe FIFO work without rollback.

Offline verification covers contract consistency and retained cancellation
mechanics, not improved live model behavior. Review ordinary continuation,
monitoring timeout, and partial-plan recovery as non-cancelling pilot paths;
review an explicit owner stop, pre-`GO` retained-work reconciliation, and
emergency replacement as the existing recorded supervisor paths. Startup still loads the
role goal and hard skill; after compaction roles re-read them before other calls.

Source publication, loaded role guidance, installation, and observed gameplay
results are separate evidence. This instruction/tool-description correction
requires no mod deployment, server replacement, or active-run restart. Any live
effectiveness validation requires an authorized fresh supervised run recording
exact loaded source/runtime identity and all interventions; it remains excluded
from benchmark evidence. Publishing corrected source does not establish that
an existing role or MCP process has loaded it.

### Burner fuel delivery versus plate cargo (2026-10-03)

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

#### Native negative controls

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

#### Offline verification and review

Both affected Lua suites passed with the repository-supported `texlua` runner.
The full `scripts/agent-app verify --profile full` profile passed all ten checks,
covering application contract tests, dependency consistency, TypeScript,
companion tests, all Lua tests, offline writable and read-only MCP smoke tests,
build, built MCP smoke and mod package layout. These checks remain offline.
A local Semgrep 1.135.0 scan with `p/default` reported all three changed Lua
files scanned, with no findings, errors or skipped rules.

A fresh independent read-only review checked the complete candidate and native
receipts, independently reran both Lua suites, and reported no code finding.
It found an incorrect topology signature in this appendix; the identifier was
corrected to the final receipts' `6cd5ddcf14d50687`. Review did not perform live
gameplay or publication, and no active-run installation was requested.

### Accepted-work monitoring failures and cancellation provenance

A failed status read, transport fault, malformed reply, or other monitoring
failure after acceptance ends the bridge wait with `OUTCOME_UNKNOWN`. The
result retains `plan_id` or `task_id`, reports `physical_state: "unknown"`, and
includes `last_known` when a valid sample preceded the failure. That sample
can include committed construction; it is not proof of the current state.
The bridge sends no cancel, replacement enqueue, or automatic mutation retry.
Read the physical state before choosing a next action.

An owning request abort intentionally cancels only its accepted plan or task;
its origin is `<tool>/<role>/abort`. Direct-task deadlines intentionally
cancel with `<tool>/<role>/direct-task-timeout`, including the return guard
under a human hold. A `run_plan` monitoring deadline returns its latest
nonterminal state without cancellation. Existing mod origin validation,
activity and server logs, and terminal cancellation attribution remain the
source of provenance; supervisor stop, pilot ownership restrictions, human
holds, writer fencing and committed construction remain in force.

In the release 0.20.0 incident on 2026-10-04, the belt-build plan was cancelled
at tick 565200, in the 21:01:14–21:01:18 UTC window, after seven committed
steps and before validation produced an outcome. Its exact cancel RPC origin
remains unproven. The bridge's former catch-all cancellation handlers are a
plausible mechanism demonstrated by source and offline regressions, not
historical attribution. This correction requires offline readiness; it does
not establish live deployment or live gameplay validation.


### Research queue replacement: isolated Factorio 2.0.77 proof

On 2026-10-25, the new research-replacement scenario in
`companion/test/live-scenarios.ts` passed on a throwaway Factorio **2.0.77**
headless server with candidate mod **0.38.1**, protocol **29**. The selected
scenario used the existing suite's server, RCON, setup, profiling and cleanup
code; the unrelated live scenarios were not run. It had separate save, mods,
configuration and write-data directories, and dynamically allocated loopback
ports. No active gameplay run was contacted or changed.

The official [LuaForce 2.0.77 API](https://lua-api.factorio.com/2.0.77/classes/LuaForce.html#research_queue)
documents whole-table queue assignment, explicit empty-queue cancellation and
silent dropping of ineligible entries. Complete replacement validation therefore
precedes the native setter. Production code never assigns `research_progress`,
`saved_progress` or `researched`. A preliminary isolated engine probe confirmed
native preservation through assignment, suspension, reordering and clearing;
the candidate scenario then checked progress earned by real lab consumption.

The fixture initially supplied both science types to earn partial Automation 2
progress, then stopped its lab and removed all remaining logistic science.
Appending Lamp left Automation 2 active. Explicit replacement selected Lamp,
which consumes automation science only. The lab then earned partial Lamp
progress before further queue edits.

| Native observation | Result |
| --- | --- |
| Automation 2 pack-earned progress | `0.020555555555555258` |
| Lamp pack-earned progress | `0.021777777777777802` |
| Reorder and identical-queue replacement | Both progress values retained |
| Remove, clear, and reselect | Suspended progress retained and resumed |
| Unknown, duplicate, and completed selections | Refused with previous queue/progress unchanged |
| Retry original replacement after Lamp completed natively | Duplicate receipt; Automation 2 remains the sole active entry |

The final run reported 15 RPCs, maximum **0.15 ms**, no handler errors
or script errors, and 19 profiling windows with worst average **0.092 ms/tick**.
The owned server exited successfully and its throwaway data directory was
removed. This is isolated engine validation, not installed gameplay validation
or a deployment receipt.

Offline checks passed with Node **22.23.2**: `npm ci`, `npm ls --all`,
`npm run typecheck`, `npm run build`, `npm test` (513 companion tests, the full
Lua suite and package verification), writable/read-only/built MCP smoke,
`npm run package:mod`, the 16 Python agent-app contract tests, and
`git diff --check`. The `scripts/agent-app verify --profile full` wrapper could
not start because its fixed prerequisite lookup did not recognize the worker's
workspace-local npm installation; its constituent checks were executed directly
with that Node 22 toolchain. This is not a passed full-profile wrapper receipt.

Semgrep **1.182.1**, `p/default`, scanned the explicitly named changed source
and test files with no findings or errors. An initial baseline invocation
selected zero files; explicit selection resolved that limit. Its initial
parallel engine failed to allocate io_uring resources; the successful scan used
one worker and the POSIX backend.

Independent read-only review covered correctness, authorization, wiring, tests,
and scope/simplicity. Two findings were fixed and skeptically re-reviewed:
missing successful replacement data now remains an unknown outcome, and
replacement origins include the run-id digest to prevent receipt collisions
when an upgrade starts a new ledger over a retained save. The final instruction
contract retains its byte limits and describes explicit replacement without
research choices or sequences. No remaining review finding was retained.

Dependency versions were unchanged. The audit reported existing production
advisories in five packages (two high, three moderate); these were captured
in a separate production-dependency follow-up, while development-only advisories
have their own follow-up. The audit is not claimed clean. Source publication and any
subsequent existing-save deployment remain separate from this isolated proof.

### Unfinished debug recorder continuation — offline evidence

The recorder/thought regressions passed 80 cases on Node 22. They include a
real child recorder killed with SIGKILL after its first checkpoint, using
mocked RCON and fake time, followed by continuation across missing checkpoints
and normal SIGTERM finalization. Filesystem evidence and kernel lock ownership
are real. The tests check original baseline/elapsed/delta continuity, preserved
valid prefixes and truncated-tail bytes, missing-slot receipts, recovered
thought deduplication without replay, acknowledgement preservation, partial
role timing coverage, invalid/terminal/benchmark rejection, and live
version/window/rollback rejection before append or game effects.

Independent read-only review covered correctness, security/data integrity,
compatibility/wiring, tests, and scope/simplicity. Review found that the new
boundary snapshot initially bypassed assistance attestation, and that an
observation persisted immediately before recorder loss could also lack its
assistance mark. Continuation now passes all successful archived observations
and the fresh boundary through the existing attestor. Regressions isolate
baseline-, checkpoint-, and boundary-only deviations with a clean final
observation. Review also separated the rollback test's tick and body-window
triggers so either missing guard fails its own case. Focused re-review found
no remaining issues in those fixes.

Full offline verification uses an isolated candidate clone with matching
dependencies because the canonical checkout's dependency descriptors belong
to an earlier revision. The repository-owned full profile supplies the same
ten checks; its results and exact candidate are recorded in the completion
receipt. This source work does not establish the cause of the earlier recorder
disappearance, install a companion, change a live factory, or provide live-game
validation. Those effects and their observed receipts remain separate.
