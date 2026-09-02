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
issue the first rolling envelope. The prompts select actions from current
structured state; none hardcodes a route, map position, or build sequence.

## Shared-run contract

For each run, the parent creates a fresh run ID and the shared directory
`${XDG_STATE_HOME:-$HOME/.local/state}/factorio-codex/runs/<run-id>`. The parent
alone writes `manifest.json`. The master alone writes `master-envelope.json`
and `decisions.md`; the pilot alone writes `pilot-state.json`, append-only
`pilot-events.jsonl`, and `landmarks.json`; the specialist alone writes
`specialist-notes.md`. Every participant reads every shared-run file and must
update exactly its owned files. Rewrite files atomically with an adjacent
temporary file and rename; only `pilot-events.jsonl` is appended, one complete
JSON object per line. The files are direct coordination artifacts: do not add a
watcher, broker, database, orchestrator, or other coordination process.

Run coordinates may appear only in `pilot-state.json`, `pilot-events.jsonl`,
or `landmarks.json`. They expire on a game reset, contradictory observation,
mutation of the referenced entity, or route failure and must not be copied to
durable player knowledge. Use deterministic MCP state and tool results before
shared notes or prose. Carry only the grounded current plan and one prepared
successor; invalidate stale state and keep safe productive work overlapping.

- Use the topology and model/effort assignment selected by completed benchmark
  results; do not assume a Sol/Luna winner. In a split topology, one strategist
  owns phase, success, and one prepared successor, one persistent pilot is the
  sole ordinary MCP action writer, and an optional specialist is read-only.
  Discard stale advice unless the pilot revalidates it.
- Maintain a rolling envelope: phase and success, executing plan, one prepared
  successor with predecessor and preconditions, prioritized fallbacks, current
  and next bill of materials, and source tick/plan ID.
- Prefer automation. Hand mining and hand crafting are bootstrap or emergency
  unblock work spent to unlock the next machine layer. Automate bulk extraction,
  smelting, intermediates, logistics, and science; overlap crafting, movement,
  production, and research; inspect and repair the dominant bottleneck. Keep
  the current plan plus one successor, and never wait while another safe
  productive action exists.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch reads and cluster travel. Direct positional actions auto-approach; use
  `walk_to` only for scouting or relocation. Use `build_plan` for layouts,
  `queue_plan`/`plan_status` for a prepared successor, and `run_plan` for
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
- No second body, raw Lua/console, teleport, hidden map, free items, or second
  RCON path. Concurrency removes thinking idle time, not physical walking time.
