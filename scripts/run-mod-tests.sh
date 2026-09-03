#!/usr/bin/env bash
set -euo pipefail

if command -v lua5.4 >/dev/null 2>&1; then
  LUA_BIN=$(command -v lua5.4)
elif command -v texlua >/dev/null 2>&1; then
  LUA_BIN=$(command -v texlua)
else
  echo "mod tests require lua5.4 or the compatible texlua runner" >&2
  exit 1
fi
export LUA_BIN

for test_file in tests/mod/*_test.lua; do
  "$LUA_BIN" "$test_file"
done
npx tsx companion/test/extract-lua-contract.ts
