# Agent play performance

Release 0.19.8 retains each exact placed entity and validates the live output
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
0.19.8 validation.

The next fresh-run topology has two persistent reasoning sessions and one
physical writer. The `gpt-6-luna` pilot uses `low` reasoning with fast mode
enabled and is the sole gameplay writer, character controller, and exact-local-
state authority. The persistent `gpt-6-astra` strategist uses `medium` reasoning at normal speed,
owns one compact NOW/NEXT/LATER list, atomically writes `operations.json`, and
receives only the separate read-only MCP surface. Strategist reads never enter
the physical FIFO. Luna validates advice against newer physical evidence and
continues fail-open when Astra or the ledger is stale or unavailable. Record both
profiles before `GO`; never change the active debug run in place. Cycles 1-6 and
their continuations ran the earlier `gpt-6.1-sol` strategist ("Sol" below).

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

## 2026-10-02 debug cycle 3 (0.19.2) and the 0.19.3 observation cost fix

Run `debug-20261002T011309Z` (fresh game, seed 747930220) stopped at `GO+20m`
with 6 machines, 13 physical edges, 70 finished products, and no nudge; `GO`
went through the native resumption procedure. The idle feedback raised body
busy time from about 14% to 34% and the first `queue_plan` came 24 s after
`GO`. Sol designed a full mined-coal fuel corridor, but all three validations
failed on `fuel_input_provenance_unresolved`: each was queued on a hand-fuelled
burner segment. The worst idle gaps began when a plan ended and the pilot then
reasoned with nothing queued, and its context grew from 94k to 235k tokens,
partly from reading other sessions' threads at turn starts.

The couch client's latency stayed at 60 to 90 ticks, rising within seconds of
Sol's read bursts. An isolated headless benchmark of the final save found the
cause: `observe_local` clustered resource patches by comparing every ore tile
with every other through engine position reads, costing 600 to 740 ms of tick
time per call at radius 30 (about 2,400 ore tiles). Release 0.19.3 clusters
through a tile-bucket index with each position read once and produces
byte-identical output at 36 to 48 ms. `plan_status` also reports `fifo_empty`
and says so when a terminal plan leaves the body idle, the pilot no longer
reads threads after `GO`, and validation steps close only segments whose every
node has a physical feed.

## 2026-10-02 debug cycle 4 (0.19.3) and the 0.19.4 self-fuel provenance

Run `debug-20261002T015403Z` (fresh game, seed 747930220) stopped at `GO+20m`
with 6 machines, 15 physical edges, 53 finished products, and no nudge. The
couch client logged no latency change in the whole run (cycles 2 and 3 held
60 to 90 ticks), confirming the `observe_local` cost fix, and the server ran
at about 100% of real time. The pilot read no threads after `GO`. Sol's
packages built the first self-fuelling coal loop: a burner coal drill refuelled
by a return inserter from its own output while its buffer grew from 4 to 50
with zero character transfers. Validation still reported
`fuel_input_provenance_unresolved`, because the provenance walk never accepted
a node as its own fuel source. The iron chain starved meanwhile, holding
finished products at 53 from minute 15, and the pilot sent 17 reports in one
20-minute turn because almost every new edge counted as reportable.

Release 0.19.4 accepts a burner source that physically refuels itself from
its own output as fuel provenance (never as another input's provenance), and
defines the pilot's report checkpoint as a package queued or falsified, a
validation result, a falsified ledger assumption, no safe successor, a
supervisor stop, or otherwise about three minutes of game time since the last
report, with no corrections or follow-ups.

## 2026-10-02 debug cycle 5 (0.19.4) and the 0.19.5 pre-GO conduct

Run `debug-20261002T023048Z` (fresh game, seed 747930220) stopped at `GO+20m`
with 6 machines, 10 physical edges, 83 finished products, and no nudge. Pilot
model time fell to 54% of wall time, the first cycle within the 60% target;
body busy time reached about 45%, the largest gap between pilot calls was
56 s, and the pilot sent two reports instead of 17. The couch client again
logged no latency change. Production flattened from minute 15 when the iron
furnace ran out of fuel while Sol kept validating a coal-only fuel loop, which
the 0.19.4 topology rule could not prove; upstream 7d49443 since made
source-only segments provable. The pilot entered `GO` with 204k tokens of
context (76k in cycle 4) after polling threads about 20 times and reading the
supervisor runbook before `GO`.

Release 0.19.5 has the pilot read only its startup files and the runbook's
profile-evidence procedure before `GO`, report, observe once, and end its
turn; later pre-`GO` turns do only what their message asks, and the
thread-read ban covers the whole run.

## 2026-10-02 debug cycle 5 continuation and the 0.19.6 validator audit

Cycle 5 continued open-ended as run `debug-20261002T055630Z-continue`. An
audit of its transcripts and recorder samples together with cycles 1 to 5
found 18 `validate_factory_component` attempts, none proven and all failing at
preflight, although 13 of them targeted segments that were delivering
material. The continuation pilot also read threads 32 times despite the ban.
Four validator defects were confirmed in source:

- A belt counted an output only from `belt_neighbours`, which never includes
  inserters, so every correct belt ending at an inserter pickup reported
  `belt_orientation_does_not_reach_consumer`, and a fixture asserted it.
- One sample of `insufficient_input` or `full_output` failed preflight or ended
  the window, so supply-limited segments, whose burner inserters wait most of
  the time, could never pass.
- In Factorio 2.0 `LuaBurner.currently_burning.name` is an item prototype, not
  a string, so the fuel-return saturation exemption never applied live
  and `inspect_entity` showed `currently_burning: null`.
- Blockers reached the agents as deduplicated names without positions, and the
  pilot once repaired an unreported coordinate and broke a working loop.

Chests accumulated because the instructions turned these false signals into
work. Sol repaired every named blocker before any other objective, the pilot
cleared `full_output` and `blocked_output` by adding sinks, every package ended
in a new terminal chest, and no package step could remove an obsolete entity,
so later packages were chained through the leftovers.

Release 0.19.6 judges validation by throughput. Belt dead ends are decided per
belt run, including underground pairs and loader containers, as
`belt_dead_end_without_consumer` at the run's last tile. Blocker rows carry
`class`, `position`, `entity` and `related_edge`; status waits are transient,
and `blocked_output` requires an inventory that refuses the item. Preflight is
topology only, and a segment missing its fuel edge or downstream path is
refused as `FACTORY_COMPONENT_NOT_READY` with located rows. A window fails
structurally only on `persistent_nonproductive_status:<status>` after a
20-second stall, and the burner read accepts the prototype object. Replays of
the recorded cycle-5 coal loop and the continuation's coal-return buffer now
pass offline, while a surplus takeoff upstream of the fuel takeoff still fails
at its drill. Sol and the pilot now repair only located structural rows, re-run
a flow-only failure once with a longer window, redesign after two strikes, give
each segment one terminal buffer, and may remove owned obsolete entities
through guarded package `mine` steps. Belt orientation in `find_placement` and
other geometry helpers wait for cycle-6 data.

The release folds in the parallel fixes for several issues that landed
first. It keeps their quality-aware pole reach, their prototype-shaped burner
reads and the empty-hand `burning_and_stocked_fuel` return identity. Their
per-sample transport and fuel-return obligations are replaced by window rules.
An inserter still waiting for source items at the end, past the path recency
limit, fails as `transport_starved_before_end` unless its drop target already
names a longer window. This also catches a hand-stocked fuel chest behind a
surplus takeoff that took every coal, which the audit had proven falsely,
even after the feeder swung once early. An unreadable burner fuel stock fails as
`fuel_stock_unreadable`. Window samples alternate 29 and 28 ticks apart to reduce
aliasing; this does not guarantee observing every short swing. A sampled burner
fuel rise resets the source-wait streak of its unique supplied inserter inlet,
because that exact path delivered fuel between samples. Another possible fuel
inlet makes this attribution ambiguous; replenishment then cannot reset either
inserter's streak. This uses private component samples and does not expose fuel
quantities or runtime identities. It is an event reset, not a permanent exemption:
one early refill cannot excuse later starvation. Saturation and a pending
longer-window row at the exact drop target retain their existing meanings.

For an earlier issue, the reported two 60-second windows had equal topology signatures
and production totals, but neither those totals nor whole-window wait counts
identify the final uninterrupted sampled source-wait streak. The rejection uses
that streak, strictly older than 20 seconds at the end of a 60-second window.
Offline deterministic short-swing timelines reproduced phase-dependent results
before the reset correction; supplied phases now pass, while stopped and
ambiguous returns remain unproven. A separate pair produced 15 plates and 125
wait samples in each window but correctly differed: final sampled wait streaks
of 1,234 versus 1,149 ticks straddled the 1,200-tick boundary. These are synthetic
regressions, not a replay or diagnosis of the exact live windows. Discriminating
live evidence would include start/end ticks, sample phase, final streak, fuel
rise observations, saturation and pending drop-target rows. No installation or
live confirmation was performed for this correction.

Known limit: a long belt feeding several burners from a cold
start can fail a 60-second window and pass at 300 seconds, so use the longer
window there.

## 2026-10-02 debug cycle 6 (0.19.6) and its open-ended continuation

Run `debug-20261002T104321Z` (fresh game, seed 747930220, release 9138e78)
stopped at its `GO+20m` deadline, 5 s late. The owner's request to keep it running
was queued behind the supervisor's busy turn and arrived after the stop. The
saved factory then continued open-ended as `debug-20261002T111425Z-continue`
(GO 11:35:31Z). The owner stopped it at 15:28:55Z. Its recorder finished at
15:30:35Z, at final checkpoint 47 (+235.6 min, tick 989414), and the server
saved the final state (save SHA-256 `86e1da6f…f8fe9`). Both roles' goals were
paused and their turns interrupted, the ledger stayed at revision 71, and the
role sessions and the couch client were closed. Re-measured `GO+20m` rows for
cycles 1-6:

| Metric | c1 | c2 | c3 | c4 | c5 | c6 | Target |
|---|---|---|---|---|---|---|---|
| Pilot think share % | 89 | 93 | 83 | 85 | 56 | 83 | <60 |
| Body busy % | 12 | 14 | 34 | 28 | 45 | 33 | >=50 |
| Machines / physical edges | 7/21 | 4/4 | 6/13 | 6/15 | 6/10 | 5/8 | >=6/>=4 |
| Products finished | 139 | 46 | 59 | 53 | 83 | 39 | |
| Validations reaching window / proven | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 2/0 | >=1/>=1 |
| Pre-window failures with flow evidence | 1 | 1 | 3 | 0 | 1 | 0 | 0 |
| Blockers with position % | 0 | 0 | 0 | — | 0 | 100 | 100 |
| Pilot thread reads after `GO` | 7 | 8 | 14 | 0 | 0 | 8 | 0 |

The 0.19.6 structural goals held, and throughput fell back:

- The pilot entered `GO` with 185k tokens of context.
- It sent every report to the supervisor and none to Sol.
- It placed its first machine at `GO+6:07`.

**Continuation.** The first pilot was replaced at 14:58Z. Before that, it ran
for 12,162 s:

- 82% model time;
- 1,234 requests averaging 134k input tokens;
- 309 `queue_plan` calls, 47% of them single-step;
- an idle body for about two thirds of the window, including validation
  windows;
- no `connect_entities` calls.

Eight compactions dropped the thread ban but kept the transport text that
orders thread reconciliation. As a result:

- the pilot read threads at about 29 call sites;
- Sol polled the pilot thread 94 times (707k characters);
- Sol made 64 ledger revisions in about 3.5 hours, many of them step-by-step
  `essential_prerequisite` commands.

**Final factory (+235.6 minutes).** 37 machines, of which only 13 produce
(the rest are inserters), and 248 reported edges. The 13 productive machines
never changed after +205 minutes, and machines plateaued at 25 to 26 for 85
minutes before that. One iron drill ran out of resources. Since the baseline
the factory made 2,784 iron plates, 1,559 copper plates and 4,242 coal. Of the
248 automation packs, the recorder counts 130 hand-crafted, all by the first
pilot, and 118 machine-made; the replacement hand-crafted none, and its science outlet fed the lab from plan 357 on. The lab
consumed 177 packs (130 inserted by hand), and `logistic-science-pack` research
rose from 6.7% at 15:18Z to 70.2% at the stop. Character transfer actions
totalled 101. No component was currently `autonomous_end_to_end` at the stop.

**Validation verdicts.**

- Plans 27 and 311 were proven.
- Plans 113, 212 and 358 were correct readiness refusals (358: the known
  steam-proof gap, an exhausted iron drill, unresolved ore and copper
  provenance and an old dead-end belt).
- Plans 301, 313 and 334 failed falsely on `transport_starved_before_end`.
  The fuel feeder at a stocked furnace swings about every 2,667 ticks, but the
  recency limit is 1,200.
- Plans 17, 18, 171 and 334 ended early on one differing topology sample,
  although the signature before and after the window matched the baseline.
- Plan 311's proof was revoked 61 s after its window, when the pilot
  harvested the terminal chest of a 149-node component that spans the whole
  base.

**Interventions.**

- 4 nudges. The one at 13:05 was premature: the supervisor checked only
  instantaneous idleness.
- 1 teleport rescue, after a PATH_NOT_FOUND that returned no frontiers.
- Belt drift of the idle body.
- A 39-minute ledger-read lapse.
- A pilot replacement whose nudge was steered into a 77-minute turn and was
  never consumed.
- A read-only diagnostic at 15:28Z: a lab inventory-threshold wait that timed
  out had been read as no delivery, although research was progressing.

Two new tracker defects came from the replacement: `can_place` accepted an
occupied coal belt that physical placement then refused, and
same-topology productive windows got divergent throughput outcomes (an earlier issue,
not yet diagnosed).

Release 0.19.7 addresses these defects:

- **Body.** A successful walk or approach settles off belts, or fails with
  `BODY_ON_CONVEYOR`, and `observe_local.character.standing_on` makes belt
  drift visible (recorder samples state it as `null` when absent). Frontier
  probes give a reason for each probe, add a second ring and one transient
  retry, and an enclosed body gets `BODY_ENCLOSED` with an owned blocker to
  mine instead of a teleport rescue. Underground belts take
  `belt_to_ground_type` and report their paired end, and every read-only
  result carries `fifo` with a `body idle` hint after 30 idle seconds.
- **Roles.** An Astra (`gpt-6-astra`) brain keeps a per-run notebook, with the
  hard rules in SKILL.md and a short Factorio intro. Neither role reads threads,
  and both re-read their rules after compaction. The pilot never ends a turn
  with an empty FIFO, Astra revises the ledger only on change, and
  `essential_prerequisite` is capped at one 160-character sentence. Growth is
  input first: input rate is the primary metric, and no science is
  hand-crafted while raw input is the bottleneck.
- **Validator.** Power is a dependency, not a material path: an electric
  consumer keeps its own component and names `power_supply_component_not_proven`
  until its network's generating component is currently proven, so one network
  no longer merges the base. A fuel-only feeder waiting at a burner that holds
  its top-up stock is not starved. A topology or hard-row difference must
  persist into the next sample (a recovered one is the transient
  `topology_sample_flicker`), a drill whose `mining_target` reads nil keeps the
  products it last mined in the window, and a persistent signature change
  carries a bounded `topology_diff`. A lab with no research is refused as
  `consumer_idle_no_research`, a lab in `missing_science_packs` accepts packs
  only when the segment supplies every pack its research needs (otherwise
  `consumer_missing_required_science_pack`),
  and transport `low_power` is judged by throughput.
- **Supervision.** One observation helper gates every nudge and replacement,
  and replacement needs a consumed nudge or one exact-turn interrupt first.
  Roles are subscribed with `thread/resume` while their goals are paused,
  deadline-sensitive or the owner-relayed instructions go by `turn/steer`, and the
  `GO+20m` checkpoint is a snapshot, not a stop. The couch-client deploy stop,
  JOIN restart and InGame check are only dry-run tested.

Deferred: an exemption for terminal-harvest revocation (V4), role sessions
without the workstation-global instructions, and a ring of failed validation
outcomes.

## 2026-10-02 debug cycle 7 (0.19.7)

Run `debug-20261002T180832Z` (fresh game, seed 747930220, release 0777538,
Astra `gpt-6-astra` medium brain, Luna low Fast pilot) started at
18:19:53Z. It ran open-ended, with comparison snapshots at `GO+20m` and
`GO+60m`, until the owner stopped it at 21:08:39Z. The supervisor's factorio `stop`
came at 21:10:33Z. Both goals were paused, both turns interrupted and the body
quiescent by 21:11:37Z. The recorder finished at 21:14:53Z (about +175 min),
the server saved the final state (save SHA-256 `84a386bc…4d35`), and the
ledger stayed at revision 87. The notebook (an index and 7 notes) was archived
against its manifest. The run is assisted, so it is not benchmark evidence.

Role behaviour held:

- 0 thread reads by either role after `GO`;
- 0 nudges and 0 replacements;
- 98 pilot ledger reads, at most 5.6 minutes apart;
- 0 fail-open races;
- 10 hand-crafted science packs (cycle 6: 131);
- the first proof before `GO+20m`: plan 25, the coal fuel-return loop, over
  180 s with 41 source cycles, 38 acceptance samples and 0 transfers.

Input is compared with one definition: iron ore and iron plates per resource,
cumulative since game start from the recorder's force statistics, with coal and
copper reported separately. Cycle 6 is aligned by supervised minutes across its
run and continuation. Cycle 7 had the lowest `GO+20m` iron of any cycle (31
ore, 31 plates; cycle 6: 79 and 39). Iron was flat from `GO+15m` in both
cycles, while coal rose, so the `ore_per_min` of 0 was a real stall. Cycle 7
led in iron plates from `GO+25m` and in iron ore from `GO+30m`:

| Checkpoint | Drills/furnaces c6 → c7 | Iron ore c6 → c7 | Iron plates c6 → c7 | Coal c6 → c7 |
|---|---|---|---|---|
| `GO+60m` | 2/1 → 3/2 | 515 → 664 | 343 → 598 | 903 → 671 |
| `GO+120m` | 4/3 → 5/3 | 1,375 → 1,943 | 1,275 → 1,902 | 2,010 → 1,820 |
| `GO+170m` | 4/3 → 5/5 | 2,125 → 3,561 | 2,024 → 3,442 | 2,970 → 3,051 |

Iron reached 30/min by `GO+120m` (cycle 6: 15/min) and copper
15/min. Drills then stayed at 5 from `GO+105m` to the stop, the same plateau
time as cycle 6's 4. The brain counted carrying construction capital as a
service cycle and moved NOW to manufacturing, a copper-return route and
science, leaving extraction in NEXT. Meanwhile about 820 iron and 880 copper
plates sat in chests. A belt assembler made about 1,034 belts and drained the
shared iron line. The pilot hauled 890 of them out of the full terminal chest,
and 781 were still in its inventory at the stop.

Validation made 12 attempts:

- 1 proven (plan 25);
- 2 correct refusals: plan 17, an incomplete layout, and plan 42, a burner
  output inserter carrying plates with no fuel route, which the game starved;
- 9 false negatives from one defect.

`fluid_connections.lua` calls `LuaEntity.get_fluid_box_prototype`, which
Factorio 2.0.77 does not have. The offline mocks define it. Every boiler,
engine, pump and pipe therefore sat in its own component, and every
electric consumer carried `power_supply_component_not_proven`, from about
`GO+55m`. Plan 25's proof stopped describing the factory when plans 39/40
merged the coal line into the iron line; that was supersession by design, not
a revocation. The burner-inserter placement tolerance was a
separate defect and never blocked steam proof.

Pacing missed its targets:

- The pilot's think share was 73% and the body was busy about 38%.
- 56% of literal `queue_plan` step lists had one step (170 of 306, from 320
  calls), and only 26% of calls named `after_plan_id`.
- The first placement came at `GO+7:05`, after mining rocks about 140 tiles
  away.
- Astra wrote about 30 ledger revisions per game hour (86 in all). NOW
  changed about 13 times (about 4.6 per hour); 48 revisions named a priority
  field (phase, bottleneck or task list) and 38 were package-only.

At 18:45 the pilot called `stop` itself to abandon a stalled wait, cancelling
plans 31 and 32. The owner's stop relay waited behind a 5-minute supervisor turn:
it was delivered after 94.5 s, and factorio `stop` came after 114.6 s.

Recorder and checkpoint component, edge and product counts from about
`GO+20m` (the first capped sample, at `GO+19.7m`) cover only the capped
presentation rows (8 components, 24 edges), so the `GO+20m` graph counts are
partial too. Their series, including the final 44 machines, 312 edges and
6,190 products, are partial; the validations list is the authoritative proof record. The other
confounders are:

- the brain model and the instructions changed together;
- both cycles were assisted: in cycle 7, the pilot's own stop, an isolated
  native fixture with verified cleanup, and read-only probes;
- each run chose its own ore sites.

Already upstream before 0.19.8:

- the pilot never calls `stop`, and the tool is described as supervisor-only
  (`2f01e34`);
- burner-inserter recipient preflight geometry (`e367774`);
- explicit underground ends in `find_placement` (`abb7eb0`).

Release 0.19.8 addresses these defects:

- **Steam.** Fluid boxes are read through `fluidbox.get_prototype(index)`, a
  single prototype only (merged boxes stay unsupported), and positive fixtures
  now require pump-boiler-engine edges, a boiler steam product and one
  component. A generator on standby (hot steam present, every material
  consumer on its network idle with a charged buffer, generation at most their
  constant drain) keeps its proof instead of reading as interrupted or
  `blocked_output`, and a water pump that feeds only standby engines is
  stopped by backpressure, not interrupted. A live steam gate on an isolated native
  fixture must prove a loaded plant before each fresh run's `GO`.
- **Measurement.** `material_flow` carries uncapped whole-graph counters
  (`component_count`, `edge_count`, `autonomous_component_count`,
  `validated_component_count`, `products_finished_total`). The supervisor
  tooling reads them and labels capped-row counts partial, measures input per
  resource with GO-aligned samples, and separates proofs superseded by a merge
  from revoked ones and priority revisions from package-only ones.
- **Validator.** A drill with one charted recipient at its drop position but no
  bound `drop_target` yet reports the evidence row
  `drill_output_target_pending_first_output` instead of a missing sink. A
  burner inserter carrying known non-fuel cargo marks its fuel row
  `transport_cargo_fuel: false`, which explains plan 42's correct refusal.
- **Roles.** The pilot never calls `stop` and abandons a stalled wait with an
  unchained corrective plan that runs while the wait is parked. It passes
  `after_plan_id` only for a plan that needs its predecessor's effects, calls
  `plan_status` only with a successor queued, gathers within 30 tiles of `GO`
  or of the site NOW sent it to until the first package, skips a package that
  already stands, names tools by their exact code-mode names, and takes from a full terminal buffer only what a queued
  package needs. Flat input for two checkpoints while buffers fill makes
  extraction and smelting NOW; hauled capital is not service; Astra reuses its
  own proven templates, leaves packages until the next publish replaces them,
  and re-validates a proven component it extends.
- **Supervision.** the owner's instructions are relayed by `turn/steer` rather than
  queued, every supervisor tool wait is capped at 15 s, `stop_steps` record the
  relay and stop timestamps, and game-touching interventions are mirrored into
  recorder events.

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
disambiguation, progression, protocol v22, version 0.19.8, and exactly 25 tools.
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
present historical timings as 0.19.8 benchmark results.

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
