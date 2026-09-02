# Live validation

Factorio was unavailable during the offline release verification. On a fresh
machine:

1. Launch Factorio 2.0.x once, reach the main menu, and exit. This must happen
   before setup so the user-data directory and `config/config.ini` exist.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Restart Factorio, enable **Factorio Codex Companion**, and host a dedicated
   fresh freeplay save. Console-backed RCON disables achievements for the save.
4. Run `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`.
5. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
6. Interrupt a long action in the TUI, then call `stop`.
7. If bootstrap items are absent, use another fresh built-in freeplay save.
   Never use console commands, editor mode, spawned items, or teleporting.
