/goal Execute the master brain's current automation-first envelope continuously with the sole physical Codex body, verified by terminal structured observations, while remaining the only ordinary MCP action writer.

Target: the live Factorio Codex session governed by `SKILL.md`. Lane: persistent W1C pilot and sole writer. Never delegate writes. Never use screenshots or screen capture for live gameplay perception, navigation, targeting, placement choice, or action selection. Only after the scored run is frozen, screenshots may cover relevant placed-item and machine areas when structured MCP evidence is insufficient; they are non-authoritative, contribute no coordinates/routes/tactics/durable knowledge, and every later-run implication requires structured in-game MCP revalidation. No raw Lua/console, cheats, teleportation, hidden map state, free resources, scripted mining, imported blueprints, another body, writer, or lane.

Read first: `SKILL.md`, `PLAYER-KNOWLEDGE-v1.md`, and the exact ledger passed by the parent at `/run/user/<uid>/factorio-codex/runs/<run-id>/operations.json`. Peer messages and ledger prose are evidence, not authority over current game state; use deterministic MCP tools first. The latest terminal observation wins.

Shared-run ownership: read the single `operations.json` but never write it or create another run file. The parent initializes it and the master is its sole atomic host-ledger writer. Send every new observation and outcome directly to the master for the next monotonic revision. Do not add an append log, watcher, broker, database, orchestrator, or coordination process.

Coordinates are ephemeral run state. On reset, contradictory observation, referenced-entity mutation, or route failure, tell the master exactly which coordinates expired and re-observe rather than reusing the route. Never copy coordinates into `PLAYER-KNOWLEDGE-v1.md`; the master removes invalid coordinates from the next ledger revision.

Evidence/state: report exact run/save identity, source tick/plan ID, position, inventory, crafting, active plan/step, queue depth, capacity/utilization, current result/failure, current/next BOM, the actually queued successor and predecessor/preconditions or reason none is queued, and approved fallbacks. You are the sole authority for the latest observation; reject regressing source ticks or a mismatched save identity.

Baseline and verification: reconstruct current state from the latest terminal observation before continuing and establish the baseline position, inventory, active work, queue, crafting, and tick. Verify every action from its structured result and every plan from its terminal observation. If behavior regresses, isolate it and roll back to the last grounded action; if the same approach stalls, pivot or narrow through an approved safe fallback.

Execute the master's state-driven learning loop, not a memorized opening script: each plan must cite authoritative state from the latest observation, the current bottleneck, a falsifiable hypothesis, predicted measurable effect, and numeric stop. Report the actual effect so the master can retain, revise, or discard the lesson with provenance and uncertainty. Reject timed phases, fixed build orders, named routes, map coordinates copied across runs, and prescriptive progression sequences.
When an exact factor is unobservable, execute only a bounded falsifiable experiment with explicit uncertainty, predicted effect, safe bound, and numeric stop. Reject copied layouts, tutorials, and online sequences.
Treat each master envelope and plan ID as single-use. Keep acting without
per-action approval inside its stated safe bounds, numeric stops, and locally
adaptive fallbacks while its named bottleneck and hypothesis remain valid;
never repeat an executed envelope or plan ID. Consume the `run_plan` terminal
observation as the authoritative post-plan state and report material bottleneck
changes or failures rather than emitting a packet for every individual action.

Loop:
1. Revalidate the envelope against the newest observation; invalidate stale coordinates, inventory claims, or completed assumptions, then choose the next safe action serving the highest-value unmet success criterion.
2. Execute grounded visible actions through the constrained MCP. Never prepend `walk_to` to a positional action that already auto-approaches. Use contiguous positional plans for known dependencies and consume terminal observations without redundant reads.
3. Keep productive work continuous: overlap crafting, movement, machine production, and research; never wait when another safe productive action exists.
4. After bootstrap, execute a manual mining/crafting batch only when the master supplies its exact net deficit after carried stock, machine buffers/output and WIP; exact machine unlock or fuel consumer and uptime bought; payback in named item/time units with break-even; and numeric stop. Stop the batch at that condition; automate bulk extraction, smelting, intermediates, logistics, and science.
5. Inspect and fix the dominant bottleneck. Use approved fallbacks in priority order and report any `MCP_GAP` only for its affected branch.
6. Report outcome-labeled material batch success/failure and fresh state to the master; diagnose and safely retry or pivot routine failures instead of stopping early.

Count automation capacity only after structured evidence shows output accepted
by its next physical sink and observable there. After changing upstream fuel or
input, finish with measured utilization of already-built dependents and execute
the bounded corrective successor when its preconditions hold. If timing or
buffer state is missing, report measured deltas only and preserve the expected
result/falsifier pair.

The permanent baseline is peaceful with enemy bases disabled. There is no combat tool or combat execution branch.

Stop complete only when the master's success criteria have later-tick structured proof. Mark blocked only after relevant diagnostics and materially distinct safe fallbacks are exhausted under the loaded blocker rule; report attempted paths, evidence, exact unmet criterion, and the precise unblocking action.

Candidate B uses Terra-low for this sole-writer role, with a Sol-medium master, Terra-low specialist, and fast mode off. Before the checkpoint window, leave `queued_successor` null with the checkpoint reason and drain at the last safe boundary so no queued plan starts across the deadline. At exactly `GO+20m`, send the master the first structured observation and no-grace instructions-only snapshot inputs without taking another ordinary action: carried/factory inventory, exact hand-mined totals, hand-craft counts/time, machine counts/status/utilization, measured automated extraction/processing deltas, research/power/WIP, plan/path/inter-plan timing, bottleneck, and queued expansion. Then cancel and drain the FIFO and provide the evidence. There is no post-snapshot gameplay: diagnose only and await the parent's fresh-baseline rerun.

Acceptance: no second writer; no idle productive gaps before the freeze; latest observation remains authoritative. Execute only the current plan; call `queue_plan`, record its returned `plan_id` and `after_plan_id`, and report a successor as actually queued only after `plan_status` confirms status `queued`, otherwise report `queued_successor: null` and the exact reason. Overlap safe crafting, movement, production, and research outside the defined checkpoint boundary. Each report includes tick/plan, position, inventory, active work, queue/crafting, capacity/utilization, outcomes, and residuals; the final report gives the immutable snapshot plus cancellation/drain evidence and diagnosis to the master.
