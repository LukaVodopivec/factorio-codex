# Agent play performance

Release 0.9.0 reduces reasoning round trips while preserving one physical
Codex body, one task lane, and honest Factorio mechanics.

## Recorded baseline and operating model

The prior one-shot live baseline required **22 MCP calls** for the initial
mine/craft/place/fuel/inspect milestone. Those September 2026 measurements
came from Linux Factorio 2.0.77 with app/mod 0.8.0 and are comparison data, not
0.9.0 validation.

The accepted operating candidate uses one persistent Sol-medium strategist and
one persistent Luna-low pilot. Sol owns the rolling phase/successor envelope;
Luna is the sole ordinary writer. Plans execute contiguously in Lua and may
prepare one successor by predecessor ID. This removes model-thinking idle time;
it does not accelerate walking, mining, crafting, or any other game tick.

For each live benchmark, record the release SHA, milestone, MCP call count,
wall time, Factorio tick delta, completed/failed plan steps, final position and
inventory, and any `MCP_GAP`. Compare the same fresh-save milestone against the
22-call baseline. These measurements document completed bounded packets; they
do not imply continuing autonomous gameplay.

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

- [Voyager](https://arxiv.org/abs/2305.16291): adopt reusable bounded skills
  and feedback after execution. Reject open-ended self-directed curricula,
  generated game code, and a second model loop inside the product.
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

## Peaceful steam milestone benchmark

This is a documentation and results protocol, not runtime machinery. Do not add
a harness, telemetry, reset automation, benchmark endpoint, couch automation,
or launcher behavior.

Create one dedicated Factorio 2.0.x freeplay baseline with an explicitly
recorded seed, peaceful mode enabled, and enemy bases disabled. Spawn Codex
before the couch viewer joins. Join `lukiPukiSmuki` only as a characterless
spectator and establish couch follow before announcing `GO`. Stop the server,
hash the immutable baseline save with SHA-256, and make one byte-for-byte copy
per trial. Record the baseline hash and verify every copy has the same hash
before use. Each trial starts from a fresh copy and fresh model conversations;
run only one trial at a time.

Success is a coal-fired steam plant powering a working electric mining drill,
with at least one mined ore delivered and later-tick structured proof, within
20 minutes of `GO`. Record wall time, start/end ticks, all plan IDs and
outcomes, MCP call count, final compact observation, and any `MCP_GAP`. Verify
Lua contiguity, predecessor success/failure cancellation, explicit
cancellation, and productive overlap with nonblocking hand-crafting; also
verify TypeScript `queue_plan`/`plan_status`/`run_plan`, compact/full
observations, recipe disambiguation, progression, protocol v6, version 0.9.0,
and exactly 20 tools.

Use at most three candidates in a wave:

| ID | Topology | Models / effort |
| --- | --- | --- |
| A | One session owns strategy and the sole writer role | Sol, medium |
| B | Read-only strategist plus sole pilot | Sol medium + Luna low |
| C | Read-only strategist, sole pilot, optional read-only specialist | Sol medium + Luna low + Luna low |

Run three repeats per retained wave and rotate order `ABC`, `BCA`, `CAB` to
reduce ordering bias. Fast wave 1 compares all three on completion and elapsed
time. Fast wave 2 retains no more than the best three variants and changes only
one documented prompt/envelope choice. Fast wave 3 confirms the leading choice
with the same immutable baseline. Never tune from a partial trial or run trials
concurrently. Append completed results below with exact baseline/release hashes;
do not present historical 0.8.0 timings as 0.9.0 benchmark results.
