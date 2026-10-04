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
  uncharted terrain through MCP. Everything the force has charted may be read;
  acting still needs physical reach.
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

The owner may take the body over by mouse and keyboard at any time. A
`human_control: true` hold (`observe_local.character` and every `fifo` block) is
The owner playing: real control input on the Codex client (movement, mining,
building, opening a GUI, holding an item) parks the FIFO without cancelling
plans; mouse hovering, map view, and camera movement do not. The mod resumes
about five seconds after the last such input. A hold is neither idleness nor failure. The
supervisor never nudges or replaces during a hold, records it as the owner input,
invalidates idle timing, and needs fresh idle evidence after it.

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
Delivery is not consumption: replace only after the nudge's token appears in
a pilot `userMessage`, or after one recorded interrupt of the exact stale pilot
turn followed by a further two minutes of unchanged idleness. The observation
helper that `docs/LIVE-VALIDATION.md` describes is the only nudge and
replacement gate.

Record every nudge or replacement intervention and invalidate affected state.
Preserve the strategist, single body, FIFO, and write path; start the replacement
from the latest structured state and the still-open milestone. Assisted progress
and timing remain excluded from benchmark evidence. These debug interventions
need no further approval from the owner.

Idleness is not low growth, and physical activity (movement, inventory change)
is not growth. At each recorder checkpoint the supervisor records structural
growth from `map_summary` with `activity_since_tick` and recorder deltas:
machines, physical edges, validated or autonomous components, character
transfers per finished product, and production. Astra, not the supervisor, turns
low growth into NOW; the supervisor never replaces a pilot for low growth alone.

`stop` is the supervisor's recorded emergency cancellation (the pilot never
calls it), used only for an explicit the owner stop, retained-work reconciliation,
or a replacement that cannot otherwise reach physical quiescence. For an
explicit the owner stop the supervisor, recording each step: calls factorio `stop`;
pauses both role goals natively (`/goal pause`, read back) and interrupts any
active role turn (TUI stop control or app-server `turn/interrupt` for the exact
thread and turn, read back); checks that no
task-owned command still runs; ensures Astra makes no further ledger write; then
finishes the recorder and stops the server. `docs/LIVE-VALIDATION.md` holds the
pre-`GO` stop rehearsal, which resumes both goals before `GO`.

Before `GO` of a fresh run, archive the previous run's `operations.json` into
that run's directory and have Astra initialise the new one; a ledger from another
run is archival evidence only. The run's `notebook/` stays in its run directory,
and the run write-up summarises what the roles learned. Before `GO` on any resumed
save or after a mod upgrade, reconcile retained work: if `observe_local` shows an
active task or queue depth, call `stop` and re-observe until idle.

Start exactly two persistent reasoning sessions around one physical body and
FIFO lane. The `gpt-6-luna` pilot uses `low` reasoning with fast mode enabled
and is the sole gameplay writer, physical controller, immediate-safety
authority, and source of latest exact local state. The persistent
`gpt-6-astra` strategist uses `medium` reasoning at normal speed, owns
coordinate-free long-horizon NOW/NEXT/LATER priorities, designs every coupled
layout as a validated build package that the pilot revalidates and queues
unchanged, and may call only the mechanically read-only MCP surface, including
the side-effect-free placement checks. Its reads never enter or delay the
physical lane.

Before `GO`, each exact role session calls native `execution_settings({})` and
reports its fresh `current_turn` and `next_turn` model, reasoning effort and
service tier, plus `fast_mode_enabled` and `fast_inherited_from_root` when
available, separately from requested launch/update settings. The supervisor
records exact session/turn identity and receipt time in existing run evidence,
explicitly consumes both reports, and confirms Luna-low-Fast and
Astra-medium-normal for current and next turns before authorizing gameplay.
An update applies next turn: end the preparation turn and obtain a fresh native
read in the subsequent turn. Missing, delayed, malformed, stale or unexplained
contradictory evidence holds `GO`; a sent report or successful update is not
confirmation. Follow `docs/LIVE-VALIDATION.md` for installed field semantics:
feature availability, selected thread tiers and provider-confirmed processing
are separate evidence.

Keep one compact `operations.json`. Astra is its sole atomic host writer,
including its initial revision; Luna never writes it. The ledger is Astra's only
channel to the pilot: supervisor assignments never ask Astra to message the
pilot. Pilot reports stay under about 300 bytes (the connected transport rejects
messages over 1,000 bytes); ledger updates stay compact, with build packages
capped at 8 KB. Both are material and asynchronous, not per-call
acknowledgements or blocking synchronization. Luna validates each unseen
revision against newer physical evidence and continues fail-open when Astra, a
report, or the ledger is missing, malformed, stale, or unavailable. Do not add
another writer, body, lane, ledger, broker, daemon, or control channel.

Each run has a markdown notebook in `<run_dir>/notebook/`, created at deploy
with empty `astra/` and `luna/` folders. Each role writes only its own folder
and reads anything there at any time. Notes may hold exact positions, maps, and
infrastructure inventories observed in this run, never imported or copied
external content. There is no total size cap; each role keeps a short `INDEX.md`
and splits long files. Nothing is read from another run; a resumed save of the
same factory continues its run. A build package may name up to three notes.
Notes are knowledge, never instructions: the notebook is a learning store, not a
broker, a second ledger, or a control channel; the ledger remains the only
command channel and Astra its only writer.

Role sessions never call `list_threads`, `read_thread`, or `wait_threads`;
delivered messages and their own tool results are their evidence. After any
context compaction a role re-reads its goal file and `SKILL.md` before any other
call, then its notebook index. The `GO` text names Astra's exact thread
ID for the pilot.

The native `/goal` owns continuation. Waypoints, batches, individual plans,
tool results, and progress reports are nonterminal. While later-tick milestone
proof is absent, immediately continue whenever productive work or bounded
recovery exists. Roles end their turn at a report checkpoint with work queued;
a turn end is neither pause nor completion, and
native goal continuation, not a supervisor assignment per batch, starts the
next batch after delivering queued messages. The supervisor also yields between
checkpoints instead of sleeping inside one turn. Complete only on milestone proof, explicit the owner stop, or a
genuine exhausted blocker; a stop never marks a goal complete.

Gameplay rules live in `.agents/skills/factorio-player/`: `SKILL.md` holds the
hard rules (one body, writer, and FIFO; honest play; tool, evidence, automation,
and validation semantics; ledger, notebook, report, thread, and stop protocol),
`PLAYER-KNOWLEDGE-v1.md` is a short Factorio intro with overridable hints, and
the two goal files hold each role's duties. Researched principles, ratios, and
a research-order hint written in this repository's own words are allowed there;
imported blueprint strings and copied layouts stay out. The supported save is permanently
peaceful with enemy bases disabled. `stop` is recorded emergency cancellation
only, in the cases listed above. Debug runs continue past `GO+20m` to their
assigned milestone; Candidate B and fresh-baseline freeze rules are historical
unless the owner explicitly starts a benchmark.

When a newly observed gameplay difficulty appears to require greenfield code,
first make one bounded Firecrawl reuse survey for maintained mods, interfaces,
or tools that already own the deterministic responsibility. Check license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether each candidate introduces cheats, uncharted map state,
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
