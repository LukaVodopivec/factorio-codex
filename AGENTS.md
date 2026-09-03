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
Keep one ephemeral `operations.json` ledger containing phase and success,
capacity/utilization, the executing plan, one `plan_status`-confirmed queued
successor with predecessor and preconditions (or the reason none is queued),
prioritized fallbacks, current and next bill of materials, and source tick/plan
ID. The master is its sole atomic host writer; the pilot is the sole ordinary
MCP writer and latest-observation authority; an optional specialist is
read-only. Discard stale advice unless the pilot revalidates it.
Immediately after one authoritative preflight packet, the master writes and
sends a broad state-grounded first physical envelope, then ends its turn so new
pilot or specialist evidence can trigger a fresh turn.

The pilot may mine, refuel, collect output, repair routes, and use an approved
fallback without waiting. Broad envelopes remain active while their named
bottleneck and hypothesis remain valid, and the pilot reports material
bottleneck changes, terminal outcomes, or invalidations instead of narrow
micro-proofs. It never stops or reports merely for one useful item or incidental
non-production loot; measured automation utilization and continuous
current-plus-successor work dominate. After bootstrap,
manual batches require an exact net
deficit after carried stock, machine buffers/output and WIP, the exact machine
unlock or fuel consumer and uptime, automation payback in named item/time units
with break-even, and a numeric stop. Fallback order is: preserve safety; unblock production; mine the
BOM bottleneck in batches; build validated automation; physically scout.
Never idle on a wait while productive work exists. Cluster travel and reuse
terminal observations. `mine` count means physical mining cycles, not
guaranteed output items; derive item ceilings and numeric stops from the
in-game learned per-cycle yield and confirm them with actual inventory deltas.
Keep the current plan plus one grounded queued successor, and avoid
micro-packet idle gaps while their shared bottleneck and hypothesis remain
valid. Count automation capacity only after structured state
shows output accepted by its next physical sink and observable there. Upstream
fuel/input changes end with measured dependent utilization and a bounded
corrective successor when preconditions hold; rate claims without timing or
buffer evidence use measured deltas only. The specialist may proactively emit
at most one coalescible calculation memo per new ledger revision; on the first
material-flow contradiction it distinguishes a game bottleneck from an MCP
observability gap. Otherwise it idles. Durable player knowledge may contain only in-game
learned recipes/calculations and Codex-authored relative layouts—never map
coordinates, tutorials, external blueprint strings, or online build sequences.

Each report carries source tick/plan ID, position, inventory, active plan/step,
queue depth, crafting, result, and failure. Never use screenshots or screen
capture for live gameplay perception, navigation, targeting, placement choice,
or action selection. After a scored run is frozen, screenshots may cover all
relevant placed-item and machine areas only when structured MCP evidence is
insufficient. They are non-authoritative review evidence: they contribute no
coordinates, routes, tactics, or durable knowledge, and any finding that could
affect a later run must be revalidated through structured in-game MCP data.
Missing structured state is an `MCP_GAP` that blocks only the affected branch,
not permission to guess or stop unrelated productive work.
Concurrency removes thinking idle time, not physical walking time. There is no
second body, raw Lua/console, teleport, hidden map, free resource, or second
RCON path; `stop` is emergency cancellation only. At the immutable `GO+20m`
checkpoint, freeze the snapshot, cancel and drain the lane, diagnose and repair,
and permit no post-snapshot gameplay. A rerun starts only from a fresh baseline.

When a newly observed gameplay difficulty appears to require greenfield code,
first make one bounded Firecrawl reuse survey for maintained mods, interfaces,
or tools that already own the deterministic responsibility. Check license,
maintenance, current Factorio API compatibility, one-body/one-writer/text-only
physical fit, and whether each candidate introduces cheats, hidden map state,
raw console, imported blueprints, or tutorial sequences. Reuse or adapt the
smallest maintained compatible path; otherwise retain candidates only as design
evidence, record why they do not fit, and patch the smallest existing active
path. This is engineering guidance, not a service, gate, or report workflow.
