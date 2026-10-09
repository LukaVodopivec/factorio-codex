# Architecture

Factorio Codex lets Codex sessions play Factorio through one physical
character. There is one active path, and everything else hangs off it:

```text
Codex session (planner)  --stdio-->  factorio-codex mcp --surface read-only --role strategist --+
                                                                                                |
Codex session (pilot)    --stdio-->  factorio-codex mcp --role pilot  (+ package bridge) -------+
                                                                                                |
                                         serialized RCON bridge (companion/src/bridge.ts) <-----+
                                                                |
                                         /silent-command remote.call("agentic", "rpc", ...)
                                                                |
                                         Factorio 2.0 headless server + agentic-companion mod
                                                                |
                                         the connected player "Codex" (the only body)
```

## The mod

`mod/agentic-companion` is a Factorio 2.0 mod. `control.lua` registers one
remote interface, `agentic`, whose `rpc` function dispatches each method
registered in `scripts/rpc.lua`. The mod owns everything deterministic:

- **The body.** The mod binds the connected player named `Codex` and drives
  that player's real character (`scripts/companion.lua`). It never creates,
  replaces or teleports a character; other players become spectators.
- **The FIFO.** Physical work runs as plans of steps in one queue
  (`scripts/tasks.lua`, `scripts/actions/`). Walking, reach, mining, crafting,
  inventory and placement are the game's own; nothing is free.
- **Reads.** `factory_status`, `map_summary`, `observe_local`,
  `inspect_entity`, placement searches and dry runs read charted state only.
  `factory_status` lists at most 10 lines, worst first, and counts every line
  in `line_counts` and `by_state`; an `output_full` line's cause may be
  `drop_blocked` with `drop_into`. `inspect_entity` reads exact positions, or
  lists own entities in one charted area of at most 64 x 64 tiles as compact
  rows (`scripts/inspect.lua`). Heavy reads run as jobs spread over ticks
  (`scripts/jobs.lua`).
- **Line tracking** (`scripts/autonomy.lua`), auto-supply, the power model,
  charting and blueprints, as listed in the README's "What the mod does by
  itself".
- **Budgets.** No RPC or `on_tick` handler may use more than about 8 ms of Lua
  time in a tick, and nothing scans the whole surface: handlers process a fixed
  number of work items per tick and spread the rest over later ticks.

### Upkeep and recoveries

Recoveries happen inside an action: stepping off a belt, leaving a placement
footprint, mining an owned blocker that encloses the body, one re-approach
after an out-of-reach result, one retry of a partial insert.

Upkeep (`scripts/chores.lua`) is the mod's own plan with source `upkeep`.
When no queued plan needs the body, no human hold is active, and a plan has
finished since the last emergency stop, the body refuels dry or low-fuel
burners and brings the current research's science packs to labs, from own
stock, within 96 tiles (and near recent work sites after two idle minutes), on
its planet only. Queued work takes the body back at the next step boundary.
Upkeep never chooses what to build.

## The companion

`companion/` is a Node 22 TypeScript package; its CLI (`companion/src/cli.ts`)
is `factorio-codex`.

- **RCON bridge** (`rcon.ts`, `bridge.ts`): one serialized RCON connection per
  process, calling the mod's RPC with JSON payloads and polling jobs to their
  result. Replies up to 256 KiB come in one piece. The pilot's process sends
  its writer generation with every write and the supervisor's labels its
  writes (the writer fence in `docs/LIVE-VALIDATION.md`); a write whose answer is lost is reported as
  `OUTCOME_UNKNOWN`, never retried silently.
- **MCP server** (`mcp/server.ts`): a stdio MCP server started by Codex from the
  committed `.codex/config.toml` through `scripts/start-factorio-mcp`. The
  `full` surface has every tool; `read-only` has only reads and dry runs.
  `--role` names the session (`pilot`, `strategist`, `advisor`, `supervisor`)
  in the origin of every cancel it makes.
- **Server lifecycle** (`server/server.ts`): `server create|start|stop` for a
  run directory with its own save, mod set, logs and ledger. `server start`
  records the run as current; the MCP processes read its ledger.

## Roles

| Role | MCP surface | Writes |
| --- | --- | --- |
| Pilot | full, `--role pilot` | gameplay (the only writer), `notebook/pilot/` |
| Planner (strategist) | read-only, `--role strategist` | `operations.json` via `ledger-apply`, `notebook/strategist/` |

The pilot is the foreman: it waits on `next_event`, handles failed plans, an
empty queue and local judgment, and sends no reports. The planner owns the
coordinate-free NOW/NEXT/LATER priorities, the architecture and research, and
designs build packages from its own layouts or this run's blueprints, dry-run
with `check_only`. A single session with the full surface can also play alone.
Role rules live in `.agents/skills/factorio-player/` (`SKILL.md` and one goal
file per role).

## The ledger and build packages

`<run-dir>/operations.json` is the planner's only channel to the pilot. The
planner writes it only through `factorio-codex ledger-apply --ledger <file>`,
which validates the update (`coordination/ledger.ts`), rejects stale or
duplicate reports (by `source_tick`) and reused package ids, and writes it atomically with mode
0600. Each call appends its outcome to `ledger-history.jsonl` beside the ledger
(`at`, `status`, `revision` or `reason` and `issues`, the update's
`package_ids`), as evidence only. An applied update that drops packages the
bridge never queued names them in `omitted_unqueued` (a fact, not a refusal).
`ledger-apply --schema` prints the update envelope, the update's fields, the
package and step fields with their numeric caps, and the notes path rule. A
ledger holds the run identity, the priorities, at most two build
packages and up to seven research technologies.

The pilot's MCP process runs the package bridge (`coordination/orders.ts`)
about once a second:

1. Read the ledger of the current run.
2. Queue each new package into the FIFO in ledger order, after the mod's
   placement check, as a plan with source `package:<id>`; make its leading
   `blueprint_capture` steps first. A package waits as `waiting_surface` while
   the body is on another surface; `travel` is never in a package.
3. Queue the ledger's research list once per revision, skipping what is already
   researched or queued.
4. Record outcomes in `<run-dir>/package-queue.json`, with what each capture
   returned (`captured`: name, entities, wires), also on a failed check; a
   failure reaches both roles as `package_failed`. Every queued package's
   record gets `plan_ended_tick` and `plan_status` once its plan ends.
5. Measure a package's optional `verify` metrics (up to three: an item's
   production per minute, or the state of the line at a position) once, two
   minutes of game time after its plan ends, through `factory_status`'s
   bridge-only `measure`. The outcome stays on the package's record and
   reaches both roles as `package_verified` or `package_unmet`, with the
   measured values; a partial plan's `NO_LINE` row carries `plan_status`. A
   failed or cancelled plan is not measured: its verification is
   `not_measured` with reason `plan <status>`, and no event. It is measurement
   only: nothing is fixed or queued again.

Packages written before an emergency `stop` stay held until the planner
rewrites the ledger, and a human hold parks everything. Every tool result
carries the planner's `orders` once each time the ledger revision changes.

## Human takeover

The human player can take the body over with mouse and keyboard at any time.
Real control input on the Codex client parks the FIFO without cancelling
anything; it resumes about five seconds after the last input. Tools report
this as `human_control`.

## Run recorder and thought feed

`factorio-codex runs record --ledger <run-dir>/operations.json ...`
(`runs/telemetry.ts`) takes a baseline, prints `GO`, samples the factory every
five minutes of wall time, and closes the run on Ctrl-C. Records live under
`~/.local/share/factorio-codex/runs/run-<id>/`.

With `--pilot-rollout` and `--strategist-rollout` the recorder also runs the
thought feed (`runs/thoughts.ts`): it tails both Codex rollout files and saves
each reasoning summary and assistant message, never tool calls or outputs, to
`thoughts.jsonl`. The ledger writer's lines go to the mod's `say` RPC, which
shows them in an always-visible panel on the Codex screen under the current NOW
objective, never in game chat. The feed is output only.

Run telemetry, all beside the samples and never shown to the bots:

- `tool_outcomes.jsonl`: one row per MCP tool call (`at`, `role`, `tool`,
  `status`, `code` (a failure's leading mod `CODE:`, else `TOOL_ERROR`),
  `ok` (the call itself succeeded: not `isError`), `event` (`next_event`'s
  kind), `summary` (the result's text, at most 200 characters, only when the
  call failed or its status is not `ok`, `completed` or `running`),
  `duration_ms`). `status` is the result's own status (a plan's or an
  event's for `plan_status` and `next_event`), else `failed` for an error,
  `not_ok` for a result with `ok: false` such as a failed dry run (its
  `code` then its own or its first `failed` row's), else `ok`. Rows are
  appended asynchronously by the MCP layer
  for the run its current run directory's ledger names, only while the
  recorder's run directory exists, capped at 16 MiB; a dropped row never
  delays or fails the call.
- `manifest.json` `telemetry.roles`: each role's turn time split into model
  (`model_ms`), tool (`tool_ms`), wait (`wait_ms`) and compaction
  (`compaction_ms`) time, from the rollout event times the feed reads (tool
  items' own spans, model calls to their outputs, and compaction items; model
  items such as reasoning and plans are model time). `wait_ms` is the
  `next_event` MCP calls' own spans, taken out of tool time even inside the
  exec cell that ran them. `model_calls` counts the model's call items
  (code-mode `exec` and `wait` cells), `mcp_calls` the MCP tool calls they
  made, `reasoning_items` the reasoning items and `reasoning_summarized` those
  with a non-empty summary (only those reach the thought feed). Manifests
  before 0.36 have `tool_calls` (now `model_calls`) and no wait split.
- `manifest.json` `telemetry.body`: the body's time by state between the
  baseline and final samples (`pilot`, `package`, `upkeep`, `crafting`,
  `hold`, `dead`, `idle`), the busy share (directed work: `pilot`,
  `package` and `crafting`; `upkeep` is the mod's chore and shows only in
  `states`), and idle gaps by the state that ended them, from the mod's
  `tasks.body_time` counters in `run_snapshot`. The baseline
  (`run_snapshot {window = true}`) marks the window, so idle before `GO` is
  no gap of the run; idle still open at the final sample is the gap `open`.
- `manifest.json` `telemetry.milestones`: each rocket milestone the final
  sample's `run_snapshot.milestones` holds (`rocket_ready`,
  `rocket_launch_ordered`, `rocket_launched`: the mod's first tick of each),
  with its `tick` and `elapsed_s` from `GO` (the baseline tick). Each
  technology's first finish tick stays in the samples' `milestones.research`.
- `manifest.json` `telemetry.holds`: human holds in the window (`count`,
  `total_seconds` of holds (an open hold's ticks so far included), and the `recent` episodes, at most 16, with
  `start_tick`, `end_tick` (absent while open) and `cause`), from the mod's
  hold record in `run_snapshot.holds`; `telemetry.handler_errors`: caught mod
  handler faults in the window, from `run_snapshot.handler_errors`. Each
  field is absent when the mod did not report it.

Run attestation: every `run_snapshot` (the baseline and each sample) carries
`attestation`: `game.speed`, the Codex player's `cheat_mode` and controllers,
the active mods, and each force or character modifier that research does not
explain. Speed other than 1, cheat mode not off, an editor or god controller,
a mod outside base, elevated-rails, quality, space-age and agentic-companion,
or a modifier above what research grants marks the run assisted through
`markRunAssisted`, once per fact, with the fact as the reason.

## Timelapse

The `timelapse` RPC (`scripts/timelapse.lua`) makes the Codex client save a
3840x2160 frame every five game seconds into its `script-output/timelapse/`,
framing the largest cluster of production machines and zooming out as it
grows, until the first rocket launch. It is output only: no MCP tool starts or
reads it, and no image reaches the bots. `scripts/timelapse-video.ps1` joins the
frames into a video.

## Enable thinking, never replace it

From `AGENTS.md`:

> **Enable thinking, never replace it.** The mod and the instructions let the
> bots show their thinking; they never do it for them.
>
> - The mod may execute a bot's decision (walk, fetch, craft, clear, upkeep,
>   recovery), give honest player-visible information (charted state, patch
>   outlines, what a footprint covers, why a machine stops, answers to the bot's
>   own search), and do deterministic arithmetic (rates, counts that cover a
>   stated demand, item totals).
> - The mod never chooses a design, site, order, quantity or timing, and never
>   grants free items or energy, or uncharted or cross-run map knowledge.
> - Instructions pass the same test: rules, mechanics, tool contracts, and
>   principles with their reasons; never build, research or planet orders,
>   opening scripts, fixed counts, layouts or coordinates.
> - Self-check: if a tool or passage lets a bot act well without deciding what,
>   where, when or how many, it is doing the thinking.
