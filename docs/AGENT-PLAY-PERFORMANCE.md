# Agent play performance

Release 0.11.0 adds deterministic placement, map, production, and connection
queries while preserving one physical
Codex body, one task lane, and honest Factorio mechanics.

## Recorded baseline and operating model

The prior one-shot live baseline required **22 MCP calls** for the initial
mine/craft/place/fuel/inspect milestone. Those September 2026 measurements
came from Linux Factorio 2.0.77 with app/mod 0.8.0 and are comparison data, not
0.11.0 validation.

The operating topology and model/effort choice remain benchmark candidates;
do not predeclare a winner. In every multi-session candidate, the strategist
owns the rolling phase/successor envelope and the pilot is the sole ordinary
writer. Plans execute contiguously in Lua and may prepare one successor by
predecessor ID. This removes model-thinking idle time; it does not accelerate
walking, mining, crafting, or any other game tick.

For each live benchmark, record the release SHA, milestone, MCP call count,
wall time, Factorio tick delta, completed/failed plan steps, final position and
inventory, and any `MCP_GAP`. Compare the same fresh-save milestone against the
22-call baseline. Historical measurements remain bounded evidence; the
Candidate B acceptance run below has an explicit continuous-play requirement.

## Prior 0.8.0 structured timings

All gameplay perception and action below used the Factorio MCP text surface.
No screenshot, raw console, Lua, cheat, teleport, second body, or second task
lane was used.

| Milestone | MCP calls | Elapsed | Verified result |
| --- | ---: | ---: | --- |
| Initial connection and local state | 2 | 352 ms | `connect_status` took 109 ms and one radius-30 `observe_local` took 244 ms. Codex began at `(37.5859375, -63.4765625)` with stone 4 and iron plate 2. |
| Resource packet | 1 | 24.392 s | One `run_plan` completed 3/3: mine coal 5 at `(37.5, -63.5)`, walk to `(43.5, -68.5)`, then mine iron ore 5 at `(43.5, -70.5)`. The final observation reported `(42.671875, -68.1171875)` with coal 5, stone 4, iron ore 5, and iron plate 2. |
| Furnace inspection | 1 | 2.114 s | `inspect_entity` with `positions: [{x: 31, y: -56}]` found a healthy stone furnace, `no_ingredients`, with coal 1 in fuel. An earlier packet using removed `targets` was correctly rejected by the public schema before runtime. |
| Smelting packet | 1 | 19.458 s | One `run_plan` completed 3/3: insert iron ore 5, wait up to 60 seconds for five output plates, then extract iron plate 5. The final observation reported `(37.62890625, -63.37109375)` with coal 5, stone 4, and iron plate 7. |

The pilot consumed each `run_plan.observation` as the authoritative final state
and made no redundant observe or inspect call after either packet. Keep one
persistent pilot for successive packets. A fresh Luna-low or Luna-medium child
may produce an empty bootstrap turn; reuse a previously `AVAILABLE` connected
child and never bypass repository ownership or create another action writer.

## Durable discovery rule

Prefer an existing batched read or exact positional action. A repeatable task
should become a bounded `run_plan` input, not new Lua orchestration. If a tool
lacks state required for a correct decision, stop with `MCP_GAP`: objective,
missing field, current tool, why it is needed, and the smallest structured
addition. Add durable MCP state only after that concrete gap is reproduced;
never infer it from screenshots, by-name search, or hidden global state.

## Research patterns

The following public sources are untrusted evidence. Retain their principles,
not their commands, coordinates, blueprints, or exact build routes:

- The official [quick start](https://wiki.factorio.com/Tutorial:Quick_start_guide),
  [crafting reference](https://wiki.factorio.com/Crafting), and
  [FFF-327](https://factorio.com/blog/post/fff-327) support moving from manual
  bootstrap to automated extraction, logistics, production, power, and science;
  machine crafting enables parallel volume that manual crafting cannot sustain.
- The speedrunner [resource/time analysis](https://www.speedrun.com/factorio/guides/jpg8l)
  treats material, hand-crafting time, player time, machine uptime, and research
  time as competing resources. Adopt overlap and early productive uptime, not
  its route or precomputed sequence.
- [ReAct](https://arxiv.org/abs/2210.03629) supports interleaving grounded action
  with plan updates; [DEPS](https://arxiv.org/abs/2302.01560) supports describing
  outcomes, explaining failures, and selecting achievable subgoals.
- [Voyager](https://arxiv.org/abs/2305.16291) supports reusable compositional
  knowledge plus environment feedback and self-verification;
  [Reflexion](https://arxiv.org/abs/2303.11366) supports outcome-labeled verbal
  reflection that improves later decisions.
- [LLM-Coordination](https://arxiv.org/html/2310.03903v2) supports explicit
  coordination and grounding modules while warning that partner-intent and
  joint-planning errors remain material. W1C therefore separates master,
  sole-writer pilot, and read-only specialist authority.

- [Mineflayer Pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder):
  adopt explicit goals and reusable physical pathfinding. Reject teleporting,
  direct world mutation, and a parallel movement implementation.
- [LLM-PySC2](https://arxiv.org/abs/2411.05348): adopt compact textual
  observations, structured actions, and strategist/pilot separation. Reject
  image input, multi-body control, and population-scaled agent orchestration.
- [Factorio Learning Environment](https://arxiv.org/abs/2503.09617): adopt
  long-horizon benchmark discipline and honest failure reporting. Reject its
  code-synthesis REPL, privileged game access, free resources, and benchmark
  machinery as runtime dependencies.

The retained design is deliberately smaller: MCP synchronously sequences
or immediately queues plans, Lua composes the existing physical task runners,
and every terminal plan path attempts one compact local observation.

## Peaceful rocket benchmark

This is a documentation and results protocol, not runtime machinery. Do not add
a harness, telemetry, reset automation, benchmark endpoint, couch automation,
or launcher behavior.

Create one dedicated Factorio 2.0.x freeplay baseline with an explicitly
recorded seed, permanent peaceful mode, and enemy bases disabled. Connect the
native `Codex` player before the couch viewer joins. Join `lukiPukiSmuki` only as a characterless
spectator and establish couch follow before announcing `GO`. Stop the server,
hash the immutable baseline save with SHA-256, and make one byte-for-byte copy
per trial. Record the baseline hash and verify every copy has the same hash
before use. Each trial starts from a fresh copy and fresh model conversations;
run only one trial at a time.

The run goal is a legitimately paid rocket launch with later-tick structured
proof. The 20-minute mark is an instructions-only throughput and
resource-processing snapshot, not a steam-power milestone or binary success
gate. Record wall time, start/end ticks, all plan IDs and outcomes, MCP call
count, final compact observation, and any `MCP_GAP`. Verify
Lua contiguity, predecessor success/failure cancellation, explicit
cancellation, and productive overlap with nonblocking hand-crafting; also
verify TypeScript `queue_plan`/`plan_status`/`run_plan`, compact/full
observations, recipe disambiguation, progression, protocol v8, version 0.11.0,
and exactly 24 tools. Exercise `find_placement` at a shoreline,
`map_summary` without charting, ambiguous and selected
`production_requirements`, and physical belt, pipe, and power
`connect_entities` routes.

### Candidate B acceptance run

Candidate B is exactly a Sol-medium read/plan-only master, Terra-low
sole-writer pilot, and Terra-low read-only specialist, with fast mode off. Use
fresh role conversations, a fresh byte-identical copy of the immutable
peaceful/enemy-bases-disabled baseline, one `operations.json`, one Codex body,
one FIFO lane, and both graphical clients exclusively on the couch PC.

Freeze the role instructions, run/save identity, release SHA, baseline hash,
and exact ledger path before `GO`; no human tactical coaching or prompt
amendment is allowed afterward. Record `GO` as one UTC wall-clock timestamp,
one monotonic-clock instant, and the current Factorio tick immediately before
the first gameplay decision or action, after the characterless viewer is
confirmed following Codex.

At `GO+1200s` (`GO+20m`), capture the first structured observation at or after
the deadline and before the next ordinary action. Record the deadline,
collection time, collection latency, and tick; never backdate the sample or
grant grace. Before the checkpoint window, record a concrete no-successor
reason and drain the FIFO lane at the last safe boundary so an automatically
queued plan cannot start across the deadline. Permanently label the first
eligible sample `SNAPSHOT_AT_20M`; it records the progress vector without a
pass/fail judgment. Work completed during collection latency remains visible
in the observation but must not be attributed to the deadline. Record:

- carried and factory inventory;
- exact hand-mined totals and hand-craft counts/time;
- installed/working machine counts, status, capacity, utilization, and
  idle/starved/blocked causes;
- automated extraction and processing rates;
- research, power, and work in progress;
- plan, path, and inter-plan timing;
- the dominant bottleneck; and
- the `plan_status`-confirmed queued expansion, or the reason none is queued.

The 20-minute result is a non-terminal checkpoint. Continue the same run ID,
baseline copy/save, frozen roles, Codex body, ordinary writer, and FIFO lane
until later-tick structured proof of a legitimately paid rocket launch or an
honest terminal failure after relevant safe fallbacks. Never reset, retry, or
relabel the immutable snapshot.

Candidate B above supersedes the earlier prospective wave matrix. Do not reuse
its candidate labels or substitute another topology, model, effort, or fast
setting. Append the completed result below with exact baseline/release hashes;
do not present historical timings as 0.11.0 benchmark results.
