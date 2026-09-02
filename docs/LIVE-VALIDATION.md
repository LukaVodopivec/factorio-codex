# Live validation

This runbook validates release **0.8.0**.

Factorio was unavailable during the offline release verification. On a fresh
machine:

1. Launch Factorio 2.0.x once, reach the main menu, and exit. This must happen
   before setup so the user-data directory and `config/config.ini` exist.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Restart Factorio, enable **Factorio Codex Companion**, and host a dedicated
   fresh freeplay save with enemy bases disabled so biters cannot spawn.
   Console-backed RCON disables achievements for the save.
4. Run `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`.
5. Physically mine resources; place a burner mining drill and stone furnace;
   insert legitimately acquired fuel; wait; inspect; extract. Confirm inventory
   changes, elapsed ticks, full footprints, honest reach and path failures.
   Verify `mine` count repeats cycles only on its initial exact resource and
   that `observe_local` reports resources as connected patches with an exact
   `nearest_target`, not duplicate entity rows.
6. Run a two-or-more-step `run_plan`. Confirm ordered fail-fast outcomes, no
   later enqueue after failure, and a final observation on completed, failed,
   and cancelled paths. Confirm Codex walks at ordinary Factorio speed and no
   global game-speed setting changes.
7. Interrupt a long action in the TUI, then call `stop`.
8. If bootstrap items are absent, use another fresh built-in freeplay save.
   Never use console commands, editor mode, spawned items, or teleporting.

## Two-session pilot contract

One Sol strategist may observe and plan, but one Luna pilot remains the sole
ordinary MCP action writer for one physical Codex body and one task lane. Sol
sends bounded milestone packets; Luna may observe, choose exact visible
coordinates, retry honest pathing, and finish the assigned milestone. End with
an authoritative observation: consume `run_plan.observation` when `run_plan`
is used; otherwise call `observe_local`. Report position, inventory, active
task, result, and failure. Concurrency removes thinking idle time, not physical
walking time. Do not add a second body, raw Lua/console, teleport, hidden map,
free resources, or a second RCON path. `stop` is emergency cancellation only.

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
- The couch install needs the same `agentic-companion_0.8.0.zip` in
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

For the tested headless server, perform this from the dedicated-server console,
where the result can be verified authoritatively. First run
`/promote <couch-player-name>`, then run
`/c local p=game.get_player("<couch-player-name>"); p.set_controller{type=defines.controllers.spectator}; log("spectator="..tostring(p.controller_type==defines.controllers.spectator).." character="..tostring(p.character~=nil))`.
Require the server log to report `spectator=true character=false`. A UI bridge
reporting that it typed the command, or other visual-only evidence, is not
sufficient evidence because keyboard focus and open GUI panels can make those
signals misleading. This is an administrator/cheat command and disables
achievements for the save.

With the current mod loaded, every connected spectator camera follows the sole
Codex body automatically. Codex itself still walks physically; only the
characterless viewer camera is repositioned. Confirm the camera follows during
a `walk_to` action and that a normal player is never moved by this behavior.

## Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below were collected before release 0.8.0. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.8.0. Complete the fresh run above after installing 0.8.0 before recording a
current-release result.

- `doctor --json` is the quickest preflight: it should report exact config
  shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app 0.8.0.
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

## Optional couch UI navigation layer

For semantic Windows UI navigation, the couch PC was tested with
[CursorTouch Windows-MCP 0.8.5](https://pypi.org/project/windows-mcp/0.8.5/).
This is an optional fallback for non-game couch UI, administration, or
reconnection steps that SSH cannot perform. It does not control Factorio
through the Codex MCP server. The gameplay pilot remains MCP-text-only:
Windows-MCP's Screenshot capability must never be used for Factorio
perception or play.

The tested deployment details are:

- Python 3.12 and `windows-mcp==0.8.5` installed for the Windows user.
- A per-user Scheduled Task named `windows-mcp-server`, running at logon with
  limited (non-elevated) privileges.
- Streamable HTTP bound only to `127.0.0.1:8000`; never expose this listener
  directly on the LAN. If remote use is needed, carry it through the existing
  authenticated SSH connection with a local port forward.
- Telemetry disabled with `ANONYMIZED_TELEMETRY=false` and an empty
  `POSTHOG_API_KEY`.
- The launcher passes this explicit UI-only allowlist:
  `Screenshot,Snapshot,Click,Type,Scroll,Move,Shortcut,Wait,WaitFor,DisplayInventory,App`.
  PowerShell, FileSystem, Registry, Process, Clipboard, Scrape, Notification,
  MultiSelect, and MultiEdit are excluded. Screenshot remains unavailable to
  the Factorio gameplay pilot regardless of this UI administration allowlist.

The installer rewrites `~/.windows-mcp/start-server.cmd`; apply the allowlist
to that launcher after installation and restart only the `windows-mcp-server`
task. If using `config.toml`, write it as UTF-8 without a BOM: Windows
PowerShell's default UTF-8 writer can otherwise cause `Invalid statement` at
startup. Verify with a local MCP `initialize`/`tools/list` request and confirm
exactly 11 tools before adding the server to a client.

The tested endpoint reported Windows-MCP 4.0.1 internally even though the
installed package was 0.8.5; use the package version for pinning and retain
the scheduled-task launcher as the source of the effective runtime options.
