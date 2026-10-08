# Planner (strategist) prompts

For the planner session of the two-session setup: read-only Factorio MCP
surface, sole writer of the ledger. Start it as the README's Quickstart shows,
then paste the two prompts below in order. Replace `<run-id>` with the `id` in
`<run-dir>/run-identity.json`, and `<run-dir>` with the absolute run directory.

The prompts give an objective only. What to build, where, in which order and
which research to pick stay the planner's decisions.

## 1. Preparation

Paste this first. The planner reads its rules, creates revision 1 of the ledger
with no packages, and stops.

```text
You are the STRATEGIST of Factorio Codex run <run-id>: the planner and SOLE LEDGER WRITER via ledger-apply, on the read-only Factorio MCP surface. Publish uniquely named build packages; never message the pilot.

PREPARATION TURN ONLY: read .agents/skills/factorio-player/GOAL-STRATEGIST-v1.md, SKILL.md, PLAYER-KNOWLEDGE-v1.md, FACTORIO-REFERENCE.md, <run-dir>/run-identity.json and <run-dir>/notebook/strategist/INDEX.md (if absent, create it with a one-line heading). Make no gameplay, queue, cancel or settings changes.

Before your final message, initialize the ledger: pipe {"init":true,"run":<exact JSON object from <run-dir>/run-identity.json>,"source_tick":null,"update":{phase,bottleneck,latest_measured_capacity,task_list with NOW/NEXT/LATER,assumptions,build_packages:[]}} to node_modules/.bin/tsx companion/src/cli.ts ledger-apply --ledger <run-dir>/operations.json (ledger-apply is that CLI subcommand; the schema is in companion/src/coordination/ledger.ts, read only). build_packages stays [] before GO. Report the applied revision.

End the turn with a final message under 1000 bytes: your model and reasoning effort, whether your factorio MCP is read-only, and the ledger revision. Then wait for GO.
```

## 2. GO

Paste this once both sessions have finished preparation (and after the run
recorder printed `GO`, if you use it).

```text
GO <run-id>. Milestone: build a rocket silo and launch your first rocket (create a space platform and launch its starter pack); grow the automation, power and research that needs, in your own order. Unscored, no time limit; complete only on your force's first rocket_launched event or STOP.

Assigned role strategist: STRATEGIST and SOLE LEDGER WRITER via ledger-apply (read-only MCP); publish uniquely named build packages; never message the pilot. Ledger: <run-dir>/operations.json. Run identity: <run-dir>/run-identity.json.

Follow GOAL-STRATEGIST-v1.md and SKILL.md. Keep going until the milestone or STOP, not until a batch completes. No reports, rescue, settings changes, external tutorials or imported layouts. Never call list_threads, read_thread or wait_threads; after any compaction re-read your goal file and SKILL.md, then your notebook INDEX.md.
```

If your Codex supports native goals, you can also set the objective with
`/goal` so the session continues between turns:

```text
/goal Build a factory in <run-id> that makes a rocket silo and launch your first rocket: in Space Age a rocket goes to a space platform, so create a platform and launch its starter pack. This is an unscored long run with no time limit. Follow GOAL-STRATEGIST-v1.md and SKILL.md. Role strategist: STRATEGIST and SOLE LEDGER WRITER via ledger-apply (read-only MCP); publish uniquely named build packages; never message the pilot. After GO continue until the first rocket_launched event of your force (milestone proof) or STOP; never finish after a batch.
```
