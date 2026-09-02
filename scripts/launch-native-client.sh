#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${XDG_STATE_HOME:-${HOME:?}/.local/state}/factorio-codex/native-client"
FACTORIO="${FACTORIO_CODEX_BINARY:-${HOME:?}/.steam/debian-installation/steamapps/common/Factorio/bin/x64/factorio}"
ADDRESS="${1:-127.0.0.1:34197}"
MODE="${2:-launch}"

if [[ ! -x "$FACTORIO" ]]; then
  echo "Factorio executable not found: $FACTORIO" >&2
  exit 1
fi

mkdir -p "$STATE_ROOT/config" "$STATE_ROOT/mods"
CONFIG_TMP="$STATE_ROOT/config/config.ini.tmp"
PLAYER_TMP="$STATE_ROOT/player-data.json.tmp"
MOD_LIST_TMP="$STATE_ROOT/mods/mod-list.json.tmp"

printf '%s\n' \
  '; factorio-codex isolated native client' \
  '[path]' \
  'read-data=__PATH__system-read-data__' \
  "write-data=$STATE_ROOT" \
  '[general]' \
  'locale=en' \
  > "$CONFIG_TMP"
mv "$CONFIG_TMP" "$STATE_ROOT/config/config.ini"

printf '%s\n' '{"service-username":"Codex"}' > "$PLAYER_TMP"
mv "$PLAYER_TMP" "$STATE_ROOT/player-data.json"
printf '%s\n' '{"mods":[{"name":"base","enabled":true},{"name":"agentic-companion","enabled":true}]}' > "$MOD_LIST_TMP"
mv "$MOD_LIST_TMP" "$STATE_ROOT/mods/mod-list.json"

bash "$ROOT/scripts/package-mod.sh" >/dev/null
cp "$ROOT/dist/agentic-companion_0.10.0.zip" "$STATE_ROOT/mods/agentic-companion_0.10.0.zip"
find "$STATE_ROOT/mods" -maxdepth 1 -type f -name 'agentic-companion_*.zip' ! -name 'agentic-companion_0.10.0.zip' -delete

if [[ "$MODE" == "--prepare-only" ]]; then
  printf 'Prepared isolated native Codex client at %s\n' "$STATE_ROOT"
  exit 0
fi
if [[ "$MODE" != "launch" ]]; then
  echo "Usage: $0 [host:port] [--prepare-only]" >&2
  exit 2
fi

exec "$FACTORIO" \
  --config "$STATE_ROOT/config/config.ini" \
  --mod-directory "$STATE_ROOT/mods" \
  --mp-connect "$ADDRESS" \
  --force-graphics-preset very-low \
  --video-memory-usage low \
  --disable-audio \
  --window-size 640x480 \
  --nogamepad
