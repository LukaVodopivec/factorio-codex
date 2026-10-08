// The writer fence and lost answers on the companion side: the pilot's
// process claims one writer generation and sends it with every write; a
// transport fault during a write is OUTCOME_UNKNOWN, never a silent retry,
// except queue_plan's one retry with its own client_key.
import { EventEmitter } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Bridge, ModError, OutcomeUnknownError, WriterRetiredError, type TaskClock } from "../src/bridge.js";
import { companionVersion } from "../src/config.js";
import { executeRunPlan } from "../src/mcp/runPlan.js";
import { createBridgeProvider, registerMcpTools } from "../src/mcp/server.js";
import { RconError, RconReplyLostError, type RconClient } from "../src/rcon.js";

const clock: TaskClock = { now: () => 0, sleep: async () => {} };
const validConfig = () => ({ ok: true, config: { factorioUserDir: "/factorio", rcon: { host: "127.0.0.1", port: 19015, password: "secret" } } } as const);

/** An RCON stand-in: each command's method and params, answered by reply. */
function fakeRcon(reply: (method: string, params: any) => unknown) {
  const sent: Array<{ method: string; params: any }> = [];
  const exec = vi.fn(async (command: string) => {
    const match = /remote\.call\("agentic","rpc","([a-z_]+)","(.*)"\)$/.exec(command)!;
    const params = JSON.parse(match[2]!.replace(/\\"/g, '"').replace(/\\\\/g, "\\"));
    sent.push({ method: match[1]!, params });
    const value = reply(match[1]!, params);
    if (value instanceof Error) throw value;
    return JSON.stringify(typeof value === "string" ? { ok: false, error: value } : { ok: true, data: value });
  });
  return { rcon: { exec } as unknown as RconClient, sent };
}

afterEach(() => { vi.restoreAllMocks(); });

describe("writer generation on the bridge", () => {
  it("stamps writes, never reads, once the process holds a generation", async () => {
    const { rcon, sent } = fakeRcon(() => ({}));
    const bridge = new Bridge(rcon, clock);
    await bridge.call("queue_plan", { steps: [] });
    bridge.writerGeneration = 3;
    await bridge.call("queue_plan", { steps: [] });
    await bridge.call("cancel", { all: true });
    await bridge.call("factory_status", {});
    await bridge.call("ping");
    expect(sent.map(({ method, params }) => [method, params.writer_generation])).toEqual([
      ["queue_plan", undefined], ["queue_plan", 3], ["cancel", 3], ["factory_status", undefined], ["ping", undefined]]);
  });

  it("turns the mod's WRITER_RETIRED into WriterRetiredError, not a ModError", async () => {
    const { rcon } = fakeRcon(() => "WRITER_RETIRED: writer generation 1 was replaced by generation 2");
    const error = await new Bridge(rcon, clock).call("queue_plan", { steps: [] }).catch((e) => e);
    expect(error).toBeInstanceOf(WriterRetiredError);
    expect(error).not.toBeInstanceOf(ModError);
  });
});

describe("a lost answer", () => {
  it("leaves a write's outcome unknown and a read's error as it was", async () => {
    const lost = new RconReplyLostError("RCON command timed out after 10000ms with 12 bytes of its reply received");
    const { rcon } = fakeRcon(() => lost);
    const bridge = new Bridge(rcon, clock);
    const write = await bridge.call("start_research", { technology: "automation" }).catch((e) => e);
    expect(write).toBeInstanceOf(OutcomeUnknownError);
    expect(write.message).toBe("the connection to the game failed during start_research (RCON command timed out after 10000ms"
      + " with 12 bytes of its reply received); it may or may not have run in the game");
    expect(await bridge.call("factory_status", {}).catch((e) => e)).toBe(lost);
    // A command never sent (no connection) is no unknown outcome.
    const { rcon: offline } = fakeRcon(() => new RconError("not connected — call connect() first"));
    expect(await new Bridge(offline, clock).call("queue_plan", { steps: [] }).catch((e) => e)).not.toBeInstanceOf(OutcomeUnknownError);
  });

  it("after a direct task was queued, leaves its outcome unknown", async () => {
    const { rcon } = fakeRcon((method) => method === "enqueue" ? { task_id: 5 }
      : method === "get_task" ? new RconReplyLostError("RCON connection closed") : {});
    const error = await new Bridge(rcon, clock).enqueueAndWaitResult({ type: "walk_to" } as never, { tool: "walk_to" }).catch((e) => e);
    expect(error).toBeInstanceOf(OutcomeUnknownError);
    expect(error.message).toContain("during walk_to (task 5)");
  });

  it("after a run_plan was queued and nothing more could be read, leaves its outcome unknown", async () => {
    const { rcon } = fakeRcon((method) => method === "queue_plan" ? { plan_id: 9 } : new RconReplyLostError("RCON connection closed"));
    const error = await executeRunPlan(new Bridge(rcon, clock), { steps: [{ action: "walk_to", x: 0, y: 0 }] } as never, undefined, clock).catch((e) => e);
    expect(error).toBeInstanceOf(OutcomeUnknownError);
    expect(error.message).toContain("during run_plan (plan 9)");
  });
});

describe("MCP results", () => {
  const tools = (call: (method: string, params: any) => Promise<unknown>) => {
    const handlers: Record<string, (args: unknown) => Promise<any>> = {};
    registerMcpTools({ registerTool(name, _config, handler) { handlers[name] = handler; } },
      async () => ({ call: vi.fn(call) } as unknown as Bridge), validConfig, "full", () => null, "pilot");
    return handlers;
  };
  const unknown = () => new OutcomeUnknownError("the connection to the game failed during queue_plan (RCON connection closed); it may or may not have run in the game");

  it("retries a queue_plan whose answer was lost once, with the same client_key", async () => {
    const keys: string[] = [];
    let calls = 0;
    const handlers = tools(async (_method, params) => {
      keys.push(params.client_key);
      if (++calls === 1) throw unknown();
      return { plan_id: 4, duplicate: true, tick: 100 };
    });
    const output = await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
    expect(output.structuredContent).toMatchObject({ plan_id: 4, status: "queued" });
    expect(keys).toHaveLength(2);
    expect(keys[0]).toBe(keys[1]);
    // Each call has its own key.
    calls = 0;
    await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
    expect(keys[2]).not.toBe(keys[0]);
  });

  it("reports OUTCOME_UNKNOWN, advice-free, when the retry settles nothing", async () => {
    for (const second of [unknown(), new Error("cannot connect to RCON at 127.0.0.1:19015")]) {
      let calls = 0;
      const handlers = tools(async () => { throw ++calls === 1 ? unknown() : second; });
      const output = await handlers.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] });
      expect(calls).toBe(2);
      expect(output.isError).toBe(true);
      expect(output.structuredContent).toEqual({ status: "outcome_unknown", terminal: true, code: "OUTCOME_UNKNOWN",
        summary: "the connection to the game failed during queue_plan (RCON connection closed); it may or may not have run in the game",
        next_action: null });
    }
    // The mod's own refusal on the retry is the answer.
    let calls = 0;
    const refused = tools(async () => { throw ++calls === 1 ? unknown() : new ModError("queue_plan requires 1-200 steps"); });
    expect((await refused.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] })).structuredContent)
      .toMatchObject({ status: "failed", code: "TOOL_ERROR", summary: "Error: queue_plan requires 1-200 steps" });
  });

  it("never retries another write: start_research and run_plan report OUTCOME_UNKNOWN, a retired writer WRITER_RETIRED", async () => {
    let calls = 0;
    const handlers = tools(async () => { calls++; throw unknown(); });
    expect((await handlers.start_research!({ technology: "automation" })).structuredContent).toMatchObject({ status: "outcome_unknown", code: "OUTCOME_UNKNOWN" });
    expect((await handlers.run_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] })).structuredContent).toMatchObject({ status: "outcome_unknown", code: "OUTCOME_UNKNOWN" });
    expect(calls).toBe(2);
    const retired = tools(async () => { throw new WriterRetiredError("WRITER_RETIRED: writer generation 1 was replaced by generation 2"); });
    expect((await retired.queue_plan!({ steps: [{ action: "walk_to", x: 1, y: 2 }] })).structuredContent)
      .toMatchObject({ status: "failed", code: "WRITER_RETIRED", summary: "Error: WRITER_RETIRED: writer generation 1 was replaced by generation 2" });
  });
});

describe("claiming a writer generation", () => {
  class FakeRcon extends EventEmitter {
    connected = false;
    connect = vi.fn(async () => { this.connected = true; });
    close = vi.fn(() => { this.connected = false; this.emit("close"); });
  }
  const settings = { host: "127.0.0.1", port: 19015, password: "secret" };

  it("claims once per process, as the pilot first connects, and keeps it across reconnects", async () => {
    const first = new FakeRcon();
    const second = new FakeRcon();
    const factory = vi.fn().mockReturnValueOnce(first as unknown as RconClient).mockReturnValueOnce(second as unknown as RconClient);
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    const call = vi.spyOn(Bridge.prototype, "call").mockImplementation(async (method: string) =>
      method === "claim_writer" ? { generation: 7 } : { protocol_version: 29, mod_version: companionVersion() });
    const getBridge = createBridgeProvider(settings, factory, "pilot");
    expect((await getBridge()).writerGeneration).toBe(7);
    first.close();
    expect((await getBridge()).writerGeneration).toBe(7);
    expect(call.mock.calls.filter(([method]) => method === "claim_writer")).toEqual([["claim_writer", { role: "pilot" }]]);
    second.close();
  });

  it("claims nothing for another process", async () => {
    vi.spyOn(Bridge.prototype, "unlock").mockResolvedValue();
    const call = vi.spyOn(Bridge.prototype, "call").mockResolvedValue({ protocol_version: 29, mod_version: companionVersion() });
    const rcon = new FakeRcon();
    const bridge = await createBridgeProvider(settings, () => rcon as unknown as RconClient)();
    expect(bridge.writerGeneration).toBeUndefined();
    expect(call.mock.calls.map(([method]) => method)).toEqual(["ping"]);
    rcon.close();
  });
});
