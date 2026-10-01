# Factorio Codex Agent Guide

## Project contract

- Lifecycle state: active
- Lifecycle class: personal-tool
- Repository owner: The owner
- Human developers: The owner only
- Engineering mode: agent-only
- Human code review: never
- Human decision scope: product outcomes and hard-authority approvals only
- Project goal: Let one Codex TUI control one physically embodied Factorio
  character through deterministic, text-only local perception and honest game
  mechanics.
- Non-goals: Image perception, agent-facing Lua or console execution, built-in
  model loops, game-chat control, multiple controllable bodies or gameplay
  writers, agent-owned orchestration services, hosted services, teleportation
  of the Codex body, or free resources. A characterless spectator camera may
  follow Codex.
- Replacement trigger: Retire or consolidate this repository when a simpler
  maintained native Factorio/Codex interface provides the same constrained
  behavior.

## Engineering rules

- Preserve one active path: Codex project MCP to the Node RCON bridge to the
  Factorio mod.
- Prefer deletion and the smallest repair to the retained upstream path.
- Keep movement, reach, inventory, crafting, placement, and time constraints
  observable and covered by tests.
- Never expose images, raw Lua, arbitrary console commands, credentials, or
  hidden global-map state through MCP.
- Use Node 22 and Factorio 2.0.x. Run the proportional offline suite before
  publication; live gameplay validation requires an installed Factorio game.
- Complete private-repository changes on clean, pushed `main` with exact
  remote-SHA readback.

## Persistent two-brain gameplay

Until the owner explicitly re-enables benchmarking, every new live run is supervised
debugging. The initiating session is the debug supervisor and may diagnose or
rescue through screenshots, raw Factorio/RCON or console, direct movement or
teleport recovery, save/source edits, and server/client replacement. Record each
intervention and invalidate affected state; assisted progress and timing are
never benchmark evidence. None of that authority passes to ordinary gameplay.

The supervisor proves pilot idleness only while milestone goals remain open
and a fresh, valid `observe_local.character` reports `active_task` absent,
`queue_depth == 0`, and `crafting.queue_size == 0`. Missing, malformed, stale,
or failed observations never prove idleness. Parked waiting plans and
predecessor-blocked queued plans are pending work, even when the body is still;
they count in `queue_depth`. `plan_status` is only a per-plan read with an exact
known `plan_id`, never a global work query.

Measure elapsed idle time with observation receipt timestamps in the current
run. Retain the last evidenced physical change or transition into the current
idle interval across unchanged samples; never restart the clock at a later
unchanged sample. Character position, carried inventory, task/queue state,
and crafting state/progress are physical activity evidence; advancing
observation ticks and unrelated factory output are not. Use an evidenced start
only when it establishes this idle interval. If the transition time is unknown
(including an active-to-idle gap between samples), start a conservative observed
lower bound at the first valid idle sample, label it as such, and retain it.
Renewed activity resets the interval and its single-nudge state; a run change
or uncertain observation invalidates timing, requiring fresh idle evidence.

Before `GO`, verify that this supervisor can deliver a message to the exact
pilot session with a delivery receipt and can interrupt and retire that session
with observable confirmation that it cannot resume gameplay writes. Verify the
retirement route with a disposable non-gameplay session using the same session
mechanism, and verify its availability for the exact pilot; never retire the
prepared pilot merely to test the route. Record capability evidence. If either
capability is unproven, resolve it before `GO`; no presumed fallback suffices.

After about two minutes of evidenced idle time, revalidate idleness and nudge
that pilot once per idle interval. Record confirmed delivery; failed or
uncertain delivery is a capability problem, never a successful nudge. Read back
delivery state before any retry to avoid duplicate nudges. After about five
minutes, revalidate continued idleness before replacement: interrupt and retire
the old pilot, confirm it cannot resume writes, settle any in-flight physical
call, then obtain fresh structured evidence of no active task, no queued work,
and no character crafting. Session interruption alone does not cancel committed
plans. Use `stop` only if required as recorded emergency cancellation, then
re-observe. Do not start a replacement without both proven writer retirement
and physical quiescence; unconfirmed retirement is a capability problem.

Record every nudge or replacement intervention and invalidate affected state.
Preserve the strategist, single body, FIFO, and write path; start the replacement
from the latest structured state and the still-open milestone. Assisted progress
and timing remain excluded from benchmark evidence. These debug interventions
need no further approval from the owner.

Idleness is not low growth, and physical activity (movement, inventory change)
is not growth. At each recorder checkpoint the supervisor records structural
growth from `map_summary` with `activity_since_tick` and recorder deltas:
machines, physical edges, validated or autonomous components, character
transfers per finished product, and production. Sol, not the supervisor, turns
low growth into NOW; the supervisor never replaces a pilot for low growth alone.

`stop` is recorded emergency cancellation, used only for an explicit the owner stop,
retained-work reconciliation, or a replacement that cannot otherwise reach
physical quiescence. For an explicit the owner stop the supervisor, recording each
step: calls factorio `stop`; pauses both role goals natively (`/goal pause`,
read back) and interrupts any active role turn (TUI stop control or app-server
`turn/interrupt` for the exact thread and turn, read back); checks that no
task-owned command still runs; ensures Sol makes no further ledger write; then
finishes the recorder and stops the server. `docs/LIVE-VALIDATION.md` holds the
pre-`GO` stop rehearsal, which resumes both goals before `GO`.

Before `GO` of a fresh run, archive the previous run's `operations.json` into
that run's directory and have Sol initialise the new one; a ledger from another
run is archival evidence only. Before `GO` on any resumed save or after a mod
upgrade, reconcile retained work: if `observe_local` shows an active task or
queue depth, call `stop` and re-observe until idle.

Start exactly two persistent reasoning sessions around one physical body and
FIFO lane. The `gpt-6-luna` pilot uses `low` reasoning with fast mode enabled
and is the sole gameplay writer, physical controller, immediate-safety
authority, and source of latest exact local state. The persistent
`gpt-6.1-sol` strategist uses `medium` reasoning at normal speed, owns coordinate-free long-horizon
NOW/NEXT/LATER priorities, designs every coupled layout as a validated build
package that the pilot revalidates and queues unchanged, and may call only the
mechanically read-only MCP surface, including the side-effect-free placement
checks. Its reads never enter or delay the physical lane.

Keep one compact `operations.json`. Sol is its sole atomic host writer, including
its initial revision; Luna never writes it. The ledger is Sol's only channel to
the pilot: supervisor assignments never ask Sol to message the pilot. Pilot
reports stay under about 600 bytes (the connected transport rejects messages
over 1,000 bytes); ledger updates stay compact, with build packages capped at
8 KB. Both are material and asynchronous, not per-call acknowledgements or
blocking synchronization. Luna validates each unseen
revision against newer physical evidence and continues fail-open when Sol, a
report, or the ledger is missing, malformed, stale, or unavailable. Do not add
another writer, body, lane, ledger, broker, daemon, or control channel.

The native `/goal` owns continuation. Waypoints, batches, individual plans,
tool results, and progress reports are nonterminal. While later-tick milestone
proof is absent, immediately continue whenever productive work or bounded
recovery exists. Keep the current plan and one `plan_status`-confirmed successor
when safe: `queue_plan` returns immediately, while `run_plan` and single
physical tools hold the only physical slot until they finish. Roles end their
turn at a report checkpoint with work queued; a turn end is neither pause nor
completion, and native goal continuation, not a supervisor assignment per batch,
starts the next batch after delivering queued messages. The supervisor also
yields between checkpoints instead of sleeping inside one turn. Complete only on
milestone proof, explicit the owner stop, or a genuine exhausted blocker; a stop
never marks a goal complete.

Gameplay strategy lives in `.agents/skills/factorio-player/SKILL.md`, the single
canonical growth and autonomy text. In short: at each decision boundary preserve
immediate safety and known-good capacity, resolve a hard production unblock,
then evaluate the highest-payback expansion of the measured factory bottleneck
before another manual deficit batch. Treat automation as an autonomous physical
material-flow segment, never as a placed or hand-fed machine; distinguish
`machine_present`, `locally_operating`, and `autonomous_end_to_end`, whose
downstream acceptance is a consumer or a terminal buffer with space, reported as
`downstream_kind`. Reserve loop, automation, continuous, self-running, and fully
calibrated for current `autonomous_end_to_end` evidence. Every repeated manual
bridge names its permanent physical replacement and numeric sunset.

Exactly one physical MCP call may be in flight. Parallelize only read-only
observations when inconsistent source ticks are acceptable, then revalidate the
newest state before mutation. Copy plan/predecessor IDs verbatim. `run_plan` is
sequential and nontransactional; early and partial effects remain committed
without rollback. During waits, continue independent productive work through the
same FIFO whenever available.

Coordinates and natural targets are ephemeral. Re-observe locally before
targeting entities not yet observed at a new position, and after a route
failure, selection contradiction, or partial or unexpected result; a successful
plan result with a compact observation is the post-action state. Cluster work
around fresh exact targets. On path failure, use only returned charted reachable
frontiers. Never use screenshots for gameplay, fuzzy selection, hidden map
state, raw Lua/console, teleport, free resources, imported blueprints, copied
layouts, tutorials, online sequences, fixed build orders, prescribed technology
order, named routes, map coordinates, or seed facts.

Use authoritative tool schemas and capability evidence. Confirm recipes through
`progression_status.enabled_recipes` or `describe_prototype(kind="recipe")`;
technology names are not assumed recipes. Inspect machines before `set_recipe`;
furnaces select from inserted input. An invalid schema, wrong machine, unknown
recipe, identity mismatch, or out-of-range observation is terminal for the
unchanged request: change evidence or preconditions instead of repeating it.

The supported save is permanently peaceful with enemy bases disabled. `stop` is
recorded emergency cancellation only, in the cases listed above. Debug runs continue past `GO+20m` to their assigned
milestone; Candidate B and fresh-baseline freeze rules are historical unless
The owner explicitly starts a benchmark.

When a newly observed gameplay difficulty appears to require greenfield code,
first make one bounded Firecrawl reuse survey for maintained mods, interfaces,
or tools that already own the deterministic responsibility. Check license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether each candidate introduces cheats, hidden map state,
raw console, imported blueprints, or tutorial sequences. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence, record why they do not fit, and patch the smallest existing active
path. This is engineering guidance, not a service, gate, or report workflow.

<!-- agent-artifacts-conventions -->
## Artifact conventions

Durable agent output (plans, analyses, handoffs) lives in `./.agent/{plans,analysis,handoffs}/`: a symlink to a workspace-owned external artifact root keyed by repository and worktree. Private uses the XDG-backed store; client workspaces use their own `.agent-runtime/artifacts` root. This keeps artifacts outside `git clean -fdx` and worktree teardown blast radius without crossing workspace boundaries.

Untracked or generated `.claude/` scratch is disposable. Committed `.claude/rules/` and other explicitly repo-owned files remain source; never use `.claude/reports/` or `.claude/analysis/` for durable task evidence.

When concurrent work needs artifacts, use unique descriptive names to prevent
clobbering. Routine work does not require an artifact.

Discovery from cold start: `ls -t .agent/plans/ | head`.
