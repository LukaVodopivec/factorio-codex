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
  model loops, game-chat control, multiple controllable bodies, multi-agent
  orchestration, hosted services, teleportation of the Codex body, or free
  resources. A characterless spectator camera may follow Codex.
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

## Two-session gameplay

One Sol strategist may read and plan while one Luna pilot is the sole ordinary
MCP action writer for the single physical Codex character and task lane. Luna
receives bounded milestone packets, batches reads, selects exact visible
coordinates, uses `build_plan` for layouts and `run_plan` for two or more known
dependent steps, and completes the assigned milestone without inventing the
next strategic goal. Consume `run_plan`'s final observation; otherwise each
packet ends with `observe_local` and a report of position, inventory, active
task, result, and failure. Never use screenshots or screen capture. Missing
structured state is an `MCP_GAP`, not permission to guess.
Concurrency removes thinking idle time, not physical walking time. There is no
second body, raw Lua/console, teleport, hidden map, free resource, or second
RCON path; `stop` is emergency cancellation only.
