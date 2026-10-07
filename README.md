# Factorio Codex

Current release: **0.29.1**.

Factorio Codex shows how Codex bots think about and architect a Factorio
factory. Two reasoning sessions plan and direct one physical character named
Codex through text-only tools; the mod does every deterministic chore, and the
strategist's thinking appears on a panel on the Codex screen.
The only active path is the project MCP server → serialized RCON bridge →
Factorio mod. Movement, reach, inventory, crafting, placement, research and
elapsed game time remain real.

Requirements: Factorio 2.0.x with the Space Age expansion, Node.js 22.12+,
and a dedicated save. The fixed `/silent-command remote.call` bridge means
Factorio disables achievements for that save. The interface never exposes Lua,
arbitrary console commands, images, uncharted terrain, teleportation of the
Codex body or free resources. Connected spectator cameras follow Codex without
affecting its movement. Every supported save is permanently peaceful: planets
generate no Nauvis enemy bases, Vulcanus generates no demolishers, Gleba's
own bases stay (its eggs feed agricultural science), and space platforms get
no world-policy write. The body launches rockets from a silo, space platforms
are built remotely from ghosts their hub fulfils, as the game's remote view
allows, and the body itself travels to other planets as a player does: by
rocket up to a platform, aboard while it flies its route, and down by pod.
Everything on a planet keeps physical reach. The game is won when a platform
reaches the solar system edge (the `promethium-science-pack` technology,
whose spawner-capture prerequisite this peaceful save cannot meet yet, is
The owner's later decision).

The owner can explicitly run a [fresh twenty-minute benchmark campaign](docs/BENCHMARK-CAMPAIGN.md)
with one to four reasoning sessions, varied GPT-6 profiles and a fixed native
cutoff. The normal two-brain setup remains the default.

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

Each run directory owns its fresh peaceful Space Age save, logs, PID, a
run-local mod directory (base, elevated-rails, quality, space-age, and the
companion), the ledger `operations.json`, the package queue record
`package-queue.json`, and the role notebook. `server start` verifies the mod
protocol and version before returning; `server stop` saves over RCON before
shutting down.

The server-and-agent workstation has no dedicated GPU and is permanently
headless. Run only the dedicated server, Node bridge, and agent tooling there;
never start a Factorio GUI/client or any other visual GUI workload on it during
rollout, validation, or benchmarks. All visual workloads run on the couch PC.
There, install the full standalone Factorio Space Age build under
`%LOCALAPPDATA%\factorio-codex\standalone-space-age` and run the couch-only
`scripts/launch-native-client.ps1 -Address <server:port>` to connect its
isolated maximum-quality 4K client as the real player named `Codex`. Then
connect the separate normal couch Factorio client as the characterless
spectator. The native launcher rejects the Steam build because Steam replaces
the isolated LAN identity with the account identity. There is intentionally no
Linux visual client launcher in this repository. The mod never creates a
standalone fallback character. Run `node companion/dist/cli.js doctor`, then
start `codex` at this root; the committed project config starts MCP
automatically.

The CLI supports `setup`, `doctor [--json]`, `mcp [--surface full|read-only]`,
`ledger-apply`, `server`, and `runs` (record, mark-assisted, compare).

## Roles

Live play uses exactly two persistent reasoning sessions around one physical
body and one FIFO plan queue.

- **The strategist** (`gpt-6.1-sol`, `medium` reasoning, normal speed) is the strategist
  and architect. It owns coordinate-free NOW/NEXT/LATER priorities and designs
  build packages of its own layouts or this run's blueprints, dry-run with
  `check_only`. It uses only the read-only MCP surface and is the sole writer of
  `operations.json`, through `ledger-apply`.
- **The pilot** (`gpt-6-luna`, `low` reasoning, fast mode) is the foreman and the
  sole gameplay writer. It waits on `next_event` and handles failed packages,
  an empty queue, and anything needing local judgment with goal-level actions.
  It sends no reports.

The strategist's packages queue themselves: the pilot's full-surface bridge watches the
ledger and queues each new package into the FIFO in ledger order, honouring
`after_package_id`, as a plan with source `package:<id>` after the mod's own
placement check, and only while the body is on the package's `surface`
(otherwise it shows `waiting_surface`; a package never holds `travel`).
Outcomes are recorded in `package-queue.json`; a rejected or
failed package surfaces as `package_failed` in `next_event` and in
`activity_log`. The strategist selects research the same way: the ledger's
`research` list (technologies in queue order) is queued by that bridge once
per revision, skipping what is already researched or queued, and recorded in
`activity_log`. Every tool result carries `orders` (revision, NOW, package
statuses) once each time the ledger revision changes. The ledger is the strategist's
only channel to the pilot.

Each run has a markdown notebook at `<run_dir>/notebook/` with one folder per
role (`notebook/strategist/`, `notebook/pilot/`). Each role writes its own folder and
reads either at any time, including exact positions and maps observed in that
run, and keeps a short `INDEX.md`; nothing is imported or carried to another
run. A package may name up to three notes.

Neither role calls `list_threads`, `read_thread`, or `wait_threads`, and after a
context compaction each re-reads its goal file and `SKILL.md` first. Gameplay
rules live in the repo-local `factorio-player` skill: `SKILL.md`, a short
Factorio intro with mechanics, rates and generic principles (`PLAYER-KNOWLEDGE-v1.md`), a reference for
rates and layout geometry (`FACTORIO-REFERENCE.md`), and one goal file per role.

**the owner takeover.** Real control input on the native `Codex` client (movement,
mining, building, opening a GUI, holding an item) parks the FIFO; nothing is
cancelled and `queue_plan` still queues. Every `fifo` block,
`factory_status.body` and `observe_local.character` report `human_control`.
The mod resumes about 5 s after the last input. Hovering, map view and camera
movement never park it. `next_event` reports `human_hold_started` and
`human_hold_ended`.

**Thought feed.** Spawn both roles with `-c model_reasoning_summary=detailed`.
The run recorder tails both role rollout files (`--pilot-rollout`,
`--strategist-rollout`) and forwards each reasoning summary and assistant
message, never tool calls or outputs, to `thoughts.jsonl`, and the ledger
writer's (the strategist; the pilot in a solo trial) through the mod's `say` RPC
at most one line per second, split into lines of at most 600 characters. The mod
shows them in the role's colour, never in game chat, and keeps the
last 8 lines in an always-visible left-side panel under the strategist's NOW line,
which the recorder sends through `say_now` whenever the ledger's NOW objective
changes. The text is also saved to the recorder's
`~/.local/share/factorio-codex/runs/run-<id>/thoughts.jsonl`, each line with
`said_at` (when the game showed it). The feed is
output only: game chat never controls the bot, and the panel never triggers a
takeover hold.

**Stop.** `stop` takes `{}` and cancels the active plan, queued plans and
character crafting; committed physical effects remain. Upkeep then stays off
until a plan finishes, unless the call passes `keep_upkeep: true` (the
retained-work reconciliation does). Neither role calls it.
Under `AGENTS.md` the supervisor alone uses it for an explicit the owner stop,
retained-work reconciliation, or recorded emergency quiescence during
replacement.

## What the mod does by itself

- **Line tracking.** The mod groups machines into production lines (same
  product, near each other) on build, removal and recipe events, and samples
  each machine every 30 ticks through stored references. Each line has a
  `state` (`running`, `starved` with the missing item or fluid as `cause`,
  `output_full` (`outlet_no_fuel` when a dry burner inserter takes from it),
  `depleted` with the ore a drill ran out of, `no_fuel`, `no_power`,
  `no_heat`, `disabled`, `idle` with `no_recipe` or `recipe_not_researched`),
  the position that causes a problem, on a running line `degraded` (its
  worst member problem and where), `rate_per_min`, `hand_fed` (a character
  transfer in the last minute), `self_sustaining` (a minute of running with
  no character transfer, no stall and no member out of fuel or power) and, from the second hand transfer into or out of
  its machines within ten minutes, `hand_transfers`: such a line is served by
  hand, not automated, and costs body time. There are no proofs or validation windows.
- **Auto-supply.** `get_items`, `place_entity`, `insert_items`, `build_plan`,
  `build_layout` and `blueprint_place` fetch what they lack: from the nearest own
  chest or machine output, then loose items at an own drill's drop position
  (belts only when nothing else holds it), else by smelting ore in an own
  furnace or hand-crafting with intermediates up to four levels deep (queued
  crafts count, so nothing is crafted twice), else by hand-gathering a raw
  resource from a tile no own building covers, also ore own drills mine when
  none of their output can be taken now. A shortfall is reported
  as `SUPPLY_SHORTFALL` with each missing item and why; what exists is
  carried, and own lines that make a missing item add their `rate_per_min`
  and `expected_minutes` for the rest. `build_layout` fetches its whole bill
  in one supply before the first placement (what the inventory has no room
  for at its step), and fails `LAYOUT_CHECK_FAILED` with nothing placed when an item cannot be had.
- **Auto-clear.** Placement mines trees and rocks in the footprint first.
- **Power model.** Each `factory_status` power row splits production by
  source (steam, solar, burner, nuclear), adds accumulator charge,
  `sustained_w` (solar at the planet's day-average light) and `headroom_w`,
  and, when demand exceeds `sustained_w`, `add_to_cover` with both ways to
  cover it, `steam` (engines, boilers, pumps) and `solar` (panels,
  accumulators); the bot chooses. Counts come from the
  entity registry, never a read-time scan.
- **Settings at build time.** Inserter filters and stack size, splitter
  priorities and filter, and chest slot limits or storage filters given as
  `settings` on `build_layout`, `build_plan` and `blueprint_create` entities
  are applied as each entity is built (blueprint ghosts carry them);
  `move_entity` and `copy_settings` carry them, and `configure_entity`
  changes them later.
- **Recoveries.** Stepping off a belt, leaving a placement footprint, mining an
  owned blocker that encloses the body, one re-approach after an out-of-reach
  result, and one retry of a partial insert happen inside the action.
- **Upkeep.** While no queued plan would take the body, no hold is active, and some plan has
  finished since the last emergency stop (a stop is never undone by upkeep;
  one with `keep_upkeep` leaves it on),
  the body, within 96 tiles of it (after two minutes with the FIFO empty, also of the last four
  sites where pilot or package plans began), refuels dry or low burner machines (with any fuel of the machine's fuel
  category, such as nutrients for a biochamber) and brings the current
  research's science packs to labs that accept them and have room, from own
  stock, as a plan with source `upkeep`; any queued plan takes the body at the
  next step boundary. A lab and pack that took nothing are not tried again
  for 600 ticks; with no research active no lab is fed, and `factory_status`
  shows a `research_idle` problem. Upkeep works only on the body's planet
  surface, never aboard or in transit. Just before a queued plan starts, a
  machine within 96 tiles of the body dry for a minute gets one upkeep plan
  first (at most once in two minutes), which moves no item that plan names, so
  back-to-back plans never starve it.
- **Several surfaces.** Lines, stock, flows and problems are kept per surface.
  `factory_status` details the body's surface (or the one named in `surface`)
  and summarises every other one with buildings in `elsewhere`, so the Nauvis
  factory stays in view from orbit or another planet. Physical plan steps
  carry their surface; when the body leaves it, unfinished plans for it end
  with `SURFACE_LEFT`. Machines that freeze on Aquilo show `frozen`.
- **Background crafting.** Hand-crafting runs while the body keeps working; a
  later step that needs the item waits for it.
- **Charting.** Every minute on a planet, and once on arrival, the force
  charts the chunks around the body, so patches and water appear without
  scouting walks; `explore` walks toward uncharted land, charting as it goes,
  until a wanted patch is in view.
- **Blueprints.** The mod keeps this run's blueprints as real blueprint items:
  capture a build that works once, then stamp it again by hand or as ghosts.
  Nothing is imported; an export is a string for the notebook.

## MCP tools

The full surface has 51 tools; the read-only surface used by the strategist has 21.
Every read-only result carries `fifo` (`active_plan_id`, `queue_depth`,
`idle_seconds`, `human_control`). Heavy reads (`map_summary`, a full
`observe_local`, route and site searches, dry runs, blueprint capture and
description) run in the game as jobs spread over ticks; the bridge polls
`get_job` and returns the same result shape.

| Tool | Surface | Purpose |
| --- | --- | --- |
| `connect_status` | both | config, RCON, mod and protocol check; binds the `Codex` player |
| `factory_status` | both | the single routine read: lines, problems, power by source with `add_to_cover` (steam and solar), stock, research, body (state, surface, health), patches with their `bbox` outline, one line per space platform, `elsewhere` (one line per other surface with buildings), `unlocked_locations`; `surface`, `since_tick`, `sections` (only the parts named; `logistics`, the robot networks, only when named) |
| `next_event` | both | waits up to 120 s for `plan_ended` (with the plan's outcomes and inventory change), `research_finished`, `queue_empty`, `new_problem`, `package_failed`, `orders_changed`, `human_hold_started`/`ended`, `rocket_ready`, `rocket_launched`, `cargo_delivered`, `platform_state_changed`, `platform_arrived`, `travel_phase`, `body_surface_changed`, or `timeout` |
| `activity_log` | both | recent plan outcomes with `source` (`pilot`, `upkeep`, `package:<id>`), cancels with their `origin`, blueprint changes, and package statuses |
| `build_layout` | both (read-only: dry run) | build a layout of offsets from an `anchor` or a found `site`, with recipes, starting items, settings and belt/pipe/power connections; `mode: ghosts` for robots; `platform` marks ghosts and foundation tiles on a space platform for its hub to build; a dry run also reports, as data, inserters, belt ends, unpowered machines, isolated poles, `on_ore` (non-drill buildings over ore), `mixed_ore` (drills whose area holds another resource) and `open_fluid_ports` (fluid connections that meet nothing) |
| `connect_entities` | both (read-only: dry run) | belt, pipe or power route of up to 200 pieces between entities or free tiles, underground past obstacles |
| `blueprint_list`, `blueprint_describe`, `blueprint_export` | both | this run's stored blueprints; export is a string for notes, never imported |
| `blueprint_place` | both (read-only: dry run) | build a stored blueprint by hand or as ghosts, or as ghosts on a space platform; its dry run also reports `on_ore`, `mixed_ore` and `open_fluid_ports` |
| `place_tiles` | both (read-only: dry run) | lay landfill, stone path, concrete, foundation or ice platform over an area or up to 1,024 positions, nearest first; a dry run counts the items |
| `platform_status` | both | space platforms: state, location, trip, speed, schedule, hub slots and requests; `detail: full` for one platform adds foundation, hub contents, entities, thrusters and `ghosts.missing` |
| `map_summary` | both | full flow graph of the charted factory on one surface (`surface`; `"all"` sums flows); `include` adds `stockpiles`, `sites`, `patches`, `power`, `problems`, `flows_all` |
| `observe_local`, `inspect_entity` | both | nearby entities and exact entity state with settings, temperature and `frozen`, up to 64 positions (own entities anywhere charted; `surface` on `inspect_entity`) |
| `can_place`, `find_placement` | both | placement checks anywhere charted, on any surface (`surface`), with surface conditions; `find_placement` lists candidates nearest first (a drill's with its `resource_coverage`), and its `fluid` picks the liquid an offshore pump pumps |
| `production_requirements`, `progression_status`, `describe_prototype` | both | recipe arithmetic with each raw material's `roots` (planet and how it is gathered), `unobtainable` and, with `planet`, `surface_limited` recipes; research; prototypes |
| `plan_status` | both | one exact plan, optionally waiting up to 60 s |
| `get_items` | full | fetch, craft or gather `count` of an item |
| `queue_plan`, `run_plan` | full | 1-200 plan steps; `queue_plan` returns at once |
| `walk_to`, `mine`, `pickup_items`, `place_entity`, `craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`, `build_plan`, `start_research` | full | single physical actions |
| `move_entity`, `explore`, `build_ghosts`, `deconstruct_area`, `upgrade_area`, `copy_settings` | full | one-step plans: move a building with its contents, scout and chart, build ghosts by hand, clear or upgrade an area, copy settings |
| `configure_entity` | full | inserter filters, mode and stack size, splitter priorities and filter, chest slot limit or storage filter, asteroid collector filters, silo `auto_requests`; walks there (with `platform`: at once, no body), changes only what is named, reads back |
| `set_requests` | full | requests of a requester or buffer chest or a landing pad (`merge`, `set`, `remove`), or of a platform hub (`target: {platform}`, at once, with `import_from`), or the body's own personal requests and `trash` (`target: "character"`, at once, after logistic robotics); only robots and platforms deliver, `network: null` when no roboport covers a chest |
| `create_platform` | full | register a space platform over the body's planet, at once; it waits for its starter pack |
| `launch_rocket` | full | load a ready rocket with cargo (items, or `"requests"`: what the hub still lacks) and launch it to a platform; a waiting one needs its starter pack in cargo |
| `set_platform_route` | full | set a platform's stops (unlocked locations, each with the game's wait conditions), `go_to` a stop or `paused`, at once and without the body; reads the schedule back |
| `travel` | full | queue the body's trip to another surface and return: up by the next ready rocket to a platform in orbit (`via_silo`), or from aboard down to the planet the platform reaches (`max_wait_minutes`, default 60); pilot only, never in a package |
| `blueprint_capture`, `blueprint_create`, `blueprint_delete` | full | store a blueprint from own buildings or a layout; delete one |
| `stop` | full | supervisor-only emergency cancellation |

Plan steps are `walk_to`, `mine`, `pickup_items`, `place_entity`,
`craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`,
`inspect_entities`, `wait_for_item`, `wait_for_research`, `get_items`,
`build_layout`, `explore`, `move_entity`, `blueprint_place`,
`build_ghosts`, `deconstruct_area`, `upgrade_area`, `copy_settings`,
`configure_entity`, `place_tiles`, `set_requests`, `create_platform`,
`launch_rocket`, `set_platform_route`, `travel`, `equip` and `flush_fluid`;
`equip` (wear armor, fit or remove equipment from the inventory) and
`flush_fluid` (empty a pipe, pump or tank system; the fluid is destroyed) are
plan steps only. `extract_items` and `insert_items` take an optional
`inventory` (`output`, `input`, `fuel`, `burnt_result`, `modules`, `trash`,
`main`, `robots`, `material`, `rocket`); without it they behave as before. Steps
with `platform` (`set_recipe`, `configure_entity`, `build_layout`,
`blueprint_place`, `deconstruct_area`, and `set_requests` on a hub) and
`create_platform` and `set_platform_route` act on a space platform without
the body, when the FIFO reaches them, without walking; the direct `set_recipe`, `configure_entity` and
`set_requests` tools with a platform, and `create_platform`, answer at once
over one RPC. A build
package may also start with `blueprint_capture` steps, which the bridge makes
before it queues the rest (after its `after_package_id` plan has ended).
`queue_plan` and `run_plan` take `surface`: positions are on the body's
surface, after a `travel` step on its destination, or on the surface named; a
step that starts on another surface fails `SURFACE_MISMATCH`.
`craft_items` does not hold the body unless `wait_for_completion` is true; a
later step that needs the item waits for it. Plans are sequential and nontransactional:
completed steps stay committed. `after_plan_id` runs a plan only after that
plan completes; a chained successor is cancelled when its predecessor fails.
`mine` accepts an optional `expected_name` and `observed_tick`. A plan step
saved by release 0.20 as `validate_factory_component` completes as a no-op with
code `REMOVED_ACTION`.

`pickup_items` takes one ground stack through native picking, or `count` items
from a plain transport belt tile as an exact conserved transfer (the body
within `item_pickup_distance` of the belt's centre and room for the whole
count, or an honest refusal, never a partial spill). A hand-mining result adds
`drill_produced: true` when own drills already mine that resource.
Every cancel names its `origin` (the tool, and the role its MCP process was
started with: `factorio-codex mcp --role pilot|strategist|supervisor`) in
`activity_log` and the server log. Packages written before an emergency stop stay held until
The strategist rewrites the ledger; nothing else holds them but a human hold.

## Run recorder

Start the foreground recorder immediately before gameplay begins. It takes a
native baseline before printing `GO`, records resources and factory context
every five minutes of wall time, and runs the thought feed. Stop it with
Ctrl-C at the run boundary; that captures one final sample and closes the
manifest.

```sh
factorio-codex runs record --ledger <run-dir>/operations.json \
  --variant guidance-v3 --change "the mod does the chores" --kind debug \
  --pilot-rollout <pilot rollout.jsonl> --strategist-rollout <strategist rollout.jsonl>
factorio-codex runs mark-assisted <run-id> --reason "supervisor teleport recovery"
factorio-codex runs compare <baseline-run-id> <candidate-run-id>
```

Records live under `~/.local/share/factorio-codex/runs/`. Samples count lines,
running, self-sustaining and hand-fed lines from the mod. Debug and assisted
runs remain available for descriptive comparison but are excluded from an
automatic benchmark verdict. Debug runs continue past `GO+20m` to their
assigned milestone unless the owner stops them; Candidate B and R1-R7 remain
historical evidence in [agent play performance](docs/AGENT-PLAY-PERFORMANCE.md).

## Timelapse

For the owner's video, the supervisor can start a 4K timelapse over the `timelapse`
RPC (`{"action":"start","folder":"<run id>"}`; `status`, `stop`). It is output
only: no MCP tool reads or starts it, and no image reaches the bots. Every five
game seconds the Codex client renders a 3840x2160 JPG (`take_screenshot` with
`by_player`; the headless server renders nothing) into
`script-output\timelapse\<folder>\frame_NNNNNN_t<tick>.jpg`. The camera frames the largest cluster
of production machines on Nauvis, ignores outposts and long lines, and only
zooms out (from 1 to 0.25) as that cluster grows; the first rocket launch on
Nauvis is caught every four ticks close on the silo, then a short pull-back
ends the capture. On the couch PC, `scripts/timelapse-video.ps1 -Run <folder>`
joins the frames into an HEVC video (`-Every 2` doubles the speed, `-SkipIdle`
drops unchanged frames). Each frame shows the time since the first frame as
HH:MM:SS, from its tick, at a fixed top-left spot in a monospace font
(`-NoClock` leaves it out).

## Verification

```sh
npm ci && npm ls --all
npm run typecheck && npm run build && npm test
npm run test:mcp && npm run test:mcp:built -w companion
npm run package:mod
```

See [live validation](docs/LIVE-VALIDATION.md) for the Factorio-only acceptance
run and [UPSTREAM.md](UPSTREAM.md) for provenance.
