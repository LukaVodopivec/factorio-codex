// Typed wrapper over RCON → remote.call("agentic","rpc",...).
import { RconClient, RconError, RconReplyLostError } from "./rcon.js";
import type { ChunkedEnvelope, GetTaskResult, Task } from "./types.js";
import { JOB_METHODS, WRITE_METHODS, parseRpcEnvelope, type RpcMethod } from "./protocol/contract.js";

export class ModError extends Error {}
export class TaskCancelledError extends ModError {}
/** A job could not be answered now: the mod's job slots are full (its error
 *  starts with JOBS_BUSY) or the game had not finished it within
 *  JOB_TIMEOUT_MS (a paused or slow server). It is transient, so not a
 *  ModError: a caller retries instead of recording a failure. */
export class JobBusyError extends Error {}
export const JOBS_BUSY = "JOBS_BUSY:";
/** A write whose answer was lost to a transport fault (a timeout, or the
 *  connection closing mid-call): the game may or may not have run it. Not a
 *  ModError, and never retried here. */
export class OutcomeUnknownError extends Error {}
/** The mod refused a write because a newer writer generation was claimed
 *  (rpc.lua's fence): this process no longer writes. Not a ModError: it is
 *  no refusal of the call's content. */
export class WriterRetiredError extends Error {}
export const WRITER_RETIRED = "WRITER_RETIRED:";

/** Escapes a string for inclusion in a double-quoted Lua string literal.
 *  JSON.stringify output never contains raw control characters, so escaping
 *  backslash and double-quote is sufficient. */
export function escapeLuaString(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

export interface EnqueueOptions {
  /** The MCP tool that owns the task; a cancel names it (default: the task type). */
  tool?: string;
  /** The session role of this MCP process (pilot, supervisor, ...); an
   *  aborted call's cancel names it (default: unknown). */
  role?: string;
  timeoutMs?: number;
  deadlineMs?: number;
  /** When the wait must return whatever happens (default: enqueue time plus
   *  DEFAULT_TASK_TIMEOUT_MS), so a tool that did work before the task stays
   *  under the MCP tool timeout. */
  returnByMs?: number;
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
export const JOB_POLL_DELAYS_MS = [50, 100, 250] as const;
export const JOB_TIMEOUT_MS = 120_000;

interface JobStatus { job_id: number; kind?: string; job_status: "pending" | "done" | "failed";
  result?: unknown; error?: string; ticks?: number; fifo?: unknown }
const jobMethods = new Set<string>(JOB_METHODS);
const writeMethods = new Set<string>(WRITE_METHODS);
export function outcomeUnknown(what: string, error: unknown): OutcomeUnknownError {
  const reason = error instanceof Error ? error.message : String(error);
  return new OutcomeUnknownError(`the connection to the game failed during ${what} (${reason}); it may or may not have run in the game`);
}
function pendingJob(value: unknown): value is JobStatus {
  const job = value as JobStatus | undefined;
  return !!job && typeof job === "object" && job.job_status === "pending" && typeof job.job_id === "number";
}

export class Bridge {
  /** This process's writer generation (claim_writer), sent with every write
   *  once set; absent for a process that never claimed one. */
  writerGeneration?: number;

  constructor(private readonly rcon: RconClient, private readonly clock: TaskClock = realClock) {}

  /** One RPC. A read the mod runs as a job over several ticks is polled
   *  through get_job here, so the caller gets the same result either way;
   *  signal (the MCP request's) stops that poll. */
  async call<T>(method: RpcMethod, params?: unknown, signal?: AbortSignal): Promise<T> {
    let value: unknown;
    try { value = await this.callUnchecked<unknown>(method, params); }
    catch (error) {
      if (jobMethods.has(method) && error instanceof ModError && error.message.startsWith(JOBS_BUSY)) {
        throw new JobBusyError(error.message);
      }
      throw error;
    }
    if (!jobMethods.has(method) || !pendingJob(value)) return value as T;
    return this.awaitJob<T>(method, value.job_id, signal);
  }

  /** Polls a job to its result. A poll that ends first (its timeout, or the
   *  caller's abort) drops the job, so it does not keep one of the mod's
   *  shared job slots for minutes. */
  private async awaitJob<T>(method: string, jobId: number, signal?: AbortSignal): Promise<T> {
    const started = this.clock.now();
    try {
      for (let poll = 0; ; poll++) {
        if (signal?.aborted) throw new TaskCancelledError(`${method} was cancelled`);
        await this.clock.sleep(JOB_POLL_DELAYS_MS[Math.min(poll, JOB_POLL_DELAYS_MS.length - 1)]!);
        if (signal?.aborted) throw new TaskCancelledError(`${method} was cancelled`);
        const job = await this.callUnchecked<JobStatus>("get_job", { job_id: jobId });
        if (job.job_status === "failed") throw new ModError(job.error ?? `${method} failed`);
        if (job.job_status === "done") {
          // get_job carries the body's FIFO state from its own read.
          const result = job.result;
          if (result && typeof result === "object" && !Array.isArray(result) && job.fifo !== undefined
            && (result as { fifo?: unknown }).fifo === undefined) return { ...result, fifo: job.fifo } as T;
          return (result ?? {}) as T;
        }
        if (this.clock.now() - started >= JOB_TIMEOUT_MS) {
          throw new JobBusyError(`${method} was still being computed in the game after ${Math.round(JOB_TIMEOUT_MS / 1000)} s`
            + ` (job ${jobId}, now dropped); try again later or with a smaller request`);
        }
      }
    } catch (error) {
      if (error instanceof JobBusyError || error instanceof TaskCancelledError) {
        await this.callUnchecked("get_job", { job_id: jobId, forget: true }).catch(() => {});
      }
      throw error;
    }
  }

  private async callUnchecked<T>(method: RpcMethod, params?: unknown): Promise<T> {
    const write = writeMethods.has(method);
    const stamped = write && this.writerGeneration !== undefined
      ? { ...(params as Record<string, unknown> | undefined), writer_generation: this.writerGeneration } : params;
    const json = escapeLuaString(JSON.stringify(stamped ?? {}));
    const cmd = `/silent-command remote.call("agentic","rpc","${method}","${json}")`;
    let reply: string;
    try { reply = await this.rcon.exec(cmd); }
    catch (error) {
      if (write && error instanceof RconReplyLostError) throw outcomeUnknown(method, error);
      throw error;
    }
    const raw = reply.trim();
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
      if (envelope.error?.startsWith(WRITER_RETIRED)) throw new WriterRetiredError(envelope.error);
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
    const clock = opts.clock ?? this.clock;
    const timeoutMs = opts.timeoutMs ?? DEFAULT_TASK_TIMEOUT_MS;
    const started = clock.now();
    const budget = holdAwareDeadline(clock, opts.deadlineMs ?? started + timeoutMs, opts.returnByMs);
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
      // An interrupted turn cancels its own task, named by this process's
      // session role; anything else is the bridge giving up at its deadline.
      const role = opts.signal?.aborted ? opts.role ?? "unknown" : "direct-task-timeout";
      await this.call("cancel", { task_id, origin: `${opts.tool ?? task.type}/${role}` }).catch(() => {});
      // The task was queued and its status could not be read: it may still run.
      if (error instanceof RconError) throw outcomeUnknown(`${opts.tool ?? task.type} (task ${task_id})`, error);
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
  returnBy: number = Math.max(deadline, clock.now() + DEFAULT_TASK_TIMEOUT_MS)) {
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
