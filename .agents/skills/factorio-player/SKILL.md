---
name: factorio-player
description: Operate the live Factorio Codex character through the constrained MCP surface when assigned a bounded gameplay milestone.
---

# Factorio player

Use only for live play of the one physical character named Codex.

Until the owner explicitly re-enables benchmarking, the parent starts a supervised
debug run. The parent is the debug supervisor and may use screenshots, raw
Factorio/RCON or console access, direct movement or teleport recovery,
save/source changes, and server/client restart or replacement for observation,
diagnosis, and rescue. Record each intervention and invalidate affected stale
state. Assisted progress and timing are never benchmark evidence. Gameplay
roles retain every restriction below and do not inherit this authority; after
an intervention, the pilot obtains fresh authoritative MCP state before acting.

For the active two-role topology, the parent starts exactly two persistent
conversations and pastes one adjacent prompt into each:

- [Sol-medium strategist](GOAL-STRATEGIST-v1.md), read/advice-only and sole
  operations-ledger writer; and
- [sole pilot](GOAL-PILOT-v1.md), the only ordinary MCP action writer, using
  the unchanged Terra-low single-pilot baseline with fast mode off.

The parent identifies the shared milestone and communication route, confirms
that only the pilot has Factorio MCP access or invokes gameplay tools, and lets
the strategist issue the first operations-ledger revision. The strategist offers
one coordinate-free advisory proposal from pilot reports, the ledger, and repo
knowledge only; the pilot alone owns the learning loop, calculations, success,
local plans, fallbacks, current plan plus successor, and execution from current
structured state.

## Shared-run contract

For each run, the parent creates a fresh run ID and exactly one ephemeral
ledger at `/run/user/<uid>/factorio-codex/runs/<run-id>/operations.json`, then
passes that exact path verbatim to every role. The parent creates the run
directory with mode `0700` and initializes the file with mode `0600`; after
initialization, the strategist is the sole host-ledger writer. The strategist rewrites
`operations.json` atomically through an adjacent temporary file and rename.
The pilot does not block startup on the ledger: it attempts one startup read and
thereafter reads at most one proposal only at a natural decision boundary under
the bounded single-use rules below. It never reads the ledger per MCP call.
A silent, unavailable, late, malformed, stale, duplicate, wrong-run, or wrong-save
proposal/channel/ledger/message is discarded once without acknowledgement,
resend, or debate. Its failure never pauses or gates gameplay; the pilot keeps
autonomous current-plus-successor work running from latest MCP state and sends
only material updates when the advisory route is available. Do
not create another run file, append log, watcher, broker, service, database,
or coordination process.

The ledger contains a schema version, run/save identity, monotonic revision,
source tick, phase and success, latest pilot observation,
capacity and utilization, current plan, and exactly one actually queued
successor with predecessor and preconditions—or an explicit reason that no
successor is queued. `current_plan` and `queued_successor` mirror pilot-reported
MCP facts only; they never describe strategist commands or proposals. Reject or replace stale state when revision, source tick,
or save identity regresses or disagrees with live structured state. The pilot
is the sole ordinary MCP writer and authority for the latest observation; the
strategist alone converts its report into the next atomic ledger revision.
The strategist coalesces superseded reports for the same run by newest source tick
and writes one revision for the current decision, not one revision per stale
report. If the strategist restarts, it rebuilds entirely from the ledger without
pausing the pilot or requesting replay. A plan ID executes at most once. Immediately after one
authoritative preflight diagnostic packet, the strategist writes the first
coordinate-free `strategy_proposal` and ledger revision, sends the proposal,
and ends its turn so new pilot evidence can trigger a fresh decision turn. It does not
repeat equivalent diagnostics unless action, contradiction, or staleness
changes the evidence.

The exact top-level keys are `schema_version`, `run`, `revision`, `source_tick`,
`phase`, `success`, `capacity`, `utilization`, `bottleneck`, `current_plan`,
`queued_successor`, `fallbacks`, `current_bom`, `next_bom`,
`latest_observation`, `decisions`, `strategy_proposal`, `invalidations`, and
`outcome`. The `outcome` object owns debug timing, supervisor interventions and
reasons, diagnosis, milestone evidence, and elapsed wall/game time. Historical
Candidate B timing and snapshot fields apply only when the owner explicitly starts
a benchmark run.
Parent-owned immutable `run` metadata contains `id`, `release_sha`,
`baseline_save_sha256`, `save_identity`, `created_at`, and the two role
model/effort assignments. The parent writes revision `0` with both
`source_tick` and `latest_observation` set to `null`, then relinquishes the
file. Every strategist rewrite preserves `run` byte-for-byte, is exactly prior
revision plus one, uses a `0600` adjacent temporary file, atomically renames it,
and verifies the final file is still `0600`. After the first pilot observation,
`source_tick` never decreases and equals `latest_observation.source_tick`; a
reset, tick rollback, or save identity mismatch requires a fresh parent-created
run ID and ledger rather than an in-place reconciliation.

`strategy_proposal` contains `run`, `save_identity`, `revision`, `source_tick`,
`proposal_id`, `objective`, `bottleneck`, `falsifiable_hypothesis`,
`expected_measurable_effect`, `assumptions`, `preconditions`, `safe_bounds`,
`numeric_stop`, `invalidation`, `confidence`, and optional `next_objective`.
It is coordinate-free, non-executable advice. There is at most one unique,
single-use proposal per source tick; never replace or resend it for that tick.

Coordinates are ephemeral run state only. Remove affected coordinates from the
ledger on a game reset, contradictory observation, referenced-entity mutation,
or route failure, and never copy them to durable player knowledge. Use the
pilot's deterministic MCP state and tool results before the ledger or prose. Carry only
the grounded current plan and one queued successor; invalidate stale state and
keep safe productive work overlapping.

The pilot owns every strategic choice and follows the same state-driven learning loop: observe
authoritative state; identify the current bottleneck; form a falsifiable hypothesis;
predict one measurable effect; choose a safe action; compare the
predicted and actual results; then retain, revise, or discard the lesson with
provenance and uncertainty. This is not an opening script: never encode a timed
phase, fixed build order, named route, map coordinate, or prescriptive
progression sequence. The 20-minute point measures the resulting play and does
not choose its strategy.
When an exact factor is not observable, a bounded falsifiable experiment is
allowed: state the uncertainty, predicted measurable effect, safe bound, and
numeric stop before acting. Never substitute copied layouts, tutorials, or
online sequences for live evidence.
Each `strategy_proposal` is bound to its run/save, ledger revision, source tick,
and unique proposal ID. It states an objective, bottleneck, falsifiable
hypothesis, expected measurable effect, assumptions/preconditions, safe bounds,
numeric stop, invalidation, confidence, and optional next objective. It is not
an executable envelope, exact-coordinate command, approval, gate, plan enqueue,
acknowledgement, resend protocol, or debate. The pilot reads at most one proposal
for a source tick only at a natural decision boundary, revalidates save identity and
every precondition exactly once against the latest MCP state, then accepts or
discards it permanently. The pilot reports only material bottleneck, technology,
production, or expansion changes, or a repeated distinct failure; consumes the
`run_plan` terminal observation; and never repeats an executed plan ID. It never stops or hands off
merely because one useful item or incidental non-production loot was obtained;
validated automation utilization, the current plan, and its grounded successor
remain the priority. The strategist may only propose coordinate-free calculations
as advisory estimates. The pilot owns phase and success interpretation for
gameplay, all action and fallback decisions, the current plan, and the grounded
successor. The strategist never owns batch authorization, success, completion
criteria, or successor planning/control. A proposal may
flag a material-flow contradiction; the pilot distinguishes the game bottleneck
from an MCP observability gap and decides what to do.

At `GO`, after sending the authoritative initial observation, the pilot
immediately uses its bootstrap
policy for bounded safe physical work selected from current state: prefer
already-carried automation against a verified visible resource and exact
physical sink; otherwise scout a visible dry waypoint or gather only the nearest
measured blocker with a numeric stop. It never waits for the strategist, a
proposal, or a ledger read/write. This overlaps reasoning with
physical work through the same sole writer/body/lane and encodes no fixed item,
resource, order, coordinate, route, or timed phase. The strategist consumes the
pilot's initial report instead of accessing Factorio or requesting an equivalent repeat.

Count production capacity only after pilot-reported structured evidence shows output accepted
by its next physical sink and observable there. Every pilot action sequence that changes
upstream fuel or input ends with measured utilization of already-built
dependents and one bounded corrective successor when its preconditions hold.
When timing or buffer state is missing, make rate claims only from measured
deltas and retain the expected result plus its falsifier.

A single `working` status is provisional: verify sustained end-to-end flow after at least one expected production cycle, including available input, physical transfer, downstream acceptance, and increased output. Treat stored buffers as transient until that later proof. Recalculate dependent waits and BOMs from actual accepted/produced quantities. Rank placements by useful lifetime, resource coverage, endpoint binding, and safe egress before proximity. After repeated identical path evidence without movement, stop offset roulette and use one materially distinct route or productive fallback. Maintain time-based input/fuel reserves from measured deltas, and express every diagnostic attempt as one falsifiable hypothesis, expected measurable effect, and numeric stop.

- Use exactly the active two-role topology: one Sol-medium strategist offers
  coordinate-free advisory synthesis and owns atomic ledger writes with zero Factorio MCP
  access; one persistent Terra-low pilot remains the sole Factorio MCP user,
  gameplay writer, and live-state authority.
  The pilot model/effort and fast-off setting are identical to the single-pilot
  baseline. Discard stale strategy unless the pilot revalidates it.
- Maintain the rolling operations ledger: phase and success, capacity and
  utilization, pilot-reported executing plan, one pilot-reported actually
  queued successor with predecessor
  and preconditions (or the reason none can be queued), prioritized fallbacks,
  current and next bill of materials, and source tick/plan ID.
- The pilot permanently owns the success criteria, local bottleneck, action,
  fallback decisions, current plan, and one grounded queued successor. Latest MCP state wins. It keeps work
  queued before reporting and never reads the ledger per MCP call.
- Prefer automation. After bootstrap, the pilot executes a manual mining or
  crafting batch only after independently establishing the exact net deficit
  after carried stock, machine buffers/output,
  and work in progress; the exact machine unlock or fuel consumer and uptime
  bought; a payback comparison in named item/time units with break-even; and a
  numeric stop condition. Automate bulk
  extraction, smelting, intermediates, logistics, and science; overlap crafting,
  movement, production, and research; inspect and repair the dominant
  bottleneck. Keep the current plan plus one queued successor, and never wait
  while another safe productive action exists.
- Start with `connect_status` and `observe_local`; keep movement legs bounded.
  Use only locally visible text and obey real reach, collision, inventory,
  crafting, and elapsed-time constraints.
- Batch reads and cluster travel. Direct positional actions auto-approach; never
  prepend a redundant `walk_to`, and use `walk_to` only for physical scouting or
  relocation that no following positional action already performs. Use `build_plan` for layouts,
  `queue_plan`/`plan_status` for a queued successor. Report the returned
  `plan_id` and echoed `after_plan_id` verbatim from structured results only
  after `plan_status` confirms `queued`; never reconstruct, substitute, or
  relabel either ID from memory. Use `run_plan` for
  synchronous compatibility. `inspect_entity` accepts `positions`.
- Never physically place a mining drill from a `find_placement` candidate unless
  `resource_coverage` is present and contains positive compatible coverage.
  Missing or empty coverage requires more structured observation and
  revalidation, not placement.
- The pilot may mine, refuel, collect output, repair routes, or take a safe
  fallback without waiting. Priority is: unblock production; mine the BOM
  bottleneck in batches; build validated automation; physically scout.
  Never idle on a wait while productive work exists. `mine` count means
  physical mining cycles, not guaranteed output items; derive item ceilings
  and numeric stops from the in-game learned per-cycle yield and confirm them
  with actual inventory deltas. Keep the current plan plus one grounded queued
  successor, and avoid micro-packet idle gaps while their shared bottleneck and
  hypothesis remain valid. Do not stop or report merely for one useful item or
  incidental non-production loot; prioritize measured automation utilization
  and continuous current-plus-successor execution.
- Finish every packet with an authoritative observation by consuming the
  plan's terminal observation. Observe again only
  if it is missing or became stale after another action. Report source tick and
  plan ID, position, inventory, active plan/step, queue depth, crafting, result,
  and failure. `stop` is emergency cancellation only.
- Never use screenshots or screen capture for live gameplay perception,
  navigation, targeting, placement choice, or action selection. After a scored
  run is frozen, screenshots may cover all relevant placed-item and machine
  areas only when structured MCP evidence is insufficient. They are
  non-authoritative review evidence, contribute no coordinates, routes,
  tactics, or durable knowledge, and every finding that could affect a later
  run must be revalidated through structured in-game MCP data. An `MCP_GAP`
  names the objective, missing field, current tool, why it is needed, and
  smallest structured addition. It blocks only that branch; continue other
  productive work and never guess.
- Follow [player knowledge v1](PLAYER-KNOWLEDGE-v1.md) for durable knowledge.
- The gameplay baseline is permanently peaceful with enemy bases disabled;
  there are no combat tools or combat branch to plan for.
- No second body, raw Lua/console, teleport, hidden map, free items, scripted
  mining, imported blueprints, or second RCON path. Concurrency removes thinking
  idle time, not physical walking time.
- If a newly observed gameplay difficulty appears to require greenfield code,
  first perform one bounded Firecrawl reuse survey for maintained mods,
  interfaces, or tools that own the deterministic responsibility. Evaluate
  license, maintenance, current Factorio API compatibility, one-body/one-writer/
  text-only physical fit, and cheats, hidden map state, raw console, imported
  blueprints, or tutorial sequences. Reuse or adapt the smallest maintained
  compatible path. If none fits, keep candidates only as design evidence,
  record why, and patch the smallest existing active path; do not create a
  service, gate, or report workflow.

For debug runs, keep the two-role model assignment and fast mode off unless the
parent explicitly changes them. Start from the requested peaceful save with
enemy bases disabled and continue past `GO+20m` until the assigned milestone,
an explicit the owner stop, or a genuine blocker. The supervisor may inspect or
intervene at any time, but records the intervention and requires the pilot to
reobserve before continuing. Candidate B freeze and byte-identical rerun rules
apply only when the owner explicitly starts a benchmark.

The supervisor intervenes only after the same failure survives two materially distinct safe approaches without relevant state progress, no unrelated productive branch remains, or a structured MCP defect prevents physical recovery. Record the pre-intervention tick/error/state, the smallest intervention and reason, and the first fresh post-intervention MCP observation. If a pilot `/goal` became terminal before the repair, retire that inactive conversation and start one replacement Terra-low pilot on the same run/save identity; never have two active pilots or add a third gameplay role.
