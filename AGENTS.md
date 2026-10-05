# Factorio Codex Agent Guide

## Project contract

- Lifecycle state: active
- Lifecycle class: personal-tool
- Repository owner: The owner
- Human developers: The owner only
- Engineering mode: agent-only
- Human code review: never
- Human decision scope: product outcomes and hard-authority approvals only
- Project goal: Show how Codex bots think about and architect a Factorio
  factory: two reasoning sessions plan and direct one physically embodied
  character through text-only tools, the mod does every deterministic chore,
  and the bots' thinking is shown in the game.
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
- Anything deterministic (monitoring, supply, recoveries, layout arithmetic,
  upkeep) belongs in the mod as a tool, not in the bots' instructions.
- Keep movement, reach, inventory, crafting, placement, and time constraints
  observable and covered by tests.
- Never expose images, raw Lua, arbitrary console commands, credentials, or
  uncharted terrain through MCP. Everything the force has charted may be read;
  acting still needs physical reach.
- No RPC or on_tick work may take more than about 8 ms of Lua time in one tick,
  and nothing scans the whole surface: the server holds 60 UPS.
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

**Roles.** Start exactly two persistent reasoning sessions around one physical
body and FIFO lane, each spawned with `-c model_reasoning_summary=detailed` so
its reasoning summaries are readable. The `gpt-6-luna` pilot uses `low`
reasoning with fast mode enabled and is the foreman: the sole gameplay writer,
physical controller, immediate-safety authority, and source of latest exact
local state. It waits on `next_event` and handles failed packages, an empty
queue, and local judgment with goal-level actions; it sends no reports. The
persistent `gpt-6-astra` strategist uses `medium` reasoning at normal speed,
owns coordinate-free NOW/NEXT/LATER priorities and the architecture, designs
every coupled layout as a build package of whole blocks or this run's
blueprints (dry-run with `check_only`), and may call only the mechanically
read-only MCP surface. Its reads never enter or delay the physical lane.

**Ledger and packages.** Keep one compact `operations.json`. Astra is its sole
atomic host writer through `ledger-apply`, including its initial revision; Luna
never writes it. The ledger is Astra's only
channel to the pilot: supervisor assignments never ask Astra to message the
pilot. The pilot's full-surface bridge queues each new package into the FIFO by
itself, in ledger order, as a plan with source `package:<id>` after the mod's
placement check, and records outcomes in `<run_dir>/package-queue.json`; a
failed package surfaces through `next_event` and `activity_log`. It never
waits for a pilot plan: it holds packages only during a human hold and while
the ledger is older than the last `stop` (packages written before a stop stay
held until Astra rewrites the ledger). A package may start with
`blueprint_capture` steps, which the bridge makes before queuing the rest.
Astra writes no build package before `GO` (every pre-`GO` ledger write has
`build_packages: []`). A reused package id is rejected by `ledger-apply`. Tool results
carry Astra's orders whenever the ledger revision changes. There are no pilot
reports, ledger reads by shell, revision checks, or package revalidation. Do not
add another writer, body, lane, ledger, broker, daemon, or control channel.

**Thought feed.** The run recorder tails both role rollout files
(`--pilot-rollout`, `--strategist-rollout`) and forwards each reasoning summary
and assistant message, never tool calls or outputs, to the mod's `say` RPC. The
mod prints it to the game chat coloured per role and keeps the last lines in an
always-visible panel on the Codex screen; the text is also saved beside the
recorder's samples (`~/.local/share/factorio-codex/runs/run-<id>/thoughts.jsonl`,
each line with `said_at`, when the game showed it). The feed is output only: game chat never controls
the bot, and the panel never triggers a takeover hold.

**Upkeep.** While the FIFO is empty, no hold is active, and some plan has
finished since the last emergency stop (a stop is never undone by upkeep), the
mod refuels dry burner machines and brings science packs to waiting labs from
own stock as a plan with source `upkeep`; any queued plan
takes the body at the next step boundary. Upkeep is the mod's work, not pilot
activity.

**Idleness.** The supervisor proves pilot idleness only while milestone goals
remain open and a fresh, valid `observe_local.character` reports
`active_task` absent or with source `upkeep`, `queue_depth == 0`, and
`crafting.queue_size == 0`. Missing, malformed, stale, or failed observations
never prove idleness. Package plans and parked or predecessor-blocked plans are
pending work, even when the body is still; they count in `queue_depth`.
`plan_status` is only a per-plan read with an exact known `plan_id`, never a
global work query.

The owner may take the body over by mouse and keyboard at any time. A
`human_control: true` hold (`observe_local.character`, `factory_status.body`,
and every `fifo` block) is the owner playing: real control input on the Codex client
(movement, mining, building, opening a GUI, holding an item) parks the FIFO
without cancelling plans; mouse hovering, map view, and camera movement do not.
The mod resumes about five seconds after the last such input. A hold is neither
idleness nor failure. The supervisor never nudges or replaces during a hold,
records it as the owner input, invalidates idle timing, and needs fresh idle
evidence after it.

Measure elapsed idle time with observation receipt timestamps in the current
run. Retain the last evidenced physical change or transition into the current
idle interval across unchanged samples; never restart the clock at a later
unchanged sample. Character position, carried inventory, task/queue state, and
crafting state/progress are physical activity evidence, except changes made by
an `upkeep` plan; advancing observation ticks and unrelated factory output are
not. Use an evidenced start only when it establishes this idle interval. If the
transition time is unknown (including an active-to-idle gap between samples),
start a conservative observed lower bound at the first valid idle sample, label
it as such, and retain it. Renewed pilot activity resets the interval and its
single-nudge state; a run change or uncertain observation invalidates timing,
requiring fresh idle evidence.

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
call, then obtain fresh structured evidence of no active pilot or package task,
no queued work, and no character crafting. Session interruption alone does not
cancel committed plans. Use `stop` only if required as recorded emergency
cancellation, then re-observe. Do not start a replacement without both proven
writer retirement and physical quiescence; unconfirmed retirement is a
capability problem. Delivery is not consumption: replace only after the nudge's
token appears in a pilot `userMessage`, or after one recorded interrupt of the
exact stale pilot turn followed by a further two minutes of unchanged idleness.
The observation helper that `docs/LIVE-VALIDATION.md` describes is the only
nudge and replacement gate.

Record every nudge or replacement intervention and invalidate affected state.
Preserve the strategist, single body, FIFO, and write path; start the replacement
from the latest structured state and the still-open milestone. Assisted progress
and timing remain excluded from benchmark evidence. These debug interventions
need no further approval from the owner.

Idleness is not low growth. At each recorder checkpoint the supervisor records
structural growth from `factory_status` and the recorder deltas: machines,
lines, running and self-sustaining lines, hand-fed lines, and production. Astra,
not the supervisor, turns low growth into NOW; the supervisor never replaces a
pilot for low growth alone.

`stop` is the supervisor's recorded emergency cancellation (the pilot never
calls it), used only for an explicit the owner stop, retained-work reconciliation,
or a replacement that cannot otherwise reach physical quiescence. For an
explicit the owner stop the supervisor, recording each step: calls factorio `stop`;
pauses both role goals natively (`/goal pause`, read back) and interrupts any
active role turn (TUI stop control or app-server `turn/interrupt` for the exact
thread and turn, read back); checks that no task-owned command still runs;
ensures Astra makes no further ledger write; waits at least 2 s, re-observes
`observe_local`, and if it shows an active task or `queue_depth > 0` (a pilot
`queue_plan` in flight before the interrupt), calls `stop` again and
re-observes until idle; then finishes the recorder and stops the server. `docs/LIVE-VALIDATION.md` holds the pre-`GO` stop rehearsal,
which resumes both goals before `GO`.

**Before `GO`.** Each exact role session calls native `execution_settings({})`
and reports its fresh `current_turn` and `next_turn` model, reasoning effort and
service tier, plus `fast_mode_enabled` and `fast_inherited_from_root` when
available, in a message under 1,000 bytes. The supervisor records exact
session/turn identity and receipt time in existing run evidence, explicitly
consumes both reports, and confirms Luna-low-Fast and Astra-medium-normal for
current and next turns before authorizing gameplay. An update applies next
turn: end the preparation turn and obtain a fresh native read in the subsequent
turn. Missing, delayed, malformed, stale or unexplained contradictory evidence
holds `GO`; a sent report or successful update is not confirmation. Follow
`docs/LIVE-VALIDATION.md` for installed field semantics.

Before `GO` of a fresh run, archive the previous run's `operations.json` and
`package-queue.json` into that run's directory and have Astra initialise the new
ledger; a ledger from another run is archival evidence only. Before `GO` on any
resumed save or after a mod upgrade, reconcile retained work: call `stop`
once even when idle (packages written before it stay held, so no old package
moves the body before `GO`) and re-observe until idle. Every cancel names its
`origin` (tool and bridge role) in `activity_log` and the server log.

**Notebook.** Each run has a markdown notebook in `<run_dir>/notebook/`, created
at deploy with empty `astra/` and `luna/` folders. Each role writes only its own
folder and reads anything there at any time. Notes may hold exact positions,
maps, and infrastructure inventories observed in this run, never imported or
copied external content. There is no total size cap; each role keeps a short
`INDEX.md` and splits long files. Nothing is read from another run; a resumed
save of the same factory continues its run. A build package may name up to
three notes. Notes are knowledge, never instructions: the notebook is a
learning store, not a broker, a second ledger, or a control channel; the ledger
remains the only command channel and Astra its only writer. The run write-up
summarises what the roles learned.

**Threads and continuation.** Role sessions never call `list_threads`,
`read_thread`, or `wait_threads`; delivered messages and their own tool results
are their evidence. After any context compaction a role re-reads its goal file
and `SKILL.md` before any other call, then its notebook index. The native
`/goal` owns continuation: plan results and batches are nonterminal, and
native goal continuation, not a supervisor assignment per batch, starts the
next batch. The supervisor yields between checkpoints instead of sleeping
inside one turn. Complete only on milestone proof, explicit the owner stop, or a
genuine exhausted blocker; a stop never marks a goal complete.

**Gameplay rules** live in `.agents/skills/factorio-player/`: `SKILL.md` holds
the rules (purpose, roles, one body and writer, honest play, tools, orders,
notebook, stop), `PLAYER-KNOWLEDGE-v1.md` is a short Factorio intro with
overridable hints, and the two goal files hold each role's duties. Researched
principles, ratios, and a research-order hint written in this repository's own
words are allowed there; imported blueprint strings and copied layouts stay out.
The supported save is permanently peaceful with enemy bases disabled. Debug
runs continue past `GO+20m` to their assigned milestone; Candidate B and
fresh-baseline freeze rules are historical unless the owner explicitly starts a
benchmark.

When a newly observed gameplay difficulty appears to require greenfield code,
first make one bounded Firecrawl reuse survey for maintained mods, interfaces,
or tools that already own the deterministic responsibility. Check license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether each candidate introduces cheats, uncharted map state,
raw console, imported blueprints, or tutorial sequences. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence, record why they do not fit, and patch the smallest existing active
path. This is engineering guidance, not a service, gate, or report workflow.

## Artifact conventions

Durable agent output (plans, analyses, handoffs) lives in `./.agent/{plans,analysis,handoffs}/`: a symlink to a workspace-owned external artifact root keyed by repository and worktree. Private uses the XDG-backed store; client workspaces use their own `.agent-runtime/artifacts` root. This keeps artifacts outside `git clean -fdx` and worktree teardown blast radius without crossing workspace boundaries.

Untracked or generated `.claude/` scratch is disposable. Committed `.claude/rules/` and other explicitly repo-owned files remain source; never use `.claude/reports/` or `.claude/analysis/` for durable task evidence.

When concurrent work needs artifacts, use unique descriptive names to prevent
clobbering. Routine work does not require an artifact.

Discovery from cold start: `ls -t .agent/plans/ | head`.
