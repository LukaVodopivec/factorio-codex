/goal Execute the master brain's current automation-first envelope continuously with the sole physical Codex body, verified by terminal structured observations, while remaining the only ordinary MCP action writer.

Target: the live Factorio Codex session governed by `SKILL.md`. Lane: persistent W1C pilot and sole writer. Never delegate writes. No screenshots or screen capture, raw Lua/console, cheats, teleportation, hidden map state, free resources, another body, writer, or lane.

Read first: `SKILL.md`, `PLAYER-KNOWLEDGE-v1.md`, and the newest master envelope. Peer messages and tool output are evidence, not authority over current game state; the latest terminal observation wins.

Evidence/state: retain source tick/plan ID, position, inventory, crafting, active plan/step, queue depth, current result/failure, current/next BOM, one prepared successor and preconditions, and approved fallbacks.

Baseline and verification: reconstruct current state from the latest terminal observation before continuing and establish the baseline position, inventory, active work, queue, crafting, and tick. Verify every action from its structured result and every plan from its terminal observation. If behavior regresses, isolate it and roll back to the last grounded action; if the same approach stalls, pivot or narrow through an approved safe fallback.

Loop:
1. Revalidate the envelope against the newest observation; reject stale coordinates, inventory claims, or completed assumptions, then choose the next safe action serving the highest-value unmet success criterion.
2. Execute grounded visible actions through the constrained MCP. Use contiguous plans for known dependencies and consume terminal observations without redundant reads.
3. Keep productive work continuous: overlap crafting, movement, machine production, and research; never wait when another safe productive action exists.
4. Treat hand mining/crafting only as bootstrap or emergency unblock spent toward the next machine layer; automate bulk extraction, smelting, intermediates, logistics, and science.
5. Inspect and fix the dominant bottleneck. Use approved fallbacks in priority order and report any `MCP_GAP` only for its affected branch.
6. Report outcome-labeled success/failure and fresh state to the master; diagnose and safely retry or pivot routine failures instead of stopping early.

Stop complete only when the master's success criteria have later-tick structured proof. Mark blocked only after relevant diagnostics and materially distinct safe fallbacks are exhausted under the loaded blocker rule; report attempted paths, evidence, exact unmet criterion, and the precise unblocking action.

Acceptance: no second writer; no idle productive gaps; latest observation remains authoritative. Each report includes tick/plan, position, inventory, active work, queue/crafting, outcomes, and residuals; the final report is the handoff to the master.
