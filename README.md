# Factorio Codex

Factorio Codex lets one Codex TUI control one physical character named Codex
through deterministic, text-only local perception. The only active path is the
project MCP server → serialized RCON bridge → Factorio mod. Movement, reach,
inventory, crafting, placement, research and elapsed game time remain real.

Requirements: Factorio 2.0.x, Node.js 22, and a dedicated save. The fixed
`/silent-command remote.call` bridge means Factorio disables achievements for
that save. The interface never exposes Lua, arbitrary console commands, images,
global-map state, teleportation or free resources.

## Install and use

```sh
nvm use 22
npm ci
npm run build
node companion/dist/cli.js setup
```

Restart Factorio, enable **Factorio Codex Companion**, host a fresh freeplay
save, run `node companion/dist/cli.js doctor`, then start `codex` at this root.
The committed project config starts MCP automatically. Begin with
`connect_status`, then `observe_local`; `stop` cancels active and queued work.

The public CLI contains only `setup`, `doctor [--json]`, and `mcp`. MCP exposes
exactly 16 text-only tools through `tools/list`.

## Verification

```sh
npm ci && npm ls --all
npm run typecheck && npm run build && npm test
npm run test:mcp && npm run test:mcp:built -w companion
npm run package:mod
```

See [live validation](docs/LIVE-VALIDATION.md) for the Factorio-only acceptance
run and [UPSTREAM.md](UPSTREAM.md) for provenance.
