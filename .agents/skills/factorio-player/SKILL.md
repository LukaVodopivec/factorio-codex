---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex.

- One Sol strategist sends one bounded milestone packet at a time. Reuse one
  previously `AVAILABLE` persistent Luna pilot as the sole ordinary MCP action
  writer. Luna may observe, choose exact visible coordinates, walk honestly,
  mine, craft, place, insert, extract, and retry honest pathing; she completes
  the assigned milestone but never invents the next strategic goal.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch positions into the existing read tools. Direct positional actions
  already auto-approach; use `walk_to` only for scouting or relocation. Use
  `build_plan` for layouts, and use `run_plan` for two or more knowable
  dependent actions. Follow the current public schema exactly: `inspect_entity`
  accepts `positions`, never the removed `targets` input.
- Finish every packet with an authoritative observation: consume a fresh
  `run_plan.observation` directly. Call `observe_local` only when that final
  observation is missing or became stale after a subsequent action. Report
  position, inventory, active task, result, and failure from that final
  observation. The parent may use `stop` only for emergency cancellation.
- Never take or request a screenshot or screen capture. If required structured
  state is missing, return `MCP_GAP` with the objective, missing field, current
  tool, why it is needed, and the smallest structured addition, then stop; do
  not guess from pixels, names, or hidden state.
- No second body, raw Lua/console, teleport, hidden map, free items, or second
  RCON path. Concurrency removes thinking idle time, not physical walking time.
- A newly bootstrapped Luna-low or Luna-medium child can return an empty first
  turn. Treat that as a platform residual: reuse a previously `AVAILABLE`
  persistent child, or return the packet to the parent for normal connected-TUI
  recovery. Never bypass repository ownership or open a second action writer.
