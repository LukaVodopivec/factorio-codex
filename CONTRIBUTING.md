# Contributing

Thanks for your interest in Factorio Codex. Read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first and
[AGENTS.md](AGENTS.md) for the full engineering rules.

## Development setup

- Node.js 22.12 or newer, with `npm` and `npx` on your `PATH`.
- Lua 5.4 (`lua5.4`) or TeX Live's `texlua` for the mod's Lua tests.
- `zip` and `unzip` for packaging the mod.
- Factorio 2.0 with Space Age only for live play; the offline suite does not
  need the game.

```sh
npm ci
npm run typecheck
npm run build
```

`scripts/dev-link.sh` links `mod/agentic-companion` into your local Factorio
`mods/` folder, so a client picks up mod edits on restart.

## Tests

```sh
npm test                                         # companion unit tests, Lua mod tests, mod package check
npm run test:mcp && npm run test:mcp:built -w companion   # offline MCP smoke tests (after npm run build)
```

`npm test` runs the companion's vitest suite, every `tests/mod/*_test.lua`
with `lua5.4` or `texlua` against a mock Factorio API, then a contract check
through `npx tsx` and the mod archive check. CI runs the same steps (see
`.github/workflows/ci.yml`). Changes to movement, reach, inventory, crafting,
placement or time must stay observable and covered by tests.

## Rules for new tools and instructions

**Enable thinking, never replace it.** The mod and the instructions let the
bots show their thinking; they never do it for them. A new tool may execute a
bot's decision, give honest player-visible information, or do deterministic
arithmetic. It never chooses a design, site, order, quantity or timing, and
never grants free items, energy, or uncharted or cross-run map knowledge.
Instructions follow the same test: rules, mechanics, tool contracts and
principles with their reasons; never build, research or planet orders, opening
scripts, fixed counts, layouts or coordinates. If a tool or passage lets a bot
act well without deciding what, where, when or how many, it is doing the
thinking. See the full rule in [AGENTS.md](AGENTS.md).

Deterministic work (monitoring, supply, recoveries, layout arithmetic, upkeep)
belongs in the mod as a tool, not in the bots' instructions.

**Performance.** The server holds 60 UPS:

- No RPC or `on_tick` work may take more than about 8 ms of Lua time in one
  tick. Lua has no clock, so every handler processes a fixed number of work
  items per tick and spreads the rest across ticks as a job.
- Nothing scans the whole surface. Use the event-maintained entity registry
  and charted, bounded areas.

**Boundaries.** Never expose images, raw Lua, arbitrary console commands,
credentials or uncharted terrain through MCP, and never teleport the Codex body.
Mod actions never use the cursor, open a GUI, or pass the player to
`set_tiles`, `put`, `take` or `copy_settings`, since that would start a human
takeover hold or fill the human player's undo queue. Keep one active path:
Codex MCP to the RCON bridge to the mod.

## Issues and pull requests

- Open an issue for bugs and proposals. For a bug, include the Factorio and
  companion versions (`factorio-codex doctor --json`), what the bot or tool
  did, what you expected, and the relevant `activity_log` rows or server log
  lines. Remove personal data, passwords and RCON secrets first.
- Keep pull requests small and focused, with tests for changed behavior, and
  run `npm test` before opening one. Use Conventional Commit style titles
  (`fix(walk): ...`, `feat(timelapse): ...`).
- Pull requests are reviewed by the maintainer, who decides what is merged.
