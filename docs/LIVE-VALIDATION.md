# Live validation

This runbook validates release **0.7.0**.

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

## Observed two-machine setup

The following was verified during the September 2026 live run. Treat the LAN
addresses as runtime inputs, not permanent configuration: confirm them with
`ip address`/DHCP leases before each session.

- The Linux workstation hosted Factorio on its LAN address `192.0.2.117`
  and game UDP port `34197`.
- The couch PC was `COUCH-PC` at `192.0.2.119` and connected with
  Steam's Factorio launch argument `--mp-connect 192.0.2.117:34197`.
  `--connect-to-server` is not a valid Factorio argument.
- The Linux firewall must allow UDP `34197` from the trusted LAN. The tested
  rule was `ufw allow from 192.0.2.0/24 to any port 34197 proto udp`.
  Apply this only through the workstation's supervised firewall procedure;
  do not change router DHCP settings for this validation.
- The couch install needs the same `agentic-companion_0.7.0.zip` in
  `%APPDATA%\\Factorio\\mods` and an enabled `agentic-companion` entry in
  `%APPDATA%\\Factorio\\mod-list.json` before joining.
- The server's RCON remains private and local: `127.0.0.1:19015`. It is not
  the address the couch client uses.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the couch client. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before Steam will launch a fresh connection.

## Viewer-only couch session

Joining a multiplayer save creates a normal Factorio player slot by default.
The Codex MCP surface does not expose spectator-controller management. To
make the couch session genuinely view-only, use Factorio's built-in
administrator/spectator UI after joining and confirm that the couch account
has no character HUD or inventory. Do not add a raw Lua/console or cheat path
to the Codex mod. Until spectator mode is visibly confirmed, leave the couch
player stationary and use the map view only.

## Live results and known failure signatures

- `doctor --json` is the quickest preflight: it should report exact config
  shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app 0.7.0.
- A fresh MCP process should be used after rebuilding the CLI. The tested
  sequence was `connect_status`, `observe_local`, then an exact-coordinate
  `mine`; the successful physical result increased Codex inventory and
  completed the task. `stop` is safe cleanup when a task is still active.
- If an action reports `empty response from the game` while `stop` can still
  see the task, restart the CLI from the build containing the RCON
  response-order fix, then retry. Do not assume that an empty response means
  the enqueue did not mutate state.
- Physical mining requires the selected entity to be updated before
  `mining_state` is enabled. A task that approaches indefinitely with no
  inventory gain indicates a stale mod build; reinstall the current archive
  and restart Factorio.
- The observed couch launch reached `InGame` and the server logged the join.
  A successful network join alone does not prove spectator mode; verify the
  controller in the Factorio UI as described above.
