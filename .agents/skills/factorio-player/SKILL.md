---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex.

For W1C, the parent starts three persistent conversations using the benchmark's
current model/effort assignment and pastes one adjacent prompt into each:

- [adaptive master brain](GOAL-MASTER-v1.md), read/plan-only;
- [sole pilot](GOAL-PILOT-v1.md), the only ordinary MCP action writer; and
- [automation specialist](GOAL-SPECIALIST-v1.md), read-only.

The parent identifies the shared milestone and communication route, confirms
that only the pilot invokes ordinary MCP action tools, and lets the master
issue the first operations-ledger revision. The prompts select actions from current
structured state; none hardcodes a route, map position, or build sequence.

## Shared-run contract

For each run, the parent creates a fresh run ID and exactly one ephemeral
ledger at `/run/user/<uid>/factorio-codex/runs/<run-id>/operations.json`, then
passes that exact path verbatim to every role. The parent creates the run
directory with mode `0700` and initializes the file with mode `0600`; after
initialization, the master is the sole host-ledger writer. The master rewrites
`operations.json` atomically through an adjacent temporary file and rename.
The pilot and specialist only read it and send observations or advice directly
to the master. Do not create another run file, append log, watcher, broker,
database, orchestrator, or coordination process.

The ledger contains a schema version, run/save identity, monotonic revision,
source tick, phase and success, latest pilot observation,
capacity and utilization, current plan, and exactly one actually queued
successor with predecessor and preconditions—or an explicit reason that no
successor is queued. Reject or replace stale state when revision, source tick,
or save identity regresses or disagrees with live structured state. The pilot
is the sole ordinary MCP writer and authority for the latest observation; the
master alone converts its report into the next atomic ledger revision.

The exact top-level keys are `schema_version`, `run`, `revision`, `source_tick`,
`phase`, `success`, `capacity`, `utilization`, `bottleneck`, `current_plan`,
`queued_successor`, `fallbacks`, `current_bom`, `next_bom`,
`latest_observation`, `decisions`, `specialist_advice`, `invalidations`, and
`outcome`. The `outcome` object also owns Candidate B timing and benchmark
state: GO UTC/monotonic/tick, deadline, collection UTC/monotonic/tick and
latency, immutable `SNAPSHOT_AT_20M` progress vector, the complete throughput
snapshot, later rocket/terminal evidence, and elapsed wall/game time. The
20-minute snapshot is not a binary success gate; only the legitimate rocket
goal determines run success.
Parent-owned immutable `run` metadata contains `id`, `release_sha`,
`baseline_save_sha256`, `save_identity`, `created_at`, and the three role
model/effort assignments. The parent writes revision `0` with both
`source_tick` and `latest_observation` set to `null`, then relinquishes the
file. Every master rewrite preserves `run` byte-for-byte, is exactly prior
revision plus one, uses a `0600` adjacent temporary file, atomically renames it,
and verifies the final file is still `0600`. After the first pilot observation,
`source_tick` never decreases and equals `latest_observation.source_tick`; a
reset, tick rollback, or save identity mismatch requires a fresh parent-created
run ID and ledger rather than an in-place reconciliation.

Coordinates are ephemeral run state only. Remove affected coordinates from the
ledger on a game reset, contradictory observation, referenced-entity mutation,
or route failure, and never copy them to durable player knowledge. Use
deterministic MCP state and tool results before the ledger or prose. Carry only
the grounded current plan and one queued successor; invalidate stale state and
keep safe productive work overlapping.

- Use the topology and model/effort assignment selected by completed benchmark
  results; do not assume a Sol/Luna winner. In a split topology, one strategist
  owns phase, success, and one actually queued successor, one persistent pilot is the
  sole ordinary MCP action writer, and an optional specialist is read-only.
  Discard stale advice unless the pilot revalidates it.
- Maintain the rolling operations ledger: phase and success, capacity and
  utilization, executing plan, one actually queued successor with predecessor
  and preconditions (or the reason none can be queued), prioritized fallbacks,
  current and next bill of materials, and source tick/plan ID.
- Prefer automation. After bootstrap, every manual mining or crafting batch
  requires the exact net deficit after carried stock, machine buffers/output,
  and work in progress; the exact machine unlock or fuel consumer and uptime
  bought; a payback comparison in named item/time units with break-even; and a
  numeric stop condition. Automate bulk
  extraction, smelting, intermediates, logistics, and science; overlap crafting,
  movement, production, and research; inspect and repair the dominant
  bottleneck. Keep the current plan plus one queued successor, and never wait
  while another safe productive action exists.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch reads and cluster travel. Direct positional actions auto-approach; never
  prepend a redundant `walk_to`, and use `walk_to` only for physical scouting or
  relocation that no following positional action already performs. Use `build_plan` for layouts,
  `queue_plan`/`plan_status` for a queued successor, recording its returned
  `plan_id` and `after_plan_id` only after `plan_status` confirms `queued`, and `run_plan` for
  synchronous compatibility. `inspect_entity` accepts `positions`.
- The pilot may mine, refuel, collect output, repair routes, or take an approved
  fallback without waiting. Priority is: unblock production; mine the BOM
  bottleneck in batches; build validated automation; physically scout.
  Never idle on a wait while productive work exists.
- Finish every packet with an authoritative observation by consuming the
  plan's terminal observation. Observe again only
  if it is missing or became stale after another action. Report source tick and
  plan ID, position, inventory, active plan/step, queue depth, crafting, result,
  and failure. `stop` is emergency cancellation only.
- No screenshots or screen capture. An `MCP_GAP` names the objective, missing field,
  current tool, why it is needed, and smallest structured addition. It blocks
  only that branch; continue other productive work and never guess.
- Follow [player knowledge v1](PLAYER-KNOWLEDGE-v1.md) for durable knowledge.
- The gameplay baseline is permanently peaceful with enemy bases disabled;
  there are no combat tools or combat branch to plan for.
- No second body, raw Lua/console, teleport, hidden map, free items, scripted
  mining, imported blueprints, or second RCON path. Concurrency removes thinking
  idle time, not physical walking time.

For Candidate B use a Sol-medium read/plan-only master, Terra-low sole-writer
pilot, and Terra-low read-only specialist with fast mode off. Start from a
fresh immutable peaceful baseline with enemy bases disabled and both graphical
clients on the couch PC. At exactly `GO+20m`, record the required
instructions-only throughput snapshot in `operations.json` without stopping
the run. Continue the same trial toward a legitimate rocket launch; stop only
with later-tick structured rocket proof or an honest terminal failure after
relevant safe fallbacks are exhausted.
