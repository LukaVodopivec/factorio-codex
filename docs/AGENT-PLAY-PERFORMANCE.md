# Agent play performance

Release 0.19.2 retains each exact placed entity and validates the live output
point through Factorio's 1×1 output-tile entity query rather than selection-box
containment. Exact geometry is distinct from runtime binding: a nil
`drop_target` is reported as pending first output, while a non-nil wrong target
fails. A mining-drill build-plan step applies its legitimate starter insertion
once, then waits for first output to expose the exact runtime recipient. It also
fails honestly on invalidation and distinguishes queueable research
from in-game trigger unlocks without
dropping item/entity quality constraints, scripted descriptions, or fieldless
space-platform triggers. It also labels main versus equipped-ammunition
inventory. It retains 0.13.8's exact
pre/post-verified inserter output-recipient binding and compatible mining-drill
resource coverage with deterministic charted-zero rejection and omitted
uncharted coverage. Entity inspection
retains exact live inserter endpoint/target, current drill target, and belt
content evidence. It retains 0.13.0's physical ground-stack pickup,
native path-completion events inside nested plan actions, deterministic queries,
one physical Codex body, one task lane, and honest Factorio mechanics.

## Recorded baseline and operating model

The prior one-shot live baseline required **22 MCP calls** for the initial
mine/craft/place/fuel/inspect milestone. Those September 2026 measurements
came from Linux Factorio 2.0.77 with app/mod 0.8.0 and are comparison data, not
0.19.2 validation.

The next fresh-run topology has two persistent reasoning sessions and one
physical writer. The `gpt-6-luna` pilot uses `low` reasoning with fast mode
enabled and is the sole gameplay writer, character controller, and exact-local-
state authority. The persistent `gpt-6.1-sol` strategist uses `medium` reasoning at normal speed,
owns one compact NOW/NEXT/LATER list, atomically writes `operations.json`, and
receives only the separate read-only MCP surface. Strategist reads never enter
the physical FIFO. Luna validates advice against newer physical evidence and
continues fail-open when Sol or the ledger is stale or unavailable. Record both
profiles before `GO`; never change the active debug run in place.

Plans execute contiguously in Lua and may prepare one successor by predecessor
ID. This removes model-thinking idle time; it does not accelerate walking,
mining, crafting, or any other game tick.

After the scored run is frozen, screenshots may be taken for human or agent
review of every relevant map area where items or machines were placed, but only
when structured MCP evidence is insufficient. They are non-authoritative review
evidence and must never drive live perception, navigation, targeting, placement
choice, or action selection. Do not derive coordinates, routes, tactics, or
durable knowledge from them. Any screenshot finding that could affect a later
run must first be revalidated through structured in-game MCP data. The benchmark
implementation and every rerun remain text-only.

For each live benchmark, record the release SHA, milestone, MCP call count,
wall time, Factorio tick delta, completed/failed plan steps, final position and
inventory, and any `MCP_GAP`. Compare the same fresh-save milestone against the
22-call baseline. Historical measurements remain bounded evidence; Candidate B
and R1-R7 below do not select the active topology.

## 2026-10-01 supervised debug run (0.17.0) and measurement method

Run `debug-20261001T190246Z` was supervised and assisted, so it is never
benchmark evidence. It produced 11 iron plates by `GO+20m` and 22 by the final
24.55-minute sample, with no autonomous segment. Measured from the role session
transcripts between `GO` and the pause (1,398 s):

- The pilot never ended its gameplay turn (one 25.8-minute turn), so no queued
  strategist or supervisor message, including cancellation, reached it.
- A physical MCP call was in flight for 195 s (14%); model time between calls
  was 1,165 s (83%). It made 0 `queue_plan` calls and 42 synchronous physical
  calls, and followed 41 of them with a read. The longest physical idle gap was
  192 s of deliberation.
- Fourteen character transfers moved 44 items for 23 plates; every ore was hand
  mined and inserted, and a one-coal fuel seed starved the coal drill.
- Each `map_summary` `detail=full` call held one game tick for about 4.5 s, which
  cost about 1.5% of simulation time and showed as freezes and catch-up jumps on
  the couch client.

Measure later runs the same way, without new instrumentation: per-call timing
comes from the role transcript records (tool call start/end, reasoning items,
turn start/end and abort events) joined with plan `transitions` ticks read back
before the record TTL expires, plus recorder samples and the couch client log's
`Latency changed to (N)` lines. Report turn lengths, message send-to-delivery
latency, physical-busy share, steps per decision boundary, observations after
successful actions, transfer actions per product, and the longest idle gap.

The viewer camera reuse survey for that run found no maintained follow-camera
mod that fits: Item Cam 2 follows items, Multi-Team Support adds forces and
surfaces, and Better Spectator targets Factorio 2.1 only. The native
`LuaPlayer.centered_on` field is the candidate if the existing spectator
follow ever judders; no candidate code was imported.

## 2026-10-01 supervised debug run (0.18.0) and the 0.19.0 role split

Run `debug-20261001T223054Z` (seed 747930220) was assisted by one steered idle
nudge and paused after 33.8 recorded minutes with 10 iron plates, 9 coal, two
machines, one physical edge, and no autonomous segment. Between `GO` and the
pause (2,002 s) the pilot's tool calls ran for under a minute (33 s blocking
physical work); model time between calls was 1,917 s (96%). Its first turn
lasted about 24 minutes, and its first `queue_plan` came 13.6 minutes after
`GO`. The largest single cost was placement design: 42 `find_placement` and
`can_place` calls preceded by 618 s of deliberation. Two defects made the
basic burner-drill-into-furnace layout unfindable (a planned 2x2 recipient was
snapped into the drill, and a flush drill's output lies 1/256 tile outside the
furnace's collision box yet binds), and empty results carried no reason, so the
pilot repeated an impossible inserter request between adjacent entities.
Steered delivery and the stop sequence worked, and full `map_summary` no
longer stalled the game (about 99.9% of real time).

Release 0.19.0 fixes the placement geometry against an isolated 2.0.77 probe,
explains empty placement results, and moves coupled-layout design to Sol as
validated build packages that the pilot revalidates and queues unchanged. The
Factorio Learning Environment results (frontier models place entities too
close, leave no room for connections, and repeat failing fixes) and the PEAR
planner-executor benchmark (planner strength dominates) support putting layout
judgement on the stronger model and keeping the fast model on execution.

## 2026-10-02 debug cycle 1 (0.19.0) and the 0.19.1 loop fixes

Run `debug-20261001T235110Z` started a fresh game on seed 747930220 and stopped
at `GO+20m`; two steered idle nudges made it assisted. Against the 0.18.0 run
over the same window it reached 7 machines and 21 physical edges (2 and 1),
148 finished products (10), first `queue_plan` at 85 s (815 s), 4 placement
calls (27), and no repeated empty search (5). Sol's build packages placed a
belt-fed coal path and a plate export to a chest. Pilot think-time was still
89% of wall time, concentrated before `queue_plan`, report messages, and 11
whole-ledger reads; the body idled twice for about 2.4 minutes while the pilot
waited on Sol's next package. No component became autonomous: the first
validation named 20 positions against the 16-position cap, the retry named real
blockers (belt orientation, blocked downstream, missing input, full output,
fuel provenance), and nobody repaired them before the pilot left the site.

Release 0.19.1 says in the validation schema and errors that one exact node
position validates its whole component, makes every segment-completing package
end with a validation step whose named blockers become the next repair, and
tightens the pilot loop: queue before reading or reporting, read only the
ledger fields it needs, and report material events in about 300 bytes.

## 2026-10-02 debug cycle 2 (0.19.1) and the 0.19.2 idle feedback

Run `debug-20261002T003357Z` (fresh game, seed 747930220) stopped at `GO+20m`
with 2 machines, 1 physical edge, about 33 finished products, and no autonomous
component. It was assisted by a GO delivery recovery (the stop rehearsal left
both roles interrupted and idle, so the queued GO waited 70 s for a native turn
start) and one steered idle nudge. A provider-wide stall of 5 minutes left all
sessions without reasoning. Sol's build packages flowed: the pilot queued three
(drill into furnace, plate export to a chest, coal drill into a chest), and the
first validation failed its preflight on fuel, as every burner node needs a
physical fuel edge. The decisive measurement is body busy time: plan running
intervals covered about 14% of the run (12% in cycle 1), because most plans
lasted seconds while each pilot decision took 20 to 85 s.

Release 0.19.2 makes that cost visible where the pilot looks: `queue_plan`
returns `body_idle_ticks`, the time the FIFO sat empty before the plan, and its
summary names idle seconds from 10 s on. The pilot sizes each plan to outlast
its next decision, and the runbook delivers `GO` as a native turn start on each
role thread with a running turn read back.

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
- [LLM-Coordination](https://arxiv.org/html/2310.03903v2) warns that partner
  intent and joint-planning errors remain material. The selected active design
  contains that failure surface with one physical writer, a compact strategic
  task list, exact evidence freshness, and fail-open pilot authority.

- [Mineflayer Pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder):
  adopt explicit goals and reusable physical pathfinding. Reject teleporting,
  direct world mutation, and a parallel movement implementation.
- [LLM-PySC2](https://arxiv.org/abs/2411.05348): adopt compact textual
  observations and structured actions. Reject image input, multi-body control,
  strategist/pilot orchestration, and population-scaled agents.
- [Factorio Learning Environment](https://arxiv.org/abs/2503.09617): adopt
  long-horizon benchmark discipline and honest failure reporting. Reject its
  code-synthesis REPL, privileged game access, free resources, and benchmark
  machinery as runtime dependencies.

The retained design is deliberately smaller: MCP synchronously sequences or
immediately queues plans, Lua composes the existing physical task runners, and
terminal plans return concise deltas unless compact/full observation is
explicitly requested.

R5's bounded Firecrawl reuse review found maintained agent projects with deterministic
validator and skill patterns, but no compatible licensed component that owns
Factorio's vanilla output geometry, trigger-research classification, or
character inventory compartments under this one-body, one-writer, text-only
physical contract. Candidate code was unnecessary, incompatible, or had
unclear licensing, so none was imported. The retained path uses Factorio's
official live `drop_position`, output-tile entity search, runtime `drop_target`,
and `LuaTechnologyPrototype.research_trigger` state directly and
changes no game mechanics.

Authoritative parsed R5 calls show plan 25 was the stone mine, while plan 26
was submitted with `after_plan_id=21`, not 25. Plan 26 correctly remained
queued while plan 25 ran and then cancelled because its declared predecessor
21 had not completed; pilot prose incorrectly relabeled the predecessor as 25.
This was an agent reporting failure, not a FIFO runtime failure. A standalone
craft appends to the same flat queue and normal completion clears only its own
active task. A regression proves a successor whose actual `after_plan_id`
names its successful predecessor remains queued across independent crafting
and is then released. Pilot reports must copy returned `queue_plan` and
`plan_status` IDs verbatim rather than reconstructing them from memory.
Terminal observations also label `inventory` as the
main compartment and expose equipped ammunition separately, preventing an
empty-main-inventory reading from implying that equipped magazines vanished.

The pilot physically places a mining drill only from a `find_placement`
candidate whose `resource_coverage` is present and contains positive compatible
coverage. Missing or empty coverage requires further structured observation and
revalidation, not placement. This applies equally to omitted uncharted coverage
and preserves deterministic rejection of charted candidates with zero compatible
resources.

For active play, the native `/goal` keeps one pilot running through waypoints,
batches, plans, and reports until later-tick milestone proof, explicit stop, or
a genuine exhausted blocker. The pilot permanently owns the local bottleneck,
growth objective, action and fallback selection, current plan, and one grounded
successor. Latest structured MCP state wins and every plan ID is copied from the
tool result rather than reconstructed.

After immediate safety and a hard production unblock, the pilot evaluates the
highest-payback capacity expansion before another manual deficit batch. It uses
measured utilization, input/output buffers, WIP, travel/service time, current
and foreseeable unlocked recipe demand, power headroom, production deltas,
item/time break-even, and expected future touches. It expands the bottlenecked
stage until downstream demand, power, supply, or another stage becomes limiting,
then reassesses factory-wide flow. Repeated manual crafting, fueling, hauling,
collection, or one-machine service is automation evidence unless remaining
useful demand cannot repay the investment.

Capacity requires sustained accepted flow, not theoretical machine count: a
later observation must prove input availability, physical transfer, downstream
acceptance, increased output, and utilization. Evidence-backed headroom is
preferred when current demand makes reuse likely. Fuel and input packets are
sized from observed rates, buffers, WIP, required uptime, and travel/correction
time. Progress reports state the measured capacity change and next bottleneck,
or quantitatively explain why a bounded manual bridge still has better payback.

Exactly one physical MCP call may be in flight through the sole FIFO. Read-only
observations may overlap only when inconsistent ticks are acceptable, followed
by newest-state revalidation before mutation. These are generic learning and
growth rules, not a timed opening, fixed build order, named route, technology
order, map coordinate, tutorial, copied layout, online sequence, or prescribed
action chain.

## Peaceful rocket benchmark

The foreground `factorio-codex runs record` command is the one retained
measurement path. It takes the `GO` baseline, then writes cumulative native
production/consumption counters, run-relative raw resources, and bounded
factory context at absolute five-minute wall-clock deadlines. It uses one
internal read-only RPC without adding an MCP tool, gameplay writer, FIFO lane,
daemon, reset automation, couch automation, or launcher behavior. A failed
deadline is stored as an error sample and is never backdated or replaced with a
fabricated checkpoint.

Run manifests copy the immutable identity from `operations.json` and add the
variant and change under test. Store supervised debug runs, but mark any
intervention with `runs mark-assisted`; debug and assisted runs are excluded
from automatic benchmark verdicts. `runs compare` issues `improved` or `worse`
only for component-wise raw-resource dominance between completed, unassisted
benchmark runs from the same baseline hash. Resource tradeoffs remain `mixed`.

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
observations including exact `ground_items`, physical `pickup_items`, recipe
disambiguation, progression, protocol v22, version 0.19.2, and exactly 25 tools.
Exercise `find_placement` at a shoreline,
`map_summary` without charting, ambiguous and selected
`production_requirements`, and physical belt, pipe, and power
`connect_entities` routes.

### Historical Candidate B acceptance run

Candidate B historically used exactly a Sol-medium read/plan-only master, Terra-low
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

The 20-minute result freezes and terminates the scored trial without turning
the progress vector into a binary pass/fail gate. Immediately cancel and drain
the FIFO, record that evidence, and permit no post-snapshot gameplay. Diagnose
the frozen result and repair the general interface or guidance. Any rerun uses
a fresh byte-identical baseline, fresh role conversations, and a new run ID;
never reset, retry, or relabel the immutable snapshot.

If a newly observed difficulty appears to require greenfield code, first run
one bounded Firecrawl reuse survey for maintained mods, interfaces, or tools
that already solve the deterministic responsibility. Evaluate license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether the candidate adds cheats, hidden map state, raw
console, imported blueprints, or tutorial sequences. Reuse or adapt the
smallest maintained compatible path. If none fits, record only why candidates
are design evidence and patch the smallest existing active path; do not add a
service, gate, or report bureaucracy.

For the R4 inserter-observation gap, that bounded survey found the maintained
MIT `SimpleAdjustableInserters` and `quick-adjustable-inserters` mods. Both
change custom inserter vectors or player adjustment interactions instead of
reporting vanilla bound-target identity, so neither fits the observation-only,
one-body/one-writer, text-only physical contract. No candidate code was
imported. The retained implementation uses Factorio's official LuaEntity
`pickup_target`, `drop_target`, `pickup_position`, and `drop_position` fields
through the existing inspection path.

Candidate B superseded the earlier prospective wave matrix for its historical
run series. Do not reuse its candidate labels as active topology instructions.
The completed result below retains its exact baseline/release hashes; do not
present historical timings as 0.19.2 benchmark results.

#### Candidate B R7 recorded result

Candidate B R7 used the immutable baseline with SHA-256
`616de9daf11ffdc03f946dd1f76732f4544539801f0f28db62959bcf8f1eea8e` and
the exact deployed predecessor commit `80a5874eabc8d9822e7c8d24dd36b68ece4e26e6`.
The deployed archive SHA-256 was
`d8d3600e4eb0a1d0087d1c9810070e514c4491c7abf05e63f01f14f58b3a2106`.
`GO` was `2026-09-03T06:26:52.063455112Z` at Factorio tick `23015`, and the
deadline was `2026-09-03T06:46:52.065339056Z`. The last ordinary action
completed at `2026-09-03T06:46:24.228Z`. The first read-only frozen snapshot
completed at `2026-09-03T06:47:08Z` with `source_tick=95498`, 15.9 seconds
after the deadline. No post-deadline gameplay occurred, and no work visible
during collection latency is attributed to the deadline.

`SNAPSHOT_AT_20M` recorded carried `iron-plate=40`, `copper-plate=10`,
`copper-ore=8`, and `wood=2`; furnace output contained `iron-plate=10`.
The FIFO queue depth was zero, the active task was `null`, and the character
crafting queue was zero. The strongest pre-deadline inspection, at
`2026-09-03T06:46:16.362Z`—35.7 seconds before the deadline—showed nine iron
plates in furnace output and one active craft at progress `0.73`; the carried
40 plates were already established by earlier completed extracts. The exact
pre-deadline lower bound is therefore 49 processed iron plates. Accepted
automated copper and iron drill-to-chest extraction, `copper-plate=10`, and the
Electronics unlock were also established before the deadline.

The tenth furnace plate and Steam Power are collection-confirmed by the
15.9-second-late frozen snapshot. Passive pre-cutoff processing makes both
overwhelmingly likely to reflect work already underway before the cutoff, but
they are not exact-deadline proof. Keep 49 as the exact cutoff lower bound
unless the master ledger establishes tighter tick attribution.

This is a satisfactory automation-first progress vector compared with R5 and
R6, not rocket completion. Remaining bottlenecks were manual tree-fuel trips,
manual chest/furnace transfers, recovery from one initially trapped layout,
and master ledger/message lag that produced stale envelopes and false
post-deadline attribution. Treat those as measured improvement targets, not a
prescribed route or fixed order. Validate physical access and accepted output
before scaling; replace manual material handling only when current structured
state and measured utilization identify it as the bottleneck. Snapshot
attribution comes only from authoritative timestamps, ticks, and the frozen
observation, never from delayed prose.

The run also confirmed that an early nil mining-drill `drop_target` is not a
failure or proof of binding: exact output geometry remains predictive, while
the runtime target becomes authoritative only after first output. Current
commit `c56a5f5149f381fd0cc88860a24259f3f9b62e89` retains the demonstrated
geometry behavior and improves pending-first-output reporting and fueled
`build_plan` waiting semantics. It was published during R7 and was neither the
deployed artifact nor benchmarked in this run.
