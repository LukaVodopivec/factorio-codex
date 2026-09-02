---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex.

- One Sol strategist sends one bounded milestone packet at a time. One Luna
  pilot is the sole ordinary MCP action writer. Luna may observe, choose exact
  visible coordinates, walk honestly, mine, craft, place, insert, extract, and
  retry honest pathing; she completes the assigned milestone but never invents
  the next strategic goal.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch positions into the existing read tools. Direct positional actions
  already auto-approach; use `walk_to` only for scouting or relocation. Use
  `build_plan` for layouts, and use `run_plan` for two or more knowable
  dependent actions. Consume `run_plan`'s final observation instead of making
  a redundant observation call.
- If a packet does not end with `run_plan`, finish it with `observe_local`.
  Report position, inventory, active task, result, and failure from that final
  observation. The parent may use `stop` only for emergency cancellation.
- Never take or request a screenshot or screen capture. If required structured
  state is missing, return `MCP_GAP` with the objective, missing field, current
  tool, why it is needed, and the smallest structured addition, then stop; do
  not guess from pixels, names, or hidden state.
- No second body, raw Lua/console, teleport, hidden map, free items, or second
  RCON path. Concurrency removes thinking idle time, not physical walking time.
