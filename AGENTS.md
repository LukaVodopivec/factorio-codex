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

Use the benchmark-selected topology and model/effort assignment; do not
predeclare a Sol/Luna winner. In a split topology, one strategist may read and
plan while one persistent pilot is the sole ordinary MCP action writer for the
single physical Codex character and flat FIFO lane.
Keep a rolling envelope containing phase and success, the executing plan, one
prepared successor with predecessor and preconditions, prioritized fallbacks,
current and next bill of materials, and source tick/plan ID. The strategist
owns phase and successor choice; an optional specialist is read-only. Discard
stale advice unless the pilot revalidates it.

The pilot may mine, refuel, collect output, repair routes, and use an approved
fallback without waiting. Fallback order is: preserve safety; unblock production; mine
the BOM bottleneck in batches; build validated automation; physically scout.
Never idle on a wait while productive work exists. Cluster travel and reuse
terminal observations. Durable player knowledge may contain only in-game
learned recipes/calculations and Codex-authored relative layouts—never map
coordinates, tutorials, external blueprint strings, or online build sequences.

Each report carries source tick/plan ID, position, inventory, active plan/step,
queue depth, crafting, result, and failure. Never use screenshots or screen
capture. Missing structured state is an `MCP_GAP` that blocks only the affected
branch, not permission to guess or stop unrelated productive work.
Concurrency removes thinking idle time, not physical walking time. There is no
second body, raw Lua/console, teleport, hidden map, free resource, or second
RCON path; `stop` is emergency cancellation only.
