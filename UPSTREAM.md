# Upstream

Factorio Codex retains the Git history of Matteo Mekhail's
[Agentic-Factorio](https://github.com/matteomekhail/Agentic-Factorio) through
commit `158dee786df204cf588a3c5e5120b2dd79aab695` (package metadata: `xell`).

This downstream removes upstream's built-in model providers, game-chat
control, image perception, hostile gameplay, vehicles and trains. It retains
the serialized RCON bridge and physical Factorio mechanics behind a single
text-only Codex MCP companion, and adds its own one-body, two-session
coordination, run-local blueprints and mod-side upkeep.
