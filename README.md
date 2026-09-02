# Factorio Codex

Current release: **0.10.0**.

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

Keep the server-and-agent workstation headless. On the couch PC, install the
full standalone Factorio build under `%LOCALAPPDATA%\factorio-codex\standalone`
and run `scripts/launch-native-client.ps1 -Address <server:port>` to connect its
isolated low-resource client as the real player named `Codex`. Then connect the
normal couch Factorio client as the characterless spectator/follower. The
native launcher rejects the Steam build because Steam replaces the isolated
LAN identity with the account identity. The Bash launcher is for an equivalent
visual Linux client host, never the dedicated server workstation.
The mod never creates a standalone fallback character. Run
`node companion/dist/cli.js doctor`, then start `codex` at this root. The
committed project config starts MCP automatically. Begin with
`connect_status`, then `observe_local`; `stop` cancels active and queued work.

The public CLI contains only `setup`, `doctor [--json]`, and `mcp`. MCP exposes
exactly 24 text-only tools through `tools/list`. `queue_plan` immediately adds
one Lua-contiguous plan to the sole FIFO; `plan_status` reads it, while
`run_plan` provides synchronous compatibility. Plans reuse the existing honest
physical runners and end with a compact or full local observation.
`find_placement` searches authoritative charted candidates,
`map_summary` summarizes only already-charted terrain and factory landmarks,
`production_requirements` performs deterministic recipe arithmetic, and
`connect_entities` builds an inventory-backed physical belt, pipe, or power
route.

Live play uses the benchmark-selected topology and model/effort assignment.
In a split topology the strategist is read/plan-only, while one persistent
pilot alone writes ordinary MCP actions for the one physical Codex body and
task lane. Bounded packets prevent strategic drift;
concurrency removes thinking idle time, not physical walking time. See the
repo-local `factorio-player` skill for the packet and reporting contract. The
pilot batches read targets, uses direct actions without a redundant `walk_to`,
uses `build_plan` for layouts, and uses `run_plan` for dependent multi-step
work. Screenshots and screen capture are never part of this text-only
interface. See [agent play performance](docs/AGENT-PLAY-PERFORMANCE.md) for the
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
