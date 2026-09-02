# Live validation

This runbook validates release **0.12.1**. Prior live evidence remains historical
until the fresh 0.12.1 run is recorded. The Linux workstation has no dedicated
GPU and is permanently headless: run only the dedicated server, Node bridge,
and agent tooling there. Never start a Factorio GUI/client or any other visual
GUI workload on that workstation during rollout, validation, or a benchmark.
Both visual Factorio processes run exclusively on the couch PC. The
`scripts/launch-native-client.ps1` entrypoint is couch-only; the repository does
not provide a Linux visual client launcher.

1. On the couch PC, install the full standalone Factorio 2.0.x build under
   `%LOCALAPPDATA%\factorio-codex\standalone`, or pass its executable as
   `-FactorioBinary`. The Steam build is intentionally rejected for the Codex
   client because it replaces the isolated LAN identity.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Enable **Factorio Codex Companion** and host a dedicated base-game fresh
   freeplay save with permanent peaceful mode and enemy bases disabled. Keep
   elevated-rails, quality, and space-age disabled in both server and client.
   Console-backed RCON disables achievements for the save.
4. From the couch PC, run
   `scripts/launch-native-client.ps1 -Address <server:port>` to connect the
   isolated low-resource native client as the real player named `Codex`, before
   starting the normal couch Factorio client as the viewer. Its write-data and
   mod profile lives only in `%LOCALAPPDATA%\factorio-codex\native-client`. Run
   `node companion/dist/cli.js doctor`, start Codex at the repository root,
   then call `connect_status` and `observe_local`. Confirm the mod refuses an
   absent or wrong player instead of creating a standalone character.
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
8. Exercise `find_placement` at a shoreline; confirm `map_summary` reads only
   force-charted chunks; verify deterministic production arithmetic and
   ambiguity refusal; then physically connect steam power to an electric drill
   and deliver mined ore through belt, pipe, and power routes.
9. If bootstrap items are absent, use another fresh built-in freeplay save.
   Never use console commands, editor mode, spawned items, or teleporting.

## Two-session pilot contract

The same permanent machine boundary applies to every W1C run: the dedicated
server and agent sessions run on the headless workstation, while the exact
`Codex` client and the characterless spectator/follower run only on the couch
PC. Do not launch a local GUI as a recovery or benchmark shortcut.

For the Candidate B acceptance run use exactly a Sol-medium read/plan-only
master, Terra-low sole-writer pilot, Terra-low read-only specialist, and fast
mode off. Give all three the same exact
`/run/user/<uid>/factorio-codex/runs/<run-id>/operations.json` path. Before
`GO`, verify the fresh baseline copy and release hashes, permanent peaceful
mode/enemy bases disabled, exact `Codex` native player, characterless following
couch viewer, one body/lane/writer, frozen instructions, and no post-`GO` human
tactical coaching.

Record `GO` as UTC time, monotonic time, and Factorio tick immediately before
the first gameplay decision/action. At `GO+1200s`, take the first structured
observation at or after the deadline and before another ordinary action; record
collection latency and an immutable `SNAPSHOT_AT_20M` progress vector with
the complete throughput vector from `AGENT-PLAY-PERFORMANCE.md`. Drain the lane
at the last safe boundary before the checkpoint and do not queue a successor
that could start across the deadline. Work completed during collection latency
remains visible but must not be attributed to the deadline; the snapshot is not
a binary success gate. This is a checkpoint, not a stop: do not reset or restart the server or either client.
Continue the same save, run, roles, body, writer, and lane to later-tick
structured proof of a legitimately paid rocket launch or an honest terminal
failure after relevant safe fallbacks.

Use the topology and model/effort assignment selected by completed benchmark
results; do not assume a Sol/Luna winner. In a split topology, one strategist
may observe and plan, but one persistent pilot remains the sole ordinary MCP
action writer for one physical Codex body and one task lane. The strategist
sends bounded milestone packets; the pilot may observe, choose exact visible
coordinates, retry honest pathing, and finish the assigned milestone. End with
an authoritative observation: consume a fresh `run_plan.observation` directly;
call `observe_local` only when that observation is missing or became stale
after a subsequent action. Report position, inventory, active task, result,
and failure. Concurrency removes thinking idle time, not physical walking time.
Do not add a second body, raw Lua/console, teleport, hidden map, free resources,
or a second RCON path. `stop` is emergency cancellation only.

Use the current public schema shown by `tools/list`. In particular,
`inspect_entity` accepts `positions`; the removed `targets` input must fail
before runtime. Keep the same previously `AVAILABLE` persistent pilot across
packets. A fresh Luna-low or Luna-medium child can produce an empty bootstrap
turn; treat that as a platform residual and fall back to a previously available
connected child without bypassing repository ownership or adding an action
writer.

## Prior verified 0.8.0 live result

- `doctor` passed the complete config, authenticated RCON, protocol, and mod
  checks on Linux Factorio 2.0.77. `connect_status` reported app/mod 0.8.0.
- One `connect_status` call took 109 ms and one radius-30 `observe_local` call
  took 244 ms, 352 ms together. The initial structured state was position
  `(37.5859375, -63.4765625)`, stone 4, and iron plate 2.
- One three-step `run_plan` took 24.392 seconds and completed 3/3: mine coal 5
  at `(37.5, -63.5)`, walk to `(43.5, -68.5)`, and mine iron ore 5 at
  `(43.5, -70.5)`. Its final observation reported position
  `(42.671875, -68.1171875)` and inventory coal 5, stone 4, iron ore 5, and
  iron plate 2.
- `inspect_entity` with `positions: [{x: 31, y: -56}]` took 2.114 seconds and
  reported a healthy stone furnace with status `no_ingredients` and coal 1 in
  its fuel inventory. A packet using obsolete `targets` was rejected by the
  schema before runtime.
- One smelting `run_plan` took 19.458 seconds and completed 3/3: insert iron ore
  5, wait for five iron plates in output, and extract iron plate 5. Its final
  observation reported position `(37.62890625, -63.37109375)` and inventory
  coal 5, stone 4, and iron plate 7.

Each plan was one bounded milestone packet and exactly one MCP call. The pilot
used the plan's final observation without a redundant read. These are completed
live results, not a claim of ongoing gameplay. Gameplay used no screenshots,
raw console, Lua, cheats, or teleportation.

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
- The prior verified couch install used `agentic-companion_0.8.0.zip` in
  `%APPDATA%\\Factorio\\mods` and an enabled `agentic-companion` entry in
  `%APPDATA%\\Factorio\\mods\\mod-list.json` before joining. The verified couch
  ZIP matched the server archive hash, was enabled, and joined successfully.
- The server's RCON remains private and local: `127.0.0.1:19015`. It is not
  the address the couch client uses.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the couch client. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before Steam will launch a fresh connection. Wait for
`factorio.exe` to exit completely before replacing the ZIP: Windows briefly
retained a lock on the old archive during the verified rollout.

Before upgrading an existing 0.9.x save, stop the server and retain an exact
copy of both the save and its matching 0.9.x mod archive. Validate 0.12.1 on a
copy first. Rollback means stopping the server, restoring that paired save and
archive, and confirming the restored version through `doctor`; never open the
only rollback save with the newer mod.

An ordinary SSH `Start-Process` did not place Steam in the interactive console
session. The verified fallback used one limited, interactive, one-shot
Scheduled Task to launch Steam, then removed that task. Without screenshots,
confirm that the Factorio client process has `SessionId 1` and that its log
reaches `InGame`.

## Viewer-only couch session

The exact `Codex` client must join first. Every other connected identity is
made characterless and placed in spectator mode by the mod; there is no second
body and no administrator or console step. The current mod makes each connected
spectator camera follow the sole Codex body automatically. Codex itself still
walks physically; only the characterless viewer camera follows. Confirm the
normal couch identity has no body or inventory and remains aligned with Codex
during a physical `walk_to` action.

## Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below were collected before release 0.12.1. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.12.1. Complete the fresh run above after installing 0.12.1 before recording a
current-release result.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A 0.12.1 run must instead report protocol v9 and mod/app 0.12.1.
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
reconnection steps that SSH cannot perform, alongside the existing
AutoHotkey-based `couch-ui` fallback. Neither UI path controls Factorio through
the Codex MCP server. The gameplay pilot remains MCP-text-only: Windows-MCP's
Screenshot capability must never be used for Factorio perception or play.

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
