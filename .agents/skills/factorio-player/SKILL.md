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
- Finish every packet with `observe_local`, reporting position, inventory,
  active task, result, and failure. The parent may use `stop` only for emergency
  cancellation.
- No second body, raw Lua/console, teleport, hidden map, free items, or second
  RCON path. Concurrency removes thinking idle time, not physical walking time.
