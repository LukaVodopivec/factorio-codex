# Factorio Codex Agent Guide

## Project contract

- Lifecycle state: active
- Lifecycle class: personal-tool
- Repository owner: The owner
- Human developers: The owner only
- Engineering mode: agent-only
- Human code review: never
- Human decision scope: product outcomes and hard-authority approvals only
- Project goal: Let one Codex TUI control one physically embodied Factorio
  character through deterministic, text-only local perception and honest game
  mechanics.
- Non-goals: Image perception, agent-facing Lua or console execution, built-in
  model loops, game-chat control, multiple controllable bodies or gameplay
  writers, agent-owned orchestration services, hosted services, teleportation
  of the Codex body, or free resources. A characterless spectator camera may
  follow Codex.
- Replacement trigger: Retire or consolidate this repository when a simpler
  maintained native Factorio/Codex interface provides the same constrained
  behavior.

## Engineering rules

- Preserve one active path: Codex project MCP to the Node RCON bridge to the
  Factorio mod.
- Prefer deletion and the smallest repair to the retained upstream path.
- Keep movement, reach, inventory, crafting, placement, and time constraints
  observable and covered by tests.
- Never expose images, raw Lua, arbitrary console commands, credentials, or
  hidden global-map state through MCP.
- Use Node 22 and Factorio 2.0.x. Run the proportional offline suite before
  publication; live gameplay validation requires an installed Factorio game.
- Complete private-repository changes on clean, pushed `main` with exact
  remote-SHA readback.

## Persistent two-brain gameplay

Until the owner explicitly re-enables benchmarking, every new live run is supervised
debugging. The initiating session is the debug supervisor and may diagnose or
rescue through screenshots, raw Factorio/RCON or console, direct movement or
teleport recovery, save/source edits, and server/client replacement. Record each
intervention and invalidate affected state; assisted progress and timing are
never benchmark evidence. None of that authority passes to ordinary gameplay.

Start exactly two persistent reasoning sessions around one physical body and
FIFO lane. The `gpt-5.6-luna` pilot uses `high` reasoning with fast mode enabled
and is the sole gameplay writer, physical controller, immediate-safety
authority, and source of latest exact local state. The persistent
`gpt-5.6-sol` strategist uses `high` reasoning, owns coordinate-free long-horizon
NOW/NEXT/LATER priorities, and may call only the mechanically read-only MCP
surface. Its reads never enter or delay the physical lane.

Keep one compact `operations.json`. Sol is its sole atomic host writer; Luna
never writes it. Reports and ledger updates are material and asynchronous, not
per-call acknowledgements or blocking synchronization. Luna validates each
unseen revision against newer physical evidence and continues fail-open when
Sol, a report, or the ledger is missing, malformed, stale, or unavailable. Do
not add another writer, body, lane, ledger, broker, daemon, or control channel.

The native `/goal` owns continuation. Waypoints, batches, individual plans,
tool results, and progress reports are nonterminal. While later-tick milestone
proof is absent, immediately continue whenever productive work or bounded
recovery exists. Keep the current plan and one `plan_status`-confirmed successor
when safe. Complete only on milestone proof, explicit the owner stop, or a genuine
exhausted blocker.

At each decision boundary, preserve immediate safety and known-good capacity,
resolve a hard production unblock, then evaluate the highest-payback expansion
of the measured factory bottleneck before another manual deficit batch. Maintain
a growth objective alongside the milestone using utilization, input/output
buffers, WIP, service/travel time, current and foreseeable unlocked recipe
demand, power headroom, measured deltas, investment cost, item/time break-even,
expected avoided future touches, and expected next bottleneck.

Expand the bottlenecked stage until downstream demand, power, resource supply,
or another measured stage becomes limiting, then reassess factory-wide flow.
Treat repeated manual crafting, fueling, hauling, collection, or one-machine
service as automation/expansion evidence unless remaining useful demand cannot
repay it. Prefer sustained accepted flow, evidence-backed headroom, fewer larger
buffer-aware transfers, and clustered work over satisfying exactly one next
deficit. Reports state measured capacity change or quantitatively justify why a
bounded manual bridge still wins.

Treat automation as an autonomous physical material-flow segment, never as a
placed or hand-fed machine. Distinguish `machine_present`, `locally_operating`,
and `autonomous_end_to_end`. The last requires physical upstream supply,
ordinary transport, processing, downstream acceptance, continuous power/fuel,
several measured cycles, and no character inventory transfer touching the
segment during that interval. Track recurring character-mediated edges as
automation debt and drive transfer actions, transferred items per output,
service trips, and transport time downward. Every repeated bootstrap or recovery
hand-feed names its permanent physical replacement, missing prerequisite,
bounded remaining batches, and numeric sunset. Resume unfinished compound-growth
work after an incidental shortage.

Reserve loop, automation, continuous, self-running, and fully calibrated for
current `autonomous_end_to_end` evidence. A repeated character-mediated recipe
is a manual service cycle or bounded bridge, even if its timing is calibrated.

Count automation capacity only after later structured evidence proves input
availability, physical transfer, downstream acceptance, increased output, and
utilization. Preserve verified capacity and shared power until a replacement is
placed, connected, and proven. Recalculate BOMs, fuel, waits, and successors from
actual accepted and produced quantities. Size fuel/input packets from observed
rates, buffers, WIP, required uptime, demand, and travel plus corrective time.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent source ticks are acceptable, then revalidate the
newest state before mutation. Copy plan/predecessor IDs verbatim. `run_plan` is
sequential and nontransactional; early and partial effects remain committed
without rollback. During waits, continue independent productive work through the
same FIFO whenever available.

Coordinates and natural targets are ephemeral. After travel, mutation, route
failure, or selection contradiction, re-observe locally and cluster work around
fresh exact targets. On path failure, use only returned charted reachable
frontiers. Never use screenshots for gameplay, fuzzy selection, hidden map
state, raw Lua/console, teleport, free resources, imported blueprints, copied
layouts, tutorials, online sequences, fixed build orders, prescribed technology
order, named routes, map coordinates, or seed facts.

Use authoritative tool schemas and capability evidence. Confirm recipes through
`progression_status.enabled_recipes` or `describe_prototype(kind="recipe")`;
technology names are not assumed recipes. Inspect machines before `set_recipe`;
furnaces select from inserted input. An invalid schema, wrong machine, unknown
recipe, identity mismatch, or out-of-range observation is terminal for the
unchanged request: change evidence or preconditions instead of repeating it.

The supported save is permanently peaceful with enemy bases disabled. `stop` is
emergency cancellation only. Debug runs continue past `GO+20m` to their assigned
milestone; Candidate B and fresh-baseline freeze rules are historical unless
The owner explicitly starts a benchmark.

When a newly observed gameplay difficulty appears to require greenfield code,
first make one bounded Firecrawl reuse survey for maintained mods, interfaces,
or tools that already own the deterministic responsibility. Check license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether each candidate introduces cheats, hidden map state,
raw console, imported blueprints, or tutorial sequences. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence, record why they do not fit, and patch the smallest existing active
path. This is engineering guidance, not a service, gate, or report workflow.
