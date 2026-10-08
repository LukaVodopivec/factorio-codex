import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createThoughtFeed, createTimeSplit, extractThoughts, RolloutTail, splitThought, type ThoughtFeed } from "../src/runs/thoughts.js";

const dirs: string[] = [];
const feeds: ThoughtFeed[] = [];
afterEach(() => { feeds.splice(0).forEach((feed) => feed.stop()); dirs.splice(0).forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })); });
const tmp = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), "factorio-thoughts-")); dirs.push(dir); return dir; };

const reasoning = (text: string, ts = "2026-10-04T18:25:54.454Z") => JSON.stringify({ timestamp: ts, type: "response_item",
  payload: { type: "reasoning", summary: [{ type: "summary_text", text }], encrypted_content: "gAAAA-secret" } });
const assistant = (text: string) => JSON.stringify({ timestamp: "2026-10-04T18:24:35.117Z", type: "response_item",
  payload: { type: "message", role: "assistant", content: [{ type: "output_text", text }], phase: "commentary" } });
const toolCall = JSON.stringify({ timestamp: "t", type: "response_item", payload: { type: "custom_tool_call", name: "factorio", input: "SECRET-INPUT" } });
const toolOutput = JSON.stringify({ timestamp: "t", type: "response_item", payload: { type: "custom_tool_call_output", output: "SECRET-OUTPUT" } });
const functionCall = JSON.stringify({ timestamp: "t", type: "response_item", payload: { type: "function_call", arguments: "SECRET-ARGS" } });
const userMessage = JSON.stringify({ timestamp: "t", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "SECRET-USER" }] } });
const event = JSON.stringify({ timestamp: "t", type: "event_msg", payload: { type: "agent_message", message: "SECRET-EVENT" } });

describe("rollout thought extraction", () => {
  it("keeps only reasoning summaries and assistant message text", () => {
    expect(extractThoughts(reasoning("Plan the smelter"))).toEqual([{ ts: "2026-10-04T18:25:54.454Z", kind: "reasoning", text: "Plan the smelter" }]);
    expect(extractThoughts(assistant("Queued the drills."))).toEqual([{ ts: "2026-10-04T18:24:35.117Z", kind: "message", text: "Queued the drills." }]);
    for (const line of [toolCall, toolOutput, functionCall, userMessage, event, "not json", "{}"]) expect(extractThoughts(line)).toEqual([]);
    const empty = JSON.stringify({ timestamp: "t", type: "response_item", payload: { type: "reasoning", summary: [], encrypted_content: "gAAAA" } });
    expect(extractThoughts(empty)).toEqual([]);
  });

  it("splits long text into single lines of at most 600 characters", () => {
    const words = Array.from({ length: 300 }, (_, i) => `word${i}`).join(" ");
    const lines = splitThought(`${words}\n\nend`);
    expect(lines.length).toBeGreaterThan(1);
    for (const line of lines) { expect(line.length).toBeLessThanOrEqual(600); expect(line).not.toContain("\n"); }
    expect(lines.join(" ")).toBe(`${words} end`);
    expect(splitThought("x".repeat(1300)).map((line) => line.length)).toEqual([600, 600, 100]);
  });
});

describe("rollout tail", () => {
  it("starts at the end, waits for complete lines, and restarts after truncation or replacement", () => {
    const file = path.join(tmp(), "rollout.jsonl");
    fs.writeFileSync(file, "old1\nold2\n");
    const tail = new RolloutTail(file);
    expect(tail.read()).toEqual([]);
    fs.appendFileSync(file, "new1\npart");
    expect(tail.read()).toEqual(["new1"]);
    fs.appendFileSync(file, "ial\n");
    expect(tail.read()).toEqual(["partial"]);
    fs.writeFileSync(file, "a\n");
    expect(tail.read()).toEqual(["a"]);
    const next = `${file}.next`; fs.writeFileSync(next, "rotated-long-line\n"); fs.renameSync(next, file);
    expect(tail.read()).toEqual(["rotated-long-line"]);
    fs.rmSync(file);
    expect(tail.read()).toEqual([]);
  });

  it("reads a file that appears after startup from its beginning", () => {
    const file = path.join(tmp(), "later.jsonl");
    const tail = new RolloutTail(file);
    expect(tail.read()).toEqual([]);
    fs.writeFileSync(file, "first\n");
    expect(tail.read()).toEqual(["first"]);
  });
});

describe("thought feed", () => {
  it("forwards one line per role per tick, records it, never replays, and survives say failures", async () => {
    const dir = tmp(), pilot = path.join(dir, "pilot.jsonl"), strategist = path.join(dir, "strategist.jsonl"), out = path.join(dir, "thoughts.jsonl");
    fs.writeFileSync(pilot, `${reasoning("history before start")}\n`);
    fs.writeFileSync(strategist, "");
    const said: Array<[string, string]> = [];
    let fail = true;
    const feed = createThoughtFeed({ sources: [{ role: "pilot", file: () => pilot }, { role: "strategist", file: () => strategist }], out, intervalMs: 3_600_000,
      say: async (role, text) => { said.push([role, text]); if (fail) { fail = false; throw new Error("rcon down"); } } });
    feeds.push(feed);
    fs.appendFileSync(pilot, [toolCall, reasoning("Need iron plates"), toolOutput, assistant("Building drills now.")].join("\n") + "\n");
    fs.appendFileSync(strategist, `${reasoning("NOW: automate red science")}\n`);
    await feed.tick();
    expect(said).toEqual([["pilot", "Need iron plates"], ["strategist", "NOW: automate red science"]]);
    await feed.tick();
    await feed.tick();
    expect(said).toEqual([["pilot", "Need iron plates"], ["strategist", "NOW: automate red science"], ["pilot", "Building drills now."]]);
    const recorded = fs.readFileSync(out, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    const iso = expect.stringMatching(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    expect(recorded).toEqual([
      { ts: "2026-10-04T18:25:54.454Z", role: "pilot", kind: "reasoning", text: "Need iron plates", said_at: null },
      { ts: "2026-10-04T18:25:54.454Z", role: "strategist", kind: "reasoning", text: "NOW: automate red science", said_at: iso },
      { ts: "2026-10-04T18:24:35.117Z", role: "pilot", kind: "message", text: "Building drills now.", said_at: iso },
    ]);
    const all = JSON.stringify(said) + fs.readFileSync(out, "utf8");
    for (const secret of ["SECRET", "gAAAA", "history before start"]) expect(all).not.toContain(secret);
  });

  it("shows only the shown roles in the game and still saves every role's thoughts", async () => {
    const dir = tmp(), pilot = path.join(dir, "pilot.jsonl"), strategist = path.join(dir, "strategist.jsonl"), out = path.join(dir, "thoughts.jsonl");
    fs.writeFileSync(pilot, ""); fs.writeFileSync(strategist, "");
    const said: Array<[string, string]> = [];
    const feed = createThoughtFeed({ sources: [{ role: "pilot", file: () => pilot }, { role: "strategist", file: () => strategist }], out, intervalMs: 3_600_000,
      shown: role => role === "strategist", say: async (role, text) => { said.push([role, text]); } });
    feeds.push(feed);
    fs.appendFileSync(pilot, [reasoning("Walking to iron"), assistant("Placed the drill.")].join("\n") + "\n");
    fs.appendFileSync(strategist, `${reasoning("Iron first, then coal")}\n`);
    await feed.tick();
    expect(said).toEqual([["strategist", "Iron first, then coal"]]);
    const recorded = fs.readFileSync(out, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    expect(recorded.filter(row => row.role === "pilot").map(row => [row.text, row.said_at]))
      .toEqual([["Walking to iron", null], ["Placed the drill.", null]]);
    expect(recorded.find(row => row.role === "strategist")?.said_at).toEqual(expect.any(String));
  });

  it("follows a replacement session's new rollout file from its start once the resolved path changes", async () => {
    const dir = tmp(), old = path.join(dir, "old.jsonl"), fresh = path.join(dir, "new.jsonl"), out = path.join(dir, "thoughts.jsonl");
    fs.writeFileSync(old, "");
    let current: string | null = old;
    const said: string[] = [];
    const feed = createThoughtFeed({ sources: [{ role: "pilot", file: () => current }], out, intervalMs: 3_600_000,
      say: async (_role, text) => { said.push(text); } });
    feeds.push(feed);
    fs.appendFileSync(old, `${reasoning("old pilot thinking")}\n`);
    await feed.tick();
    // The supervisor replaced the pilot: its file already holds the first lines.
    fs.writeFileSync(fresh, `${reasoning("replacement starts")}\n`);
    current = fresh;
    fs.appendFileSync(old, `${reasoning("retired pilot never speaks again")}\n`);
    await feed.tick();
    fs.appendFileSync(fresh, `${assistant("Queued the smelting block.")}\n`);
    await feed.tick();
    expect(said).toEqual(["old pilot thinking", "replacement starts", "Queued the smelting block."]);
  });

  it("sends the strategist's NOW objective through say_now only when it changes, retrying a failed send", async () => {
    const dir = tmp(), out = path.join(dir, "thoughts.jsonl");
    let objective: string | null = null, fail = true;
    const sent: string[] = [];
    const feed = createThoughtFeed({ sources: [], out, intervalMs: 3_600_000, say: async () => undefined,
      now: { read: () => objective, say: async (text) => { sent.push(text); if (fail) { fail = false; throw new Error("rcon down"); } } } });
    feeds.push(feed);
    await feed.tick();
    expect(sent).toEqual([]);
    objective = "Automate iron and coal";
    await feed.tick();
    await feed.tick();
    await feed.tick();
    objective = "Red science";
    await feed.tick();
    expect(sent).toEqual(["Automate iron and coal", "Automate iron and coal", "Red science"]);
  });
});

describe("rollout time split", () => {
  // Seconds after a fixed start, as a rollout line's ISO timestamp.
  const ms = (s: number) => Date.UTC(2026, 9, 4, 18, 0, 0) + s * 1000;
  const line = (s: number, type: string, payload: Record<string, unknown> = {}) =>
    JSON.stringify({ timestamp: new Date(ms(s)).toISOString(), type, payload });
  const event = (s: number, kind: string, extra: Record<string, unknown> = {}) => line(s, "event_msg", { type: kind, ...extra });
  const item = (s: number, kind: string, from: number, to: number) =>
    event(s, "item_completed", { item: { type: kind }, started_at_ms: ms(from), completed_at_ms: ms(to) });

  it("splits each turn into model, tool and compaction time from event times", () => {
    const split = createTimeSplit();
    for (const text of [
      event(0, "task_started"),
      line(4, "response_item", { type: "reasoning", summary: [] }),
      line(5, "response_item", { type: "custom_tool_call", call_id: "a", name: "exec", input: "x" }),
      // An MCP call inside the exec overlaps it: the union counts once.
      item(8, "McpToolCall", 6, 8),
      line(9, "response_item", { type: "custom_tool_call_output", call_id: "a", output: "y" }),
      // Compaction: the item's own span and the gap before the compacted line agree.
      item(30, "ContextCompaction", 10, 30),
      line(30, "compacted", { message: "" }),
      item(32, "Reasoning", 30, 32),
      line(33, "response_item", { type: "function_call", call_id: "b", name: "observe_local", arguments: "{}" }),
      line(36, "response_item", { type: "function_call_output", call_id: "b", output: "{}" }),
      event(40, "task_complete"),
      // Between turns nothing counts; a settings event opens no turn.
      event(100, "thread_settings_applied"),
      event(120, "task_started"),
      line(121, "response_item", { type: "custom_tool_call", call_id: "c", name: "exec", input: "x" }),
      line(125, "response_item", { type: "custom_tool_call_output", call_id: "c", output: "y" }),
      event(130, "turn_aborted"),
      "not json", JSON.stringify({ type: "event_msg", payload: { type: "task_started" } }),
    ]) split.line(text);
    expect(split.summary()).toEqual({ turns: 2, turn_ms: 50_000, tool_ms: 4_000 + 3_000 + 4_000, compaction_ms: 20_000,
      model_ms: 50_000 - 11_000 - 20_000, tool_calls: 3, compactions: 1 });
  });

  it("counts a turn already running when the tail began from its first line, and an open turn to its last", () => {
    const split = createTimeSplit();
    split.line(line(10, "response_item", { type: "reasoning", summary: [] }));
    split.line(line(12, "response_item", { type: "function_call", call_id: "a", name: "walk", arguments: "{}" }));
    split.line(line(15, "response_item", { type: "function_call_output", call_id: "a", output: "{}" }));
    split.line(event(20, "task_complete"));
    split.line(event(30, "task_started"));
    split.line(line(31, "response_item", { type: "function_call", call_id: "b", name: "next_event", arguments: "{}" }));
    split.line(event(34, "token_count"));
    // The open call counts as tool time up to the turn's last line.
    expect(split.summary()).toEqual({ turns: 2, turn_ms: 14_000, tool_ms: 6_000, compaction_ms: 0, model_ms: 8_000,
      tool_calls: 2, compactions: 0 });
    split.line(line(40, "response_item", { type: "function_call_output", call_id: "b", output: "{}" }));
    split.line(event(41, "task_complete"));
    expect(split.summary()).toMatchObject({ turns: 2, turn_ms: 21_000, tool_ms: 12_000, model_ms: 9_000 });
  });

  it("hands every rollout line read to onLine by role, and a throwing hook never stops the feed", async () => {
    const dir = tmp(), pilot = path.join(dir, "pilot.jsonl"), out = path.join(dir, "thoughts.jsonl");
    fs.writeFileSync(pilot, `${event(0, "task_started")}\n`);
    const seen: Array<[string, string]> = [], said: string[] = [];
    const feed = createThoughtFeed({ sources: [{ role: "pilot", file: () => pilot }], out, intervalMs: 3_600_000,
      say: async (_role, text) => { said.push(text); }, onLine: (role, text) => { seen.push([role, text]); throw new Error("ignored"); } });
    feeds.push(feed);
    fs.appendFileSync(pilot, `${event(1, "task_started")}\n${reasoning("Plan")}\n`);
    await feed.tick();
    expect(seen).toEqual([["pilot", event(1, "task_started")], ["pilot", reasoning("Plan")]]);
    expect(said).toEqual(["Plan"]);
  });
});
