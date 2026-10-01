# Live validation

This runbook validates release **0.17.0**. Prior live evidence remains historical
until the fresh 0.17.0 run is recorded. The Linux workstation has no dedicated
GPU and is permanently headless: run only the dedicated server, Node bridge,
and agent tooling there. Never start a Factorio GUI/client or any other visual
GUI workload on that workstation during rollout, validation, or a benchmark.
Both visual Factorio processes run exclusively on the couch PC. The
`scripts/launch-native-client.ps1` entrypoint is couch-only; the repository does
not provide a Linux visual client launcher.

1. On the couch PC, install the full standalone Factorio 2.0.x Space Age build under
   `%LOCALAPPDATA%\factorio-codex\standalone-space-age`, or pass its executable as
   `-FactorioBinary`. The Steam build is intentionally rejected for the Codex
   client because it replaces the isolated LAN identity.
2. Run `nvm use 22 && npm ci && npm run build && node companion/dist/cli.js setup`.
3. Host a dedicated Space Age fresh freeplay save from one run directory with
   permanent peaceful mode and enemy bases disabled:
   `node companion/dist/cli.js server create <run-dir>`, then
   `node companion/dist/cli.js server start <run-dir> [--bind <lan-address>]`.
   The run directory owns its save, logs, PID, and a run-local mod directory
   with base, elevated-rails, quality, space-age, and the companion enabled, so
   stale global mods never load. `server start` refuses a protocol or mod
   version mismatch before `GO`; `server stop <run-dir>` saves over RCON and
   shuts the server down at the run boundary instead of leaving it idle. Both
   server and couch client run the identical Space Age mod set.
   Console-backed RCON disables achievements for the save. Play is
   Nauvis-first: the MCP has no rocket, space-platform, or planet-travel tools
   yet.
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
   `nearest_target`, not duplicate entity rows. Observe an exact `ground_items`
   stack, call `pickup_items` with its unchanged position/item/count, and verify
   ordinary walking/ticks, target depletion, and the matching inventory delta.
6. Run a two-or-more-step `run_plan`. Confirm ordered fail-fast outcomes, no
   later enqueue after failure, and a final observation on completed, failed,
   and cancelled paths. Confirm Codex walks at ordinary Factorio speed and no
   global game-speed setting changes.
7. Interrupt a long action in the TUI, then call `stop`.
8. Exercise `find_placement` at a shoreline; confirm `map_summary` reads only
   force-charted chunks; verify deterministic production arithmetic and
   ambiguity refusal. Find a cardinal inserter placement with an exact
   `output_target`, physically place it with that target, and distinguish its
   live output point's valid 1×1 recipient geometry from runtime binding. A nil
   `drop_target` before first output must remain explicitly pending, not fail or
   claim binding; a non-nil different target must fail. For a mining drill,
   include legitimate starter fuel in the same build-plan step and confirm the
   plan waits until actual output flow exposes the exact runtime recipient.
   Inspect the placed inserter's `pickup_target` to
   falsify an incorrect source binding. Confirm an output-capable candidate always
   reports `output_position` and reports its recipient or explicit `null`; a
   selection-box-only furnace overlap must not pass exact target filtering.
   Confirm mining-drill candidates report
   only compatible resources whose centers are covered by their mining area; treat a
   deterministic rejection count for charted candidates with zero compatible
   resources and treat omitted coverage as uncharted. Inspect the live inserter
   and confirm its pickup/drop positions and valid target identities; confirm
   belt contents, a mining drill's actual output position, recipient-or-null and
   `drop_target_bound`, its current resource target, and exact furnace
   fuel/input/output buffers only where the corresponding inventory exists.
   Force a bounded no-path/stall fixture and confirm only its immediate charted
   collision segment, stable capped inferred visible collision candidates and
   collision tiles—not an authoritative blocker claim—or the explicit absence
   of an identified blocker. Confirm a terminal
   `plan_status` still carries only the assigned `queued`, first `running`, first
   applicable `waiting`, and truthful final transition after a fast successor.
   Then physically connect steam power to an
   electric drill and deliver mined ore through belt, pipe, and power routes.
9. If bootstrap items are absent, use another fresh built-in freeplay save.
   Gameplay roles never use console commands, editor mode, spawned items, or
   teleporting. A debug supervisor may use those surfaces only for recorded
   diagnosis or the smallest recovery intervention, after which the pilot must
   re-observe authoritative MCP state.

For the 0.17.0 reliability pass, also record these observable checks without
turning them into a fixed opening or map-specific sequence:

- A compact observation stays bounded, names every omission count, and appears
  once as structured content with only a short text summary. Full detail remains
  available only when deliberately requested.
- A freshly observed natural target either mines by exact identity or returns a
  named diagnostic distinguishing exact-coordinate resolution, physical reach,
  and engine selection. Re-observe after any stale-target result.
- A genuine no-path case reports only charted local collision evidence, any
  owned collision cage, and the best bounded reachable frontier/partial route;
  it neither walks that partial route automatically nor reveals uncharted state.
- A deliberately split electrical route reports successful pole placement
  separately from endpoint coverage and network continuity. Add an honest
  bridge and confirm the later result becomes connected; do not equate either
  result with a powered, working consumer without inspecting that consumer.
- A producer and its recipient can be preflighted when the recipient is an
  earlier placement in the same build plan. Wrong endpoint geometry fails
  before mutation, while runtime binding remains exact and pending until first
  output when appropriate.
- An out-of-range `wait_for_item` fails immediately with the physical-distance
  correction instead of consuming its timeout. An insertion that accepts only
  part of a request terminates as `partial`, reports requested/inserted/remainder
  counts, preserves the useful accepted amount, and does not execute dependent
  steps.
- Queue and plan responses carry a self-describing `terminal` state and exact
  `next_action`; a terminal continuation handle is never waited a second time.
- A plan with `observation_detail=none` returns compact outcomes, execution
  metadata, and inventory deltas without an embedded observation. Explicit
  compact/full requests retain bounded detail and omission counts.
- A bounded `plan_status` wait returns on a meaningful step outcome, waiting
  state, or terminal result. A monitoring timeout does not cancel the plan and
  returns a self-describing continuation.

## Persistent two-brain, one-writer contract

The dedicated server and agent session run on the headless workstation, while
the exact `Codex` client and characterless spectator/follower run only on the
couch PC. Do not launch a local GUI as a recovery shortcut.

The next fresh supervised-debug topology has exactly two persistent reasoning
sessions and one physical writer. Start the sole gameplay pilot as
`gpt-6-luna` with `low` reasoning and fast mode enabled. Start the persistent
strategist as `gpt-6.1-sol` with `medium` reasoning at normal speed and expose only the disabled-
by-default `factorio-readonly` MCP server to it; disable the full `factorio`
server in that Sol session. Sol owns NOW/NEXT/LATER and is the sole atomic writer
of one compact `operations.json`. Luna owns immediate safety, coordinates,
physical plans, actions, and latest exact local evidence. Sol reads never enter
the physical FIFO, and Luna continues without waiting when Sol or its ledger is
stale or unavailable. Record both profiles, their MCP surfaces, release SHA,
archive hash, and save hash before `GO`. Never apply this cutover to the current
run.

At cutover, launch the two sessions with role-specific project overrides (or
the equivalent supervised UI selections):

```sh
codex -m gpt-6-luna -c 'model_reasoning_effort="low"' -c 'service_tier="fast"' \
  -c mcp_servers.factorio.enabled=true -c mcp_servers.factorio-readonly.enabled=false
codex -m gpt-6.1-sol -c 'model_reasoning_effort="medium"' -c 'service_tier="default"' \
  -c mcp_servers.factorio.enabled=false -c mcp_servers.factorio-readonly.enabled=true
```

Start each with its checked-in role goal. Confirm Sol lists exactly the eight
configured read-only tools and cannot list any movement, transfer, crafting,
placement, research mutation, plan enqueue/run/cancel, or stop tool before
`GO`.

Before `GO`, verify the requested fresh save and release hashes, permanent
peaceful mode/enemy bases disabled, exact native player, viewer, and one
body/lane/writer. Continue past 20 minutes toward the assigned milestone;
Candidate B and R1-R7 freeze rules are historical unless the owner starts a benchmark.

The parent is the debug supervisor and may diagnose or recover through its
separate surfaces. That authority does not pass to the pilot. Record each
intervention and obtain a fresh structured observation before ordinary play.

The native `/goal` owns continuation. Waypoints, batches, plans, and progress
reports are nonterminal. While later-tick milestone proof is absent, immediately
continue whenever productive work or bounded recovery exists. Keep the current
plan and one grounded successor when safe.

After immediate safety and a hard production unblock, evaluate the
highest-payback expansion of the measured factory bottleneck before another
manual deficit batch. Record the growth objective, utilization, buffers, WIP,
service time, power headroom, current and foreseeable unlocked demand,
production deltas, item/time break-even, expected avoided touches, and expected
next bottleneck. Count expansion only after later evidence proves sustained
input, physical transfer, downstream acceptance, increased output, and
utilization. Reassess factory-wide flow after every material increase. Prefer
evidence-backed headroom, buffer-aware packets, and clustered trips over exact
next-task quantities. A progress report states the measured capacity change or
quantitatively justifies a short manual bridge.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent ticks are acceptable, then revalidate the newest
state before mutation. Do not add another body, lane, RCON path, raw Lua/console,
teleport, hidden state, or free resources. `stop` is emergency cancellation.
If a pilot goal terminates after an intervention, retire it before starting one
replacement; never keep two pilots active.

Use the current public schema shown by `tools/list`. Keep the same persistent
pilot across packets. An empty intermediate turn or report does not satisfy the
goal and must not add another action writer.

## Historical Candidate B R7 verified live result

R7 ran the immutable baseline SHA-256
`616de9daf11ffdc03f946dd1f76732f4544539801f0f28db62959bcf8f1eea8e` with
deployed commit `80a5874eabc8d9822e7c8d24dd36b68ece4e26e6` and archive SHA-256
`d8d3600e4eb0a1d0087d1c9810070e514c4491c7abf05e63f01f14f58b3a2106`.
`GO` was `2026-09-03T06:26:52.063455112Z` at tick `23015`; the deadline was
`2026-09-03T06:46:52.065339056Z`. The last ordinary action completed at
`2026-09-03T06:46:24.228Z`, before the deadline. The first read-only frozen sample
completed at `2026-09-03T06:47:08Z` with `source_tick=95498`. No post-deadline
gameplay occurred, and the 15.9-second collection latency grants no grace
or attribution to the deadline.

The frozen sample recorded carried `iron-plate=40`, `copper-plate=10`,
`copper-ore=8`, and `wood=2`, plus `iron-plate=10` in furnace output. Queue
depth, active task, and crafting queue were respectively `0`, `null`, and `0`.
The pre-deadline inspection at `2026-09-03T06:46:16.362Z`, 35.7 seconds before
the cutoff, showed furnace output `iron-plate=9` and one active craft at
progress `0.73`; earlier completed extracts had already established 40 carried
plates. Thus the exact cutoff lower bound is 49 processed iron plates.
Accepted copper and iron drill-to-chest extraction, `copper-plate=10`, and
Electronics were proved before the deadline.

The tenth furnace plate and Steam Power are collection-confirmed. Passive
pre-cutoff processing makes them overwhelmingly likely to reflect work already
underway before the cutoff, but the late snapshot alone is not exact-deadline
proof. Retain 49 as the cutoff lower bound unless tighter master-ledger tick
attribution is established. This remains satisfactory automation-first progress
relative to R5/R6, not a completed rocket objective.

Residuals were manual tree-fuel travel, manual chest/furnace transfers, one
recovered trapped layout, and master ledger/message lag that caused stale
envelopes and false post-deadline attribution. General follow-up remains
state-driven: validate access and accepted output before scaling, use measured
utilization to select the next bottleneck, and derive snapshot attribution only
from authoritative timestamps, ticks, and frozen structured evidence. For a
mining drill, nil `drop_target` before production means runtime binding is still
unknown; a matching non-nil target becomes authoritative after first output.

Current commit `c56a5f5149f381fd0cc88860a24259f3f9b62e89` was published during
R7. It retains the live-proven geometry behavior and adds explicit
pending-first-output plus fueled `build_plan` waiting semantics, but it was not
deployed or benchmarked in R7. This result used no map-coordinate evidence,
fixed route or order, screenshot, raw console, or gameplay cheat.

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

Post-run screenshots are permitted only after the scored run is frozen and only
when structured MCP evidence is insufficient for review. Review all relevant
map areas where items or machines were placed, but treat images as
non-authoritative: they must not contribute coordinates, routes, tactics, or
durable knowledge, and they never support live perception, navigation,
targeting, placement choice, or action selection. Revalidate every finding that
could affect a later run through structured in-game MCP data. This permission
does not authorize couch GUI control or expand the Windows-MCP boundary.

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
- Factorio dedicated-server process arguments contain the RCON secret. Never
  print or read full arguments through `ps` full args, `/proc` command-line
  data, WMI `CommandLine`, or an equivalent process-inspection surface. Verify
  health through user-service state, PID, executable basename, and `doctor`
  only, and keep all reported output secret-redacted.

After changing the repository build or mod, run setup again, confirm both
Factorio config files are mode `0600`, restart the dedicated server, and then
reconnect the couch client. A client left in Factorio's
`WaitingForUserToSaveOrQuitAfterServerLeft` state must be exited or its
Factorio process closed before Steam will launch a fresh connection. Wait for
`factorio.exe` to exit completely before replacing the ZIP: Windows briefly
retained a lock on the old archive during the verified rollout.

Before upgrading an existing 0.9.x save, stop the server and retain an exact
copy of both the save and its matching 0.9.x mod archive. Validate 0.17.0 on a
copy first. Rollback means stopping the server, restoring that paired save and
archive, and confirming the restored version through `doctor`; never open the
only rollback save with the newer mod.

An ordinary SSH `Start-Process` did not place Steam in the interactive console
session. The verified fallback used one limited, interactive, one-shot
Scheduled Task to launch Steam, then removed that task. Without screenshots,
confirm that the Factorio client process has `SessionId 1` and that its log
reaches `InGame`.

The couch display runs at `3840x2160`, and `scripts/launch-native-client.ps1`
renders the isolated client at that native 16:9 size. A recorder may downscale
the captured window to `1920x1080`, but it must fit the complete source without
cropping or enlarging a lower-resolution viewport. Before a timed recording,
verify the live Factorio client area, capture-source dimensions and aspect
ratio, crop/transform state, and representative framing. A non-black Factorio
frame alone is not sufficient evidence of usable framing.

## Viewer-only couch session

The exact `Codex` client must join first. Every other connected identity is
made characterless and placed in spectator mode by the mod; there is no second
body and no administrator or console step. The current mod makes each connected
spectator camera follow the sole Codex body automatically. Codex itself still
walks physically; only the characterless viewer camera follows. Confirm the
normal couch identity has no body or inventory and remains aligned with Codex
during a physical `walk_to` action.

## Prior-release 0.7.0 live evidence and known failure signatures

The successful observations below were collected before release 0.17.0. They
are historical 0.7.0 evidence and diagnostic guidance, not live validation of
0.17.0. Complete the fresh run above after installing 0.17.0 before recording a
current-release result.

- `doctor --json` is the quickest preflight: the historical run reported exact
  config shape/mode `0600`, authenticated RCON, protocol/mod v5, and mod/app
  0.8.0. A 0.17.0 run must instead report protocol v22 and mod/app 0.17.0.
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
