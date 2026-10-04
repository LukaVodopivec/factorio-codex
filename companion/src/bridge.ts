// Typed wrapper over RCON → remote.call("agentic","rpc",...).
import { RconClient } from "./rcon.js";
import type { ChunkedEnvelope, GetTaskResult, Task } from "./types.js";
import { parseRpcEnvelope, type RpcMethod } from "./protocol/contract.js";

export class ModError extends Error {}
export class TaskCancelledError extends ModError {}

/** Escapes a string for inclusion in a double-quoted Lua string literal.
 *  JSON.stringify output never contains raw control characters, so escaping
 *  backslash and double-quote is sufficient. */
export function escapeLuaString(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

export interface EnqueueOptions {
  timeoutMs?: number;
  deadlineMs?: number;
  signal?: AbortSignal;
  clock?: TaskClock;
}

export interface TaskClock {
  now(): number;
  sleep(ms: number): Promise<void>;
}

const realClock: TaskClock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
};
export const TASK_POLL_DELAYS_MS = [100, 200, 500] as const;
export const DEFAULT_TASK_TIMEOUT_MS = 570_000;

export class Bridge {
  constructor(private readonly rcon: RconClient) {}

  async call<T>(method: RpcMethod, params?: unknown): Promise<T> {
    return this.callUnchecked<T>(method, params);
  }

  private async callUnchecked<T>(method: RpcMethod, params?: unknown): Promise<T> {
    const json = escapeLuaString(JSON.stringify(params ?? {}));
    const cmd = `/silent-command remote.call("agentic","rpc","${method}","${json}")`;
    const raw = (await this.rcon.exec(cmd)).trim();
    if (!raw) {
      throw new ModError(
        "empty response from the game — is the agentic-companion mod installed and enabled on this save?",
      );
    }
    let envelope: ReturnType<typeof parseRpcEnvelope>;
    try {
      envelope = parseRpcEnvelope(raw);
    } catch (error) {
      throw new ModError(
        `invalid protocol response from the game: ${raw.slice(0, 200)} (${error instanceof Error ? error.message : error})`,
      );
    }
    if (envelope.ok && envelope.chunked) {
      // Oversized response: part 1 came inline, fetch parts 2..N and reparse.
      const head = envelope as unknown as ChunkedEnvelope;
      let assembled = head.data;
      for (let part = 2; part <= head.parts; part++) {
        const chunk = await this.call<{ data: string }>("get_chunk", { id: head.id, part });
        assembled += chunk.data;
      }
      try {
        envelope = parseRpcEnvelope(assembled);
      } catch {
        throw new ModError(
          `unparseable chunked response from the game (${head.parts} parts, ${assembled.length} bytes)`,
        );
      }
    }
    if (!envelope.ok) {
      throw new ModError(envelope.error ?? "unknown mod error");
    }
    return envelope.data as T;
  }

  /** Factorio requires the first Lua command of a session to be repeated as an
   *  "this disables achievements" confirmation, and returns nothing until then.
   *  Send a harmless ping up to twice to get past it. Call once after connect. */
  async unlock(): Promise<void> {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await this.call("ping");
        return;
      } catch (err) {
        if (!(err instanceof ModError) || !/empty response/.test(err.message)) throw err;
      }
    }
    throw new ModError(
      "the game did not accept Lua commands — is the agentic-companion mod installed and enabled on this save?",
    );
  }

  /** Enqueues a task and polls until it reaches a terminal state.
   *  Resolves with the human-readable detail; rejects (ModError) on failure. */
  async enqueueAndWait(task: Task, opts: EnqueueOptions = {}): Promise<string> {
    const st = await this.enqueueAndWaitResult(task, opts);
    if (st.status === "done") return st.detail || "done";
    if (st.status === "cancelled") throw new TaskCancelledError("the task was cancelled");
    throw new ModError(st.detail || (st.status === "partial" ? "task partially completed" : "task failed"));
  }

  /** Same physical queue path, retaining the structured terminal outcome.
   *  Time the body spends under a human hold (get_task's fifo.human_control)
   *  is not charged to the deadline. A direct call has no parked form: if the
   *  body is still held at the return guard, the task is cancelled and the call
   *  fails asking for a retry after the hold. */
  async enqueueAndWaitResult(task: Task, opts: EnqueueOptions = {}): Promise<GetTaskResult> {
    if (opts.signal?.aborted) throw new TaskCancelledError("the task was cancelled");
    const { task_id } = await this.call<{ task_id: number }>("enqueue", { task });
    const clock = opts.clock ?? realClock;
    const timeoutMs = opts.timeoutMs ?? DEFAULT_TASK_TIMEOUT_MS;
    const started = clock.now();
    const budget = holdAwareDeadline(clock, opts.deadlineMs ?? started + timeoutMs);
    let poll = 0;

    try {
      for (;;) {
        if (opts.signal?.aborted) throw new TaskCancelledError("the task was cancelled");
        const delay = TASK_POLL_DELAYS_MS[Math.min(poll, TASK_POLL_DELAYS_MS.length - 1)]!;
        poll++;
        await clock.sleep(Math.max(0, Math.min(delay, budget.remaining())));
        if (opts.signal?.aborted) throw new TaskCancelledError("the task was cancelled");
        const st = await this.call<GetTaskResult>("get_task", { task_id });
        if (opts.signal?.aborted) throw new TaskCancelledError("the task was cancelled");
        budget.sample(st.fifo?.human_control === true);
        const { fifo: _fifo, ...status } = st;
        if (status.status !== "queued" && status.status !== "running") {
          return budget.held ? { ...status, human_control: true } : status;
        }
        if (budget.remaining() > 0) continue;
        const waited = Math.round((clock.now() - started) / 1000);
        if (budget.holding) {
          throw new ModError(`a human holds the body: task ${task_id} was still ${status.status} after ${waited}s and was cancelled`
            + " so the tool call can return; retry the call after the hold ends");
        }
        throw new ModError(`gave up after ${Math.round(timeoutMs / 1000)}s — task cancelled`
          + (budget.held ? ` (${waited}s wall time including a human hold)` : ""));
      }
    } catch (error) {
      await this.call("cancel", { task_id }).catch(() => {});
      throw error;
    }
  }
}

/** A wall-clock deadline that a human hold does not consume. sample() after
 *  each status read credits the time since the previous read only when both
 *  reads show the hold. The wait ends at the budget or at the return guard
 *  (default 570 s, under the 600 s MCP tool timeout), whichever comes first;
 *  parked() means it ended at the guard with credited budget left. holding is
 *  the latest read; held is true once any read showed the hold. */
export function holdAwareDeadline(clock: TaskClock, deadline: number,
  returnBy = Math.max(deadline, clock.now() + DEFAULT_TASK_TIMEOUT_MS)) {
  let last = clock.now();
  let holding = false;
  let held = false;
  return {
    sample(nowHeld: boolean): void {
      const now = clock.now();
      if (nowHeld && holding) deadline += now - last;
      holding = nowHeld;
      held ||= nowHeld;
      last = now;
    },
    remaining: () => Math.min(deadline, returnBy) - clock.now(),
    parked: () => clock.now() < deadline,
    get holding() { return holding; },
    get held() { return held; },
  };
}
