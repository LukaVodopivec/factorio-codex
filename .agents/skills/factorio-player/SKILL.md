---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex.

- Use the topology and model/effort assignment selected by completed benchmark
  results; do not assume a Sol/Luna winner. In a split topology, one strategist
  owns phase, success, and one prepared successor, one persistent pilot is the
  sole ordinary MCP action writer, and an optional specialist is read-only.
  Discard stale advice unless the pilot revalidates it.
- Maintain a rolling envelope: phase and success, executing plan, one prepared
  successor with predecessor and preconditions, prioritized fallbacks, current
  and next bill of materials, and source tick/plan ID.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch reads and cluster travel. Direct positional actions auto-approach; use
  `walk_to` only for scouting or relocation. Use `build_plan` for layouts,
  `queue_plan`/`plan_status` for a prepared successor, and `run_plan` for
  synchronous compatibility. `inspect_entity` accepts `positions`.
- The pilot may mine, refuel, collect output, repair routes, or take an approved
  fallback without waiting. Priority is defend; unblock production; mine the
  BOM bottleneck in batches; build validated automation; physically scout.
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
- No second body, raw Lua/console, teleport, hidden map, free items, or second
  RCON path. Concurrency removes thinking idle time, not physical walking time.
