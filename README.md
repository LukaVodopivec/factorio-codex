# Factorio Codex

Current release: **0.13.9**.

Factorio Codex lets one Codex TUI control one physical character named Codex
through deterministic, text-only local perception. The only active path is the
project MCP server → serialized RCON bridge → Factorio mod. Movement, reach,
inventory, crafting, placement, research and elapsed game time remain real.

Requirements: Factorio 2.0.x, Node.js 22, and a dedicated save. The fixed
`/silent-command remote.call` bridge means Factorio disables achievements for
that save. The interface never exposes Lua, arbitrary console commands, images,
global-map state, teleportation of the Codex body or free resources. Connected
spectator cameras follow Codex without affecting its physical movement. Every
supported save is permanently peaceful with enemy bases disabled.

## Install and use

```sh
nvm use 22
npm ci
npm run build
node companion/dist/cli.js setup
```

The server-and-agent workstation has no dedicated GPU and is permanently
headless. Run only the dedicated server, Node bridge, and agent tooling there;
never start a Factorio GUI/client or any other visual GUI workload on it during
rollout, validation, or benchmarks. All visual workloads run on the couch PC.
There, install the full standalone Factorio build under
`%LOCALAPPDATA%\factorio-codex\standalone` and run the couch-only
`scripts/launch-native-client.ps1 -Address <server:port>` to connect its isolated
low-resource client as the real player named `Codex`. Then connect the separate
normal couch Factorio client as the characterless spectator/follower. The
native launcher rejects the Steam build because Steam replaces the isolated
LAN identity with the account identity. There is intentionally no Linux visual
client launcher in this repository.
The mod never creates a standalone fallback character. Run
`node companion/dist/cli.js doctor`, then start `codex` at this root. The
committed project config starts MCP automatically. Begin with
`connect_status`, then `observe_local`; `stop` cancels active and queued work.

The public CLI contains only `setup`, `doctor [--json]`, and `mcp`. MCP exposes
exactly 25 text-only tools through `tools/list`. `observe_local` exposes exact
`ground_items` stacks and `pickup_items` physically collects one still-matching
stack through the character's normal picking state. Its character record labels
the existing `inventory` as `main` and reports equipped ammunition separately.
`queue_plan` immediately adds
one Lua-contiguous plan to the sole FIFO; both calls echo the stored
`after_plan_id`, and `plan_status` retains only assigned `queued`, first
`running`, first applicable `waiting`, and one truthful final transition after its
terminal observation, even when a plan completes before its first poll, while
`run_plan` provides synchronous compatibility. Plans reuse the existing honest
physical runners and end with a compact or full local observation.
`inspect_entity` reports live inserter endpoints and targets, mining-drill output
position, recipient (explicitly `null` when unbound), and a drill-only
`drop_target_bound` boolean, current drill resource targets, furnace
fuel/input/output buffers including exact empty compartments only when the
corresponding inventory exists, and belt contents. `find_placement`
searches authoritative charted candidates, reports compatible mining-drill
resource coverage, rejects charted candidates with no compatible resources with a
deterministic count while retaining uncharted candidates with coverage omitted, and
exposes cardinal inserter pickup/drop endpoints. Output-capable candidates expose
their deterministic `output_position` and recipient, explicitly `null` for
ground output. Its existing `output_target` contract resolves the requested
recipient by exact entity position, floors the predicted or live output point
to Factorio's 1×1 output tile, and uses the entities returned for that tile—never
selection-box point containment. Physical placement retains the exact created
entity and checks its live `drop_position` geometry and runtime `drop_target`
without removing or replacing it. Exact geometry with a nil runtime target is
reported as pending first output, never as bound; a non-nil wrong target fails.
For mining-drill `build_plan` steps with starter insertion, the items are
legitimately inserted once before the step waits for first output to expose the
exact runtime recipient. Inspect the placed inserter's
`pickup_target` to falsify an incorrect source binding.
Native no-path and repeated-stall failures inspect only the immediate charted
collision segment and report stable, capped local candidate identities and
colliding tiles as inferred visible collision candidates, not authoritative
blockers (or explicitly say none was identified); they never expand or search
the map.
`map_summary` summarizes only already-charted terrain and factory landmarks,
`production_requirements` performs deterministic recipe arithmetic, and
`connect_entities` builds an inventory-backed physical belt, pipe, or power
route.
`progression_status` separates ordinary queueable research from action/trigger
unlocks, retaining item/entity quality filters and comparators, scripted trigger
descriptions, and fieldless space-platform triggers. `start_research` refuses a
trigger technology with its required in-game action and never reports it as
queued progress.

Live play uses exactly two active roles: a Sol-medium read/advice-only strategist
with zero Factorio MCP access and the unchanged Terra-low single-pilot baseline
with fast mode off. The strategist writes coordinate-free non-executable
`strategy_proposal` advice to the one ledger. The persistent pilot alone uses
Factorio MCP, writes gameplay actions, and owns live-state authority for the one
physical Codex body and task lane. It never waits for the strategist or ledger,
owns the local bottleneck/action/fallback plus current plan and one grounded
successor, reads the ledger once at startup rather than per MCP call, and reads
at most one tick-keyed proposal only at a natural boundary.
Latest MCP state wins; the pilot validates save identity and every proposal
precondition once, accepts or discards it, keeps work queued, and reports only
material changes or a repeated distinct failure. It alone authorizes manual
batches and owns the learning loop, authoritative calculations, success, plans,
fallbacks, and milestone completion from MCP proof. Strategist or ledger silence
or failure never pauses gameplay. A restarted strategist rebuilds
from the ledger without pausing play. The first rollout is the next fresh matched run; Candidate
B and R1-R7 remain historical evidence. Bounded packets prevent strategic drift;
concurrency removes thinking idle time, not physical walking time. See the
repo-local `factorio-player` skill for the packet and reporting contract. The
pilot batches read targets, uses direct actions without a redundant `walk_to`,
uses `build_plan` for layouts, and uses `run_plan` for dependent multi-step
work. Screenshots and screen capture are never part of the live text-only
interface. Non-authoritative post-run review is bounded by the player skill and
live-validation guide. See [agent play performance](docs/AGENT-PLAY-PERFORMANCE.md) for the
22-call baseline, benchmark fields, and adopted research patterns.

## Verification

```sh
npm ci && npm ls --all
npm run typecheck && npm run build && npm test
npm run test:mcp && npm run test:mcp:built -w companion
npm run package:mod
```

See [live validation](docs/LIVE-VALIDATION.md) for the Factorio-only acceptance
run and [UPSTREAM.md](UPSTREAM.md) for provenance.
