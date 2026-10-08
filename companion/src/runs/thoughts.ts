import fs from "node:fs";

// Thought feed: tails the role Codex rollout files, saves every role's
// reasoning summaries and assistant messages, and shows the shown roles' in
// the game. Output only; tool calls, tool outputs and encrypted reasoning are
// never read out. The time split reads only event types and times.
export type ThoughtRole = "pilot" | "strategist" | "mining" | "logistics";
export type ThoughtKind = "reasoning" | "message";
export interface Thought { ts: string; role: ThoughtRole; kind: ThoughtKind; text: string }
/** One thoughts.jsonl row: ts is the rollout time, said_at when the game showed it (null when the say failed or the role is not shown). */
export interface ThoughtRecord extends Thought { said_at: string | null }

export const THOUGHT_LINE_MAX = 600;
const QUEUE_MAX = 200;

/** Readable text items from one rollout JSONL line; anything else yields nothing. */
export function extractThoughts(line: string): Array<{ ts: string; kind: ThoughtKind; text: string }> {
  let entry: any;
  try { entry = JSON.parse(line); } catch { return []; }
  if (entry?.type !== "response_item" || !entry.payload || typeof entry.payload !== "object") return [];
  const ts = typeof entry.timestamp === "string" ? entry.timestamp : new Date().toISOString();
  const { payload } = entry;
  let kind: ThoughtKind, parts: unknown;
  if (payload.type === "reasoning") { kind = "reasoning"; parts = payload.summary; }
  else if (payload.type === "message" && payload.role === "assistant") { kind = "message"; parts = payload.content; }
  else return [];
  if (!Array.isArray(parts)) return [];
  const wanted = kind === "reasoning" ? "summary_text" : "output_text";
  return parts.flatMap((part: any) => part?.type === wanted && typeof part.text === "string"
    && part.text.trim() ? [{ ts, kind, text: part.text }] : []);
}

/** A role's wall time inside its turns, from rollout event times: tool time
 *  (tool items' own start and end, and each model tool call to its output),
 *  compaction time (context compaction items), and model time (the rest of
 *  the turn). Turns run from task_started to task_complete or turn_aborted;
 *  a turn already running when the tail began counts from its first
 *  response item seen, and one still open counts to its last line. Events
 *  after a turn closed (a late item_completed) open no turn. */
export interface TimeSplit { turns: number; turn_ms: number; model_ms: number; tool_ms: number; compaction_ms: number;
  tool_calls: number; compactions: number }
type Span = [number, number];
// Model-generated items: their time is model time, not tool time.
const MODEL_ITEMS = new Set(["Reasoning", "AgentMessage", "UserMessage", "Plan"]);
const CALLS = new Set(["function_call", "custom_tool_call", "local_shell_call"]);
const OUTPUTS = new Set(["function_call_output", "custom_tool_call_output", "local_shell_call_output"]);
const IN_TURN_EVENTS = new Set(["item_completed", "token_count", "agent_message", "agent_reasoning"]);

/** Adds [a, b] to a start-sorted list of disjoint spans, merging what it
 *  overlaps. Spans arrive nearly in order, so this works at the tail. */
function insert(list: Span[], [a, b]: Span): void {
  if (b <= a) return;
  let i = list.length;
  while (i > 0 && list[i - 1]![0] > a) i--;
  if (i > 0 && list[i - 1]![1] >= a) i--;
  let j = i;
  while (j < list.length && list[j]![0] <= b) { a = Math.min(a, list[j]![0]); b = Math.max(b, list[j]![1]); j++; }
  list.splice(i, j - i, [a, b]);
}
/** Total length of disjoint spans, clipped to [from, to]. */
function covered(spans: readonly Span[], from: number, to: number): number {
  return spans.reduce((total, [a, b]) => total + Math.max(0, Math.min(b, to) - Math.max(a, from)), 0);
}
/** The union of two start-sorted disjoint lists, in one pass. */
function union(x: readonly Span[], y: readonly Span[]): Span[] {
  const out: Span[] = [];
  for (let i = 0, j = 0; i < x.length || j < y.length;) {
    const [a, b] = j >= y.length || (i < x.length && x[i]![0] <= y[j]![0]) ? x[i++]! : y[j++]!;
    const last = out[out.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b); else out.push([a, b]);
  }
  return out;
}

export function createTimeSplit() {
  const totals: TimeSplit = { turns: 0, turn_ms: 0, model_ms: 0, tool_ms: 0, compaction_ms: 0, tool_calls: 0, compactions: 0 };
  let turn: { start: number; last: number; tools: Span[]; compactions: Span[] } | null = null;
  const calls = new Map<string, number>();
  const fold = (into: TimeSplit, open: NonNullable<typeof turn>, end: number) => {
    const length = Math.max(0, end - open.start);
    const tool = covered(open.tools, open.start, end), compaction = covered(open.compactions, open.start, end);
    const both = covered(union(open.tools, open.compactions), open.start, end);
    into.turns++; into.turn_ms += length; into.tool_ms += tool; into.compaction_ms += compaction;
    into.model_ms += Math.max(0, length - both);
  };
  return {
    /** One rollout JSONL line; anything unreadable is skipped. */
    line(text: string): void {
      let entry: any;
      try { entry = JSON.parse(text); } catch { return; }
      const ts = typeof entry?.timestamp === "string" ? Date.parse(entry.timestamp) : NaN;
      if (!Number.isFinite(ts)) return;
      const payload = entry.payload && typeof entry.payload === "object" ? entry.payload : {};
      const event = entry.type === "event_msg" ? payload.type : undefined;
      if (event === "task_started") {
        if (turn) fold(totals, turn, turn.last);
        turn = { start: ts, last: ts, tools: [], compactions: [] }; calls.clear();
        return;
      }
      if (event === "task_complete" || event === "turn_aborted") {
        if (turn) fold(totals, turn, ts);
        turn = null; calls.clear();
        return;
      }
      const opens = entry.type === "response_item" || entry.type === "compacted";
      if (!turn && !opens) return;
      if (!opens && !IN_TURN_EVENTS.has(event)) return;
      turn ??= { start: ts, last: ts, tools: [], compactions: [] };
      turn.last = Math.max(turn.last, ts);
      if (entry.type === "compacted") {
        totals.compactions++;
      } else if (entry.type === "response_item" && CALLS.has(payload.type) && typeof payload.call_id === "string") {
        totals.tool_calls++;
        calls.set(payload.call_id, ts);
      } else if (entry.type === "response_item" && OUTPUTS.has(payload.type) && calls.has(payload.call_id)) {
        insert(turn.tools, [calls.get(payload.call_id)!, ts]);
        calls.delete(payload.call_id);
      } else if (event === "item_completed" && typeof payload.started_at_ms === "number" && typeof payload.completed_at_ms === "number") {
        const kind = payload.item?.type;
        if (kind === "ContextCompaction") insert(turn.compactions, [payload.started_at_ms, payload.completed_at_ms]);
        else if (typeof kind === "string" && !MODEL_ITEMS.has(kind)) insert(turn.tools, [payload.started_at_ms, payload.completed_at_ms]);
      }
    },
    /** The totals so far, an open turn (and its unanswered calls) counted to its last line. */
    summary(): TimeSplit {
      const out = { ...totals };
      if (turn) {
        const tools = [...turn.tools];
        for (const start of calls.values()) insert(tools, [start, turn.last]);
        fold(out, { ...turn, tools }, turn.last);
      }
      return out;
    },
  };
}

/** One-line chunks of at most `max` characters, broken at a space where one is near. */
export function splitThought(text: string, max = THOUGHT_LINE_MAX): string[] {
  let rest = text.replace(/\s+/g, " ").trim();
  const lines: string[] = [];
  while (rest.length > max) {
    const space = rest.lastIndexOf(" ", max);
    const cut = space > max / 2 ? space : max;
    lines.push(rest.slice(0, cut).trimEnd()); rest = rest.slice(cut).trimStart();
  }
  if (rest) lines.push(rest);
  return lines;
}

/** Follows a growing file from its end at construction (or from its start
 *  with fromStart); restarts at 0 after truncation or replacement. */
export class RolloutTail {
  private offset = 0;
  private ino: number | undefined;
  constructor(private readonly file: string, options: { fromStart?: boolean } = {}) {
    try {
      const st = fs.statSync(file);
      this.ino = st.ino;
      if (!options.fromStart) this.offset = st.size;
    } catch { /* appears later: read it whole */ }
  }
  /** Complete new lines since the last read; a trailing partial line waits for its newline. */
  read(): string[] {
    let fd: number | undefined;
    try {
      fd = fs.openSync(this.file, "r");
      const st = fs.fstatSync(fd);
      if (st.ino !== this.ino || st.size < this.offset) { this.ino = st.ino; this.offset = 0; }
      if (st.size === this.offset) return [];
      const chunk = Buffer.alloc(st.size - this.offset);
      const got = fs.readSync(fd, chunk, 0, chunk.length, this.offset);
      const end = chunk.subarray(0, got).lastIndexOf(0x0a);
      if (end < 0) return [];
      this.offset += end + 1;
      return chunk.subarray(0, end).toString("utf8").split("\n").filter((line) => line.trim());
    } catch {
      return [];
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }
}

export interface ThoughtFeedOptions {
  /** Each role's rollout file, resolved on every tick: a replacement session
   *  writes a new file, which is then followed from its start. */
  sources: Array<{ role: ThoughtRole; file: () => string | null }>;
  say: (role: ThoughtRole, text: string) => Promise<unknown>;
  /** Roles shown in the game (default all); the others are only saved. */
  shown?: (role: ThoughtRole) => boolean;
  out: string;
  /** The strategist's current NOW objective for the panel's top line, sent through say_now when it changes. */
  now?: { read: () => string | null; say: (text: string) => Promise<unknown> };
  intervalMs?: number;
  /** Every complete rollout line read, by role (the recorder's time split). */
  onLine?: (role: ThoughtRole, line: string) => void;
}
export interface ThoughtFeed { tick(): Promise<void>; stop(): void }

/** Polls each source once per interval and forwards at most one line per role per interval. */
export function createThoughtFeed(options: ThoughtFeedOptions): ThoughtFeed {
  const roles = options.sources.map(({ role, file }) => {
    const first = file();
    return { role, file, path: first, tail: first ? new RolloutTail(first) : null, queue: [] as Thought[], busy: false };
  });
  let shownNow: string | null = null;
  const tick = async () => {
    const now = options.now?.read() ?? null;
    if (options.now && now !== null && now !== shownNow) {
      try { await options.now.say(now); shownNow = now; } catch { /* game unavailable: retried next tick */ }
    }
    await Promise.all(roles.map(async (source) => {
      let resolved: string | null = null;
      try { resolved = source.file(); } catch { /* keep the current file */ }
      if (resolved && resolved !== source.path) {
        source.path = resolved;
        source.tail = new RolloutTail(resolved, { fromStart: true });
      }
      for (const line of source.tail?.read() ?? []) {
        try { options.onLine?.(source.role, line); } catch { /* telemetry never stops the feed */ }
        for (const item of extractThoughts(line)) {
          for (const text of splitThought(item.text)) source.queue.push({ ts: item.ts, role: source.role, kind: item.kind, text });
        }
      }
      // A hidden role is only saved, all of it: the cap paces what the game shows.
      if (options.shown && !options.shown(source.role)) {
        const rows = source.queue.splice(0).map(thought => `${JSON.stringify({ ...thought, said_at: null })}\n`);
        try { if (rows.length) fs.appendFileSync(options.out, rows.join(""), { encoding: "utf8", mode: 0o600 }); } catch { /* evidence only */ }
        return;
      }
      if (source.queue.length > QUEUE_MAX) source.queue.splice(0, source.queue.length - QUEUE_MAX);
      if (source.busy) return;
      const next = source.queue.shift();
      if (!next) return;
      // said_at is when the game accepted the line (null: the say failed and the line was dropped).
      let saidAt: string | null = null;
      source.busy = true;
      try { await options.say(next.role, next.text); saidAt = new Date().toISOString(); }
      catch { /* game unavailable: drop the line */ } finally { source.busy = false; }
      const record: ThoughtRecord = { ...next, said_at: saidAt };
      try { fs.appendFileSync(options.out, `${JSON.stringify(record)}\n`, { encoding: "utf8", mode: 0o600 }); } catch { /* keep feeding the game */ }
    }));
  };
  let running = false;
  const timer = setInterval(() => {
    if (running) return;
    running = true;
    tick().catch(() => undefined).finally(() => { running = false; });
  }, options.intervalMs ?? 1000);
  timer.unref();
  return { tick, stop: () => clearInterval(timer) };
}
