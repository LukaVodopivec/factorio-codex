import fs from "node:fs";

// Thought feed: tails the role Codex rollout files, saves every role's
// reasoning summaries and assistant messages, and shows the shown roles' in
// the game. Output only; tool calls, tool outputs and encrypted reasoning are
// never read out.
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
