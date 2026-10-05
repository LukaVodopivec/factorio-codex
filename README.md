# Factorio Codex

Current release: **0.22.0**.

Factorio Codex shows how Codex bots think about and architect a Factorio
factory. Two reasoning sessions plan and direct one physical character named
Codex through text-only tools; the mod does every deterministic chore, and the
bots' thinking appears in the game chat and on a panel on the Codex screen.
The only active path is the project MCP server → serialized RCON bridge →
Factorio mod. Movement, reach, inventory, crafting, placement, research and
elapsed game time remain real.

Requirements: Factorio 2.0.x with the Space Age expansion, Node.js 22.12+,
and a dedicated save. The fixed `/silent-command remote.call` bridge means
Factorio disables achievements for that save. The interface never exposes Lua,
arbitrary console commands, images, uncharted terrain, teleportation of the
Codex body or free resources. Connected spectator cameras follow Codex without
affecting its movement. Every supported save is permanently peaceful with
enemy bases disabled. Play is Nauvis-first: there are no rocket,
space-platform, or planet-travel tools yet.

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

- **Astra** (`gpt-6-astra`, `medium` reasoning, normal speed) is the strategist
  and architect. It owns coordinate-free NOW/NEXT/LATER priorities and designs
  build packages of whole blocks or this run's blueprints, dry-run with
  `check_only`. It uses only the read-only MCP surface and is the sole writer of
  `operations.json`, through `ledger-apply`.
- **Luna** (`gpt-6-luna`, `low` reasoning, fast mode) is the foreman and the
  sole gameplay writer. It waits on `next_event` and handles failed packages,
  an empty queue, and anything needing local judgment with goal-level actions.
  It sends no reports.

Astra's packages queue themselves: the pilot's full-surface bridge watches the
ledger and queues each new package into the FIFO in ledger order, honouring
`after_package_id`, as a plan with source `package:<id>` after the mod's own
placement check. Outcomes are recorded in `package-queue.json`; a rejected or
failed package surfaces as `package_failed` in `next_event` and in
`activity_log`. Every tool result carries `orders` (revision, NOW, package
statuses) once each time the ledger revision changes. The ledger is Astra's
only channel to the pilot.

Each run has a markdown notebook at `<run_dir>/notebook/` with one folder per
role (`notebook/astra/`, `notebook/luna/`). Each role writes its own folder and
reads either at any time, including exact positions and maps observed in that
run, and keeps a short `INDEX.md`; nothing is imported or carried to another
run. A package may name up to three notes.

Neither role calls `list_threads`, `read_thread`, or `wait_threads`, and after a
context compaction each re-reads its goal file and `SKILL.md` first. Gameplay
rules live in the repo-local `factorio-player` skill: `SKILL.md`, a short
Factorio intro with overridable hints (`PLAYER-KNOWLEDGE-v1.md`), and one goal
file per role.

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
message, never tool calls or outputs, through the mod's `say` RPC at most one
line per second per role, split into lines of at most 600 characters. The mod
prints them to chat as `[Astra]` and `[Luna]` in role colours and keeps the
last 8 lines in an always-visible left-side panel under Astra's NOW line,
which the recorder sends through `say_now` whenever the ledger's NOW objective
changes. The text is also saved to the recorder's
`~/.local/share/factorio-codex/runs/run-<id>/thoughts.jsonl`, each line with
`said_at` (when the game showed it). The feed is
output only: game chat never controls the bot, and the panel never triggers a
takeover hold.

**Stop.** `stop` takes `{}` and cancels the active plan, queued plans and
character crafting; committed physical effects remain. Neither role calls it.
Under `AGENTS.md` the supervisor alone uses it for an explicit the owner stop,
retained-work reconciliation, or recorded emergency quiescence during
replacement.

## What the mod does by itself

- **Line tracking.** The mod groups machines into production lines (same
  product, near each other) on build, removal and recipe events, and samples
  each machine every 30 ticks through stored references. Each line has a
  `state` (`running`, `starved` with the missing item or fluid as `cause`,
  `output_full`, `no_fuel`, `no_power`, `no_heat`, `disabled`, `idle` with
  `no_recipe` or `recipe_not_researched`), the position that causes a
  problem, `rate_per_min`, `hand_fed` (a character transfer in the last
  minute), `self_sustaining` (a minute of running with no character
  transfer and no stall) and, from the second hand transfer into or out of
  its machines within ten minutes, `hand_transfers`: such a line needs a
  connection, not another trip. There are no proofs or validation windows.
- **Auto-supply.** `get_items`, `place_entity`, `insert_items`, `build_plan`,
  `build_layout` and `build_block` fetch what they lack: from the nearest own
  chest or machine output (belts only when nothing else holds it), else by
  smelting ore in an own furnace or hand-crafting with intermediates up to
  four levels deep (queued crafts count, so nothing is crafted twice), else by
  hand-gathering a raw resource no own drill produces. A shortfall is reported
  as `SUPPLY_SHORTFALL` with each missing item and why; what exists is
  carried, and own lines that make a missing item add their `rate_per_min`
  and `expected_minutes` for the rest.
- **Auto-clear.** Placement mines trees and rocks in the footprint first.
- **Power model.** Each `factory_status` power row splits production by
  source (steam, solar, burner, nuclear), adds accumulator charge,
  `sustained_w` (solar at the planet's day-average light) and `headroom_w`,
  and, when demand exceeds `sustained_w`, `add_to_cover`: the steam engines,
  solar panels or accumulators that would cover it. Counts come from the
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
- **Upkeep.** While the FIFO is empty, no hold is active, and some plan has
  finished since the last emergency stop (a stop is never undone by upkeep),
  the body refuels dry burner machines and brings the current research's
  science packs to waiting labs from own stock as a plan with source `upkeep`;
  any queued plan
  takes the body at the next step boundary.
- **Background crafting.** Hand-crafting runs while the body keeps working; a
  later step that needs the item waits for it.
- **Charting.** Every minute the force charts the chunks around the body, so
  patches and water appear without scouting walks; `explore` walks toward
  uncharted land, charting as it goes, until a wanted patch is in view.
- **Blueprints.** The mod keeps this run's blueprints as real blueprint items:
  capture a build that works once, then stamp it again by hand or as ghosts.
  Nothing is imported; an export is a string for the notebook.

## MCP tools

The full surface has 47 tools; the read-only surface used by Astra has 21.
Every read-only result carries `fifo` (`active_plan_id`, `queue_depth`,
`idle_seconds`, `human_control`). Heavy reads (`map_summary`, a full
`observe_local`, route and site searches, dry runs, blueprint capture and
description) run in the game as jobs spread over ticks; the bridge polls
`get_job` and returns the same result shape.

| Tool | Surface | Purpose |
| --- | --- | --- |
| `connect_status` | both | config, RCON, mod and protocol check; binds the `Codex` player |
| `factory_status` | both | the single routine read: lines, problems, power by source with `add_to_cover`, stock, research, body, patches; `since_tick`, `sections` (only the parts named; `logistics`, the robot networks, only when named) |
| `next_event` | both | waits up to 120 s for `plan_ended` (with the plan's outcomes and inventory change), `research_finished`, `queue_empty`, `new_problem`, `package_failed`, `orders_changed`, `human_hold_started`/`ended`, or `timeout` |
| `activity_log` | both | recent plan outcomes with `source` (`pilot`, `upkeep`, `package:<id>`), cancels with their `origin`, blueprint changes, and package statuses |
| `build_layout` | both (read-only: dry run) | build a layout of offsets from an `anchor` or a found `site`, with recipes, starting items, settings and belt/pipe/power connections |
| `build_block` | both (read-only: dry run) | `mining`, `smelting`, `assembly`, `power` or `labs` blocks, `count` copies, or a stored `blueprint` |
| `connect_entities` | both (read-only: dry run) | belt, pipe or power route of up to 200 pieces between entities or free tiles, underground past obstacles |
| `blueprint_list`, `blueprint_describe`, `blueprint_export` | both | this run's stored blueprints; export is a string for notes, never imported |
| `blueprint_place` | both (read-only: dry run) | build a stored blueprint by hand or as ghosts |
| `place_tiles` | both (read-only: dry run) | lay landfill, stone path, concrete, foundation or ice platform over an area or up to 1,024 positions, nearest first; a dry run counts the items |
| `map_summary` | both | full flow graph of the charted factory; `include` adds `stockpiles`, `sites`, `patches`, `power`, `problems`, `flows_all` |
| `observe_local`, `inspect_entity` | both | nearby entities and exact entity state with settings, up to 64 positions (own entities anywhere charted) |
| `can_place`, `find_placement` | both | placement checks anywhere charted |
| `production_requirements`, `progression_status`, `describe_prototype` | both | recipe arithmetic, research, prototypes |
| `plan_status` | both | one exact plan, optionally waiting up to 60 s |
| `get_items` | full | fetch, craft or gather `count` of an item |
| `queue_plan`, `run_plan` | full | 1-200 plan steps; `queue_plan` returns at once |
| `walk_to`, `mine`, `pickup_items`, `place_entity`, `craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`, `build_plan`, `start_research` | full | single physical actions |
| `move_entity`, `explore`, `build_ghosts`, `deconstruct_area`, `upgrade_area`, `copy_settings` | full | one-step plans: move a building with its contents, scout and chart, build ghosts by hand, clear or upgrade an area, copy settings |
| `configure_entity` | full | inserter filters, mode and stack size, splitter priorities and filter, chest slot limit or storage filter; walks there, changes only what is named, reads back |
| `set_requests` | full | requests of a requester or buffer chest (`merge`, `set`, `remove`); only robots deliver, `network: null` when no roboport covers it |
| `blueprint_capture`, `blueprint_create`, `blueprint_delete` | full | store a blueprint from own buildings or a layout; delete one |
| `stop` | full | supervisor-only emergency cancellation |

Plan steps are `walk_to`, `mine`, `pickup_items`, `place_entity`,
`craft_items`, `insert_items`, `extract_items`, `set_recipe`, `rotate_entity`,
`inspect_entities`, `wait_for_item`, `wait_for_research`, `get_items`,
`build_layout`, `build_block`, `explore`, `move_entity`, `blueprint_place`,
`build_ghosts`, `deconstruct_area`, `upgrade_area`, `copy_settings`,
`configure_entity`, `place_tiles`, `set_requests`, `equip` and `flush_fluid`;
`equip` (wear armor, fit or remove equipment from the inventory) and
`flush_fluid` (empty a pipe, pump or tank system; the fluid is destroyed) are
plan steps only. `extract_items` and `insert_items` take an optional
`inventory` (`output`, `input`, `fuel`, `burnt_result`, `modules`, `trash`,
`main`, `robots`, `material`); without it they behave as before. A build
package may also start with `blueprint_capture` steps, which the bridge makes
before it queues the rest (after its `after_package_id` plan has ended).
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
Astra rewrites the ledger; nothing else holds them but a human hold.

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

## Verification

```sh
npm ci && npm ls --all
npm run typecheck && npm run build && npm test
npm run test:mcp && npm run test:mcp:built -w companion
npm run package:mod
```

See [live validation](docs/LIVE-VALIDATION.md) for the Factorio-only acceptance
run and [UPSTREAM.md](UPSTREAM.md) for provenance.
