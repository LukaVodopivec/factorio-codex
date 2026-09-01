# Live validation

Factorio was unavailable during the offline release verification. Run this on
a machine with Factorio 2.0.x installed:

1. `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`
2. Restart Factorio, enable **Factorio Codex Companion**, and host a dedicated
   fresh freeplay save. Console-backed RCON disables achievements for the save.
3. Run `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`.
4. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
5. Interrupt a long action in the TUI, then call `stop`.
6. If bootstrap items are absent, use another fresh built-in freeplay save.
   Never use console commands, editor mode, spawned items, or teleporting.
