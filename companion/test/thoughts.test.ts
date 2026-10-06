import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { createThoughtFeed, extractThoughts, RolloutTail, splitThought, type ThoughtFeed } from "../src/runs/thoughts.js";

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
