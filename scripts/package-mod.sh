#!/usr/bin/env bash
# Packages the mod as dist/agentic-companion_<version>.zip.
# Factorio requires the zip's top-level folder to be named <name>_<version>.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD_SRC="$REPO_DIR/mod/agentic-companion"
INFO_JSON="$MOD_SRC/info.json"

VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INFO_JSON")"
if [ -z "$VERSION" ]; then
  echo "Could not read \"version\" from $INFO_JSON" >&2
  exit 1
fi

NAME="agentic-companion_$VERSION"
DIST_DIR="$REPO_DIR/dist"
ZIP_PATH="$DIST_DIR/$NAME.zip"


STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R "$MOD_SRC" "$STAGE_DIR/$NAME"
find "$STAGE_DIR" -name '.DS_Store' -delete

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
(cd "$STAGE_DIR" && zip -qr "$ZIP_PATH" "$NAME")

echo "Packaged $ZIP_PATH"

if [ "${1:-}" = "--verify" ]; then
  test "$VERSION" = "0.22.11"
  entries="$(unzip -Z1 "$ZIP_PATH")"
  test "$(printf '%s\n' "$entries" | sed -n '1p')" = "$NAME/"
  printf '%s\n' "$entries" | grep -Fx "$NAME/info.json" >/dev/null
  if printf '%s\n' "$entries" | grep -Ev "^$NAME/" >/dev/null; then
    echo "Archive contains a path outside $NAME/" >&2
    exit 1
  fi
  test "$(unzip -p "$ZIP_PATH" "$NAME/info.json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" = "0.22.11"
  echo "Verified $ZIP_PATH layout and version"
fi
