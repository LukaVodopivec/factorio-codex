import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { toolPayloads } from "../src/mcp/server.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const payload = toolPayloads.extract({ x: 1, y: 2 });
assert.deepEqual(payload, { target: { x: 1, y: 2 }, all: true });

const result = spawnSync(process.env.LUA_BIN ?? "lua5.4", [
  path.join(root, "tests/mod/extract_contract_runner.lua"),
  String(payload.target.x),
  String(payload.target.y),
  String(payload.all === true),
], {
  cwd: root,
  encoding: "utf8",
});
if (result.status !== 0) throw new Error(`Lua extract contract failed: ${result.stderr || result.stdout}`);
if (!result.stdout.includes("ok   mapped omission reaches extract.start as all=true")) {
  throw new Error(`unexpected Lua extract contract output: ${result.stdout}`);
}
console.log("PASS TypeScript omitted-extract mapping executes Lua extract.start with all=true");
