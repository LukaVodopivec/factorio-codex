# Security Policy

## Supported versions

Only the latest `main` receives security fixes. Please reproduce a report
against it before filing.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/LukaVodopivec/factorio-codex/security/advisories/new)
(the **Report a vulnerability** button on the repository's Security tab).
Please do not open a public issue, discussion, or pull request for a
suspected vulnerability.

Include the affected version or commit, the steps to reproduce, and the
impact you expect. A fix and an advisory follow once the issue is
confirmed.

## Security model

- The RCON password is generated locally by the setup wizard (random bytes,
  never a fixed default). It is stored in the companion's mode-0600
  configuration and in Factorio's `config.ini`, and `server start` passes it to
  the headless server as `--rcon-password`, so other users on the same machine
  can read it from the process list. RCON listens on `127.0.0.1` only. Nothing in this repository
  ships or needs a shared secret.
- The MCP companion exposes typed game tools only. It never exposes raw Lua,
  arbitrary console commands, images, credentials, or uncharted terrain.
- Game chat never controls the bot.

Reports that show a way around any of these boundaries are in scope.
