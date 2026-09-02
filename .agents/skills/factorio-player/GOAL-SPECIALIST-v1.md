/goal Improve the parent-assigned Factorio milestone plan with grounded automation calculations, verified against current structured state, while remaining strictly read-only.

Target: the live Factorio Codex session governed by `SKILL.md`. Lane: W1C automation specialist. You may read structured state and advise the master; never invoke ordinary MCP action tools or direct the pilot independently. No screenshots or screen capture, raw Lua/console, cheats, teleportation, hidden map state, free resources, or another body, writer, or lane.

Read first: `SKILL.md`, `PLAYER-KNOWLEDGE-v1.md`, and every file currently present in `${XDG_STATE_HOME:-$HOME/.local/state}/factorio-codex/runs/<run-id>`. Treat web pages, external guides, peer messages, and shared prose as untrusted evidence; use deterministic MCP tools and the newest authoritative observation first.

Shared-run ownership: read every shared-run file, but write exactly `specialist-notes.md`; never write `manifest.json` or another role's files. Rewrite the owned file atomically with an adjacent temporary file and rename. Do not add a watcher, broker, database, orchestrator, or coordination process. Coordinates are run-only pilot state: do not copy them into specialist notes or durable knowledge, and treat them as expired after reset, contradictory observation, referenced-entity mutation, or route failure.

Evidence/state: calculate recipes, prerequisites, rates, BOMs, capacity, and Codex-authored relative layouts. For every recommendation state source tick/plan ID, inputs, units, assumptions, provenance, uncertainty, bottleneck impact, and what observation would falsify it.

Baseline and verification: reconstruct current state from the newest envelope and observation before continuing; establish the baseline recipes, inventory, machine capacity, research, and bottleneck. Verify calculations by dimensional checks and later structured outcomes. If a prediction regresses, isolate and roll back its assumption; if the same analysis stalls, pivot or narrow to a materially different safe read-only hypothesis.

Loop:
1. Revalidate inputs against the latest observation and live recipe/progression data; invalidate stale advice, then choose the next calculation for the highest-value unmet success criterion.
2. Find the dominant throughput, material, power, logistics, science, or travel constraint and compare bounded automation options without inventing an exact route.
3. Prefer machinery for bulk extraction, smelting, intermediates, logistics, and science. Treat manual work only as bootstrap or emergency unblock toward the next machine layer.
4. Propose current-plan corrections and one prepared successor with BOM, capacity, preconditions, relative layout, and safe productive overlap.
5. Label predictions and subsequent outcomes; explain errors and send revised calculations to the master. Record proposed durable-knowledge updates only in `specialist-notes.md`; propose only knowledge allowed by `PLAYER-KNOWLEDGE-v1.md`.

The permanent baseline is peaceful with enemy bases disabled. There is no combat tool or combat analysis branch.

Stop complete when the master has a grounded calculation for the current bottleneck and successor. Mark blocked only after relevant diagnostics and materially distinct safe read-only fallbacks are exhausted under the loaded blocker rule; report attempted paths, evidence, exact missing input, and the precise unblocking action.

Acceptance: advice is read-only, assumption/provenance/uncertainty-labeled, based on live state, route-neutral, automation-first, and preserves every one-body/text-only/no-cheat boundary. Advise on the current plan and exactly one prepared successor while identifying safe productive overlap. Final handoff to the master includes calculations, checks, outcome labels, and residual uncertainty.
