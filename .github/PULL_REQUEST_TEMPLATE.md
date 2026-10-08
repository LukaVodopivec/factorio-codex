## Summary

<!-- What changes, and why. Link the issue it closes, if any. -->

## Tests run

<!-- Commands and results, e.g. `npm test`. Say whether you also played it in a live Factorio 2.0 game. -->

## Checklist

- [ ] Follows "Enable thinking, never replace it": the mod executes a bot's decision, reports honest player-visible information, or does deterministic arithmetic; it never chooses a design, site, order, quantity or timing, and grants no free items, energy, or uncharted map knowledge.
- [ ] No RPC or `on_tick` handler takes more than about 8 ms of Lua time in one tick; larger work is budgeted per tick and spread across ticks as a job.
- [ ] Nothing scans the whole surface.
- [ ] The MCP surface still exposes no images, raw Lua, console commands, credentials, or uncharted terrain.
- [ ] Mod actions use no cursor or GUI and do not pass the player to `set_tiles`, `put`, `take`, or `copy_settings`.
- [ ] Movement, reach, inventory, crafting, placement, and time constraints stay observable and covered by tests.
- [ ] `npm test` passes, and docs are updated where behaviour changed.
