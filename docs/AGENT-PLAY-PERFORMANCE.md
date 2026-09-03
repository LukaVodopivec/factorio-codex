# Agent play performance

Release 0.13.10 retains each exact placed entity and validates the live output
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
0.13.10 validation.

The active topology is exactly two roles: a Sol-medium read/advice-only
strategist and the unchanged Terra-low sole-writer single-pilot baseline, with
fast mode off. The strategist has zero Factorio MCP access and writes
coordinate-free `strategy_proposal` advice; the pilot is the sole Factorio MCP
user, gameplay writer, and live-state authority. The first rollout is the next
fresh matched run. Plans execute contiguously in Lua and may prepare one successor by
predecessor ID. This removes model-thinking idle time; it does not accelerate
walking, mining, crafting, or any other game tick.

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
  joint-planning errors remain material. The active topology therefore
  separates a read/advice-only strategist from the sole-writer pilot.

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

For active role coordination, the strategist coalesces superseded pilot reports
by run and newest source tick and writes one atomic ledger revision for the
current analysis. `current_plan` and `queued_successor` mirror pilot-reported MCP
facts rather than strategist commands. The first decision uses one authoritative
preflight pilot report, immediately writes and sends a coordinate-free
`strategy_proposal`, and ends the strategist turn so new pilot evidence can
trigger a fresh turn; it consumes rather than repeats the pilot's initial report, and
equivalent diagnostics repeat only after action,
contradiction, or staleness. Each proposal states a falsifiable hypothesis,
predicted measurable effect, assumptions/preconditions, safe bounds, numeric
stop, invalidation, and confidence. It is non-executable advice: never an
envelope, plan enqueue, approval/gate, acknowledgement/resend/debate protocol,
or exact-coordinate command. The pilot reads at most one unique proposal per
source tick only at a natural decision boundary, validates save identity and every
precondition exactly once against the latest MCP state, then accepts or discards
it without acknowledgement or resend. It consumes each `run_plan` terminal
observation, reports only a material bottleneck, technology, production, or
expansion change or a repeated distinct failure, and never repeats an executed
plan ID. It never stops or reports
merely for one useful item or incidental non-production loot. Measured
automation utilization and continuous current-plus-successor work dominate.
At `GO`, the pilot sends the authoritative initial observation and immediately
performs bounded safe physical work under the bootstrap policy
while the strategist reasons without Factorio access. Current structured state selects the work: prefer
already-carried automation with a verified visible resource and exact sink;
otherwise scout a visible dry waypoint or gather the nearest measured blocker
to a numeric stop. The pilot continues without waiting and considers advice only
under the single-use natural-boundary rule. This creates no second writer, body, or
lane and prescribes no item, resource, order, coordinate, route, or timed phase.
The pilot never waits for the strategist or ledger, permanently owns local
bottleneck/action/fallback selection and the current plan plus one grounded
queued successor, reads the ledger once at startup rather than per MCP call, and
keeps useful work queued before reporting. Latest MCP
state always wins. A restarted strategist rebuilds from the ledger without
pausing the pilot or requesting replay. Strategist silence or an unavailable,
late, malformed, stale, or wrong-run proposal/ledger/message never pauses or
gates gameplay. The pilot alone owns the learning
loop, authoritative calculations, success, plans, fallbacks, batch authorization,
and milestone completion from later-tick MCP proof; the strategist only offers
one advisory proposal and mirrors pilot-reported facts.
An advisory proposal may flag a material-flow contradiction; the pilot
distinguishes a game bottleneck from an MCP observability gap and decides what
to do. Count capacity only after output is
accepted by its next physical sink and observable there. Upstream fuel/input
changes end with measured dependent utilization and a bounded corrective
successor. Rate claims without timing/buffer evidence use measured deltas and
retain expected/falsifier pairs. These are general learning-loop rules,
not a timed opening, fixed build order, named route, map coordinates, tutorial,
copied layout, online sequence, or gameplay-specific action chain.

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
observations including exact `ground_items`, physical `pickup_items`, recipe
disambiguation, progression, protocol v17, version 0.13.10, and exactly 25 tools.
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
present historical timings as 0.13.10 benchmark results.

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
