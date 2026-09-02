import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const expected = ["connect_status","observe_local","inspect_entity","describe_prototype","progression_status","can_place","walk_to","mine","place_entity","craft_items","insert_items","extract_items","set_recipe","rotate_entity","build_plan","queue_plan","plan_status","run_plan","start_research","stop"].sort();
const cwd = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entry = process.env.MCP_ENTRY ?? "src/cli.ts";
const home = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-codex-mcp-home-"));
const command = entry.endsWith(".ts") ? "npx" : "node";
const args = entry.endsWith(".ts") ? ["tsx", entry, "mcp"] : [entry, "mcp"];
const child = spawn(command, args, { cwd, stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, HOME: home } });
let buffer = "", stderr = "", next = 1;
const pending = new Map<number, (value: any) => void>();
child.stderr.on("data", (data) => { stderr += data.toString(); });
child.stdout.on("data", (data) => {
  buffer += data;
  let at;
  while ((at = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
    if (!line) continue;
    const message = JSON.parse(line); pending.get(message.id)?.(message); pending.delete(message.id);
  }
});
const request = (method: string, params?: unknown) => new Promise<any>((resolve, reject) => {
  const id = next++; pending.set(id, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  setTimeout(() => reject(new Error(`timeout: ${method}; stderr=${stderr}`)), 10000);
});

try {
  const init = await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "offline-smoke", version: "1" } });
  if (init.result?.serverInfo?.name !== "factorio-codex" || init.result?.serverInfo?.version !== "0.9.0") throw new Error(`wrong server metadata; stderr=${stderr}`);
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const tools = (await request("tools/list")).result.tools;
  const names = tools.map((tool: any) => tool.name).sort();
  if (JSON.stringify(names) !== JSON.stringify(expected)) throw new Error(`tool mismatch: ${names}`);
  if (/agent_id|companion|background|image|lua|console/i.test(JSON.stringify(tools))) throw new Error("forbidden schema/content exposed");
  const rotateSchema = tools.find((tool: any) => tool.name === "rotate_entity")?.inputSchema?.properties ?? {};
  if (!rotateSchema.direction || rotateSchema.reverse) throw new Error("rotate_entity must expose Lua direction, never reverse");
  const describeSchema = tools.find((tool: any) => tool.name === "describe_prototype")?.inputSchema?.properties ?? {};
  if (describeSchema.names?.maxItems !== 10) throw new Error("describe_prototype must match Lua's 10-name cap");
  const extractSchema = tools.find((tool: any) => tool.name === "extract_items")?.inputSchema ?? {};
  if ((extractSchema.required ?? []).includes("items")) throw new Error("extract_items must allow omitted items for all=true extraction");
  const planSchema = tools.find((tool: any) => tool.name === "build_plan")?.inputSchema?.properties ?? {};
  if (planSchema.stop_on_error?.default !== true || planSchema.steps?.maxItems !== 25) throw new Error("build_plan must default fail-fast and cap steps at 25");
  const tooManySteps = Array.from({ length: 26 }, (_, x) => ({ x, y: 0, name: "transport-belt" }));
  const rejectedPlan = await request("tools/call", { name: "build_plan", arguments: { steps: tooManySteps } });
  const rejectedText = rejectedPlan.result?.content?.[0]?.text ?? "";
  if (!rejectedPlan.result?.isError || /Offline:/.test(rejectedText)) throw new Error(`26-step plan reached runtime instead of input rejection: ${rejectedText}`);
  const mineSchema = tools.find((tool: any) => tool.name === "mine")?.inputSchema?.properties ?? {};
  if (mineSchema.count?.default !== 1 || mineSchema.count?.maximum !== 200) throw new Error("mine must expose count 1-200 default 1");
  const runPlanSchema = tools.find((tool: any) => tool.name === "run_plan")?.inputSchema ?? {};
  if (runPlanSchema.properties?.steps?.maxItems !== 25 || runPlanSchema.properties?.steps?.minItems !== 1) throw new Error("run_plan must accept 1-25 steps");
  if (runPlanSchema.properties?.final_observation_radius?.default !== 15 || runPlanSchema.properties?.observation_radius) throw new Error("run_plan must expose only final_observation_radius");
  if (/build_plan|start_research|stop|sleep|by_name/.test(JSON.stringify(runPlanSchema))) throw new Error("run_plan exposes a forbidden nested step");
  const status = await request("tools/call", { name: "connect_status", arguments: {} });
  const text = status.result?.content?.[0]?.text ?? "";
  if (!text.startsWith("Offline:") || !text.includes("factorio-codex setup")) throw new Error(`offline status not actionable: ${text}`);
  if (stderr.trim()) throw new Error(`unexpected pre-init/offline stderr: ${stderr}`);
  const queueSchema = tools.find((tool: any) => tool.name === "queue_plan")?.inputSchema?.properties ?? {};
  if (queueSchema.after_plan_id?.exclusiveMinimum !== 0 || queueSchema.observation_detail?.default !== "compact") throw new Error("queue_plan dependency/detail schema mismatch");
  console.log("PASS initialize, exact 20 tools, Lua-parity schemas, forbidden-schema scan, actionable offline status");
} finally {
  child.kill();
  fs.rmSync(home, { recursive: true, force: true });
  if (fs.existsSync(home)) throw new Error(`temporary HOME cleanup failed`);
}
