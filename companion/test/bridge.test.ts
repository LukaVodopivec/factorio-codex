import { describe, expect, it, vi } from "vitest";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS, escapeLuaString, JOB_TIMEOUT_MS, JobBusyError, ModError, TaskCancelledError,
  type TaskClock } from "../src/bridge.js";
import type { RconClient } from "../src/rcon.js";

function fakeRcon(execImpl: (cmd: string) => Promise<string>): {
  rcon: RconClient;
  exec: ReturnType<typeof vi.fn>;
} {
  const exec = vi.fn(execImpl);
  return { rcon: { exec } as unknown as RconClient, exec };
}

const ok = (data: unknown) => Promise.resolve(JSON.stringify({ ok: true, data }));
function fakeClock() {
  let now = 0;
  const sleeps: number[] = [];
  const clock: TaskClock = { now: () => now, sleep: async (ms) => { sleeps.push(ms); now += ms; } };
  return { clock, sleeps, set: (value: number) => { now = value; } };
}

describe("escapeLuaString", () => {
  it("escapes backslashes and quotes", () => {
    expect(escapeLuaString('a"b\\c')).toBe('a\\"b\\\\c');
  });

  it("survives a JSON round trip with nasty content", () => {
    const params = { text: 'he said "ciao" \\ done\nnewline' };
    const escaped = escapeLuaString(JSON.stringify(params));
    // Simulate Lua unescaping of the double-quoted string literal:
    const unescaped = escaped.replace(/\\(["\\])/g, "$1");
    expect(JSON.parse(unescaped)).toEqual(params);
  });
});

describe("Bridge.call", () => {
  it("builds the remote.call command and parses the envelope", async () => {
    const { rcon, exec } = fakeRcon(() => ok({ tick: 42 }));
    const bridge = new Bridge(rcon);
    const res = await bridge.call<{ tick: number }>("ping", {});
    expect(res.tick).toBe(42);
    expect(exec).toHaveBeenCalledWith(
      '/silent-command remote.call("agentic","rpc","ping","{}")',
    );
  });

  it("reassembles an actual chunked mod response before returning its data", async () => {
    const complete = JSON.stringify({ ok: true, data: { tick: 42, note: "x".repeat(80) } });
    const cuts = [complete.slice(0, 37), complete.slice(37, 79), complete.slice(79)];
    let nextPart = 0;
    const { rcon, exec } = fakeRcon((cmd) => {
      if (cmd.includes('"get_chunk"')) {
        nextPart++;
        return ok({ data: cuts[nextPart] });
      }
      return Promise.resolve(JSON.stringify({
        ok: true,
        chunked: true,
        id: 17,
        parts: cuts.length,
        data: cuts[0],
      }));
    });

    await expect(new Bridge(rcon).call<{ tick: number; note: string }>("ping", {}))
      .resolves.toEqual({ tick: 42, note: "x".repeat(80) });
    expect(exec).toHaveBeenCalledTimes(3);
    expect(exec.mock.calls[1][0]).toContain('get_chunk","{\\"id\\":17,\\"part\\":2}"');
    expect(exec.mock.calls[2][0]).toContain('get_chunk","{\\"id\\":17,\\"part\\":3}"');
  });

  it("throws ModError on ok:false", async () => {
    const { rcon } = fakeRcon(() =>
      Promise.resolve(JSON.stringify({ ok: false, error: "boom" })),
    );
    await expect(new Bridge(rcon).call("x")).rejects.toThrow("boom");
  });

  it("throws ModError on empty response (mod missing)", async () => {
    const { rcon } = fakeRcon(() => Promise.resolve("\n"));
    await expect(new Bridge(rcon).call("x")).rejects.toThrow(/mod installed/);
  });

  it("throws ModError on garbage response", async () => {
    const { rcon } = fakeRcon(() => Promise.resolve("Unknown command"));
    await expect(new Bridge(rcon).call("x")).rejects.toThrow(ModError);
  });
});

describe("Bridge.enqueueAndWait", () => {
  it("allows long physical plans below the 600-second MCP ceiling", () => {
    expect(DEFAULT_TASK_TIMEOUT_MS).toBe(570_000);
    expect(DEFAULT_TASK_TIMEOUT_MS).toBeGreaterThan(540_000);
    expect(DEFAULT_TASK_TIMEOUT_MS).toBeLessThan(600_000);
  });
  it("settles at 500ms after 100/200 throughout a long-running task", async () => {
    let polls = 0;
    const { rcon, exec } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) return ok({ task_id: 7 });
      polls++;
      return polls < 8
        ? ok({ status: "running", detail: "" })
        : ok({ status: "done", detail: "arrived at (1.0, 2.0)" });
    });
    const bridge = new Bridge(rcon);
    const time = fakeClock();
    await expect(
      bridge.enqueueAndWait({ type: "walk_to", target: { x: 1, y: 2 } }, { clock: time.clock }),
    ).resolves.toBe("arrived at (1.0, 2.0)");
    expect(time.sleeps).toEqual([100, 200, 500, 500, 500, 500, 500, 500]);
    expect(exec.mock.calls[0][0]).toContain('\\"task\\"');
    expect(exec.mock.calls[0][0]).not.toContain("replace");
  });

  it("rejects when the task fails", async () => {
    const { rcon } = fakeRcon((cmd) =>
      cmd.includes('"enqueue"')
        ? ok({ task_id: 8 })
        : ok({ status: "failed", detail: "got stuck" }),
    );
    await expect(new Bridge(rcon).enqueueAndWait(
      { type: "mine", target: { x: 0, y: 0 }, count: 1 }, { clock: fakeClock().clock },
    )).rejects.toThrow("got stuck");
  });

  it("retains a structured useful partial result without retrying", async () => {
    const terminal = { status: "partial" as const, detail: "inserted 7 of 10",
      outcome: { code: "PARTIAL_INSERT", total_inserted: 7 } };
    const { rcon, exec } = fakeRcon((cmd) => cmd.includes('"enqueue"')
      ? ok({ task_id: 18 }) : ok(terminal));
    await expect(new Bridge(rcon).enqueueAndWaitResult(
      { type: "insert", target: { x: 0, y: 0 }, items: { wood: 10 } }, { clock: fakeClock().clock },
    )).resolves.toEqual(terminal);
    expect(exec).toHaveBeenCalledTimes(2);
  });

  it("cancels and rejects on timeout", async () => {
    const cancelled: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) return ok({ task_id: 9 });
      if (cmd.includes('"cancel"')) {
        cancelled.push(cmd);
        return ok({ cancelled: 1 });
      }
      return ok({ status: "running", detail: "" });
    });
    const time = fakeClock();
    await expect(
      new Bridge(rcon).enqueueAndWait(
        { type: "walk_to", target: { x: 1, y: 2 } },
        { clock: time.clock, timeoutMs: 300 },
      ),
    ).rejects.toThrow(/gave up/);
    expect(cancelled).toHaveLength(1);
    expect(cancelled[0]).toContain(escapeLuaString(JSON.stringify({ task_id: 9, origin: "walk_to/direct-task-timeout" })));
  });

  it("cancels its owned task on abort and never polls again", async () => {
    const controller = new AbortController();
    const methods: string[] = [];
    const cancels: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) { methods.push("enqueue"); return ok({ task_id: 12 }); }
      if (cmd.includes('"cancel"')) { methods.push("cancel"); cancels.push(cmd); return ok({ cancelled: 1 }); }
      methods.push("get_task"); return ok({ status: "running" });
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    await expect(new Bridge(rcon).enqueueAndWait(
      { type: "mine", target: { x: 0, y: 0 }, count: 2 }, { signal: controller.signal, clock, tool: "mine", role: "pilot" },
    )).rejects.toThrow(/cancelled/);
    expect(methods).toEqual(["enqueue", "cancel"]);
    // An interrupted turn's cancel names the session role of this process.
    expect(cancels[0]).toContain(escapeLuaString(JSON.stringify({ task_id: 12, origin: "mine/pilot" })));
  });

  it("does not enqueue when already aborted", async () => {
    const controller = new AbortController(); controller.abort();
    const { rcon, exec } = fakeRcon(() => ok({}));
    await expect(new Bridge(rcon).enqueueAndWait(
      { type: "walk_to", target: { x: 1, y: 2 } }, { signal: controller.signal },
    )).rejects.toThrow(/cancelled/);
    expect(exec).not.toHaveBeenCalled();
  });
});

describe("Bridge.enqueueAndWaitResult under a human hold", () => {
  // get_task carries the mod's fifo block; human_control is the current hold.
  function heldRcon(held: (now: number) => boolean, done: (now: number) => boolean, now: () => number) {
    const methods: string[] = [];
    const fake = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) { methods.push("enqueue"); return ok({ task_id: 21 }); }
      if (cmd.includes('"cancel"')) { methods.push("cancel"); return ok({ cancelled: 1 }); }
      methods.push("get_task");
      const t = now();
      return ok(done(t) ? { status: "done", detail: "arrived", fifo: { human_control: held(t) } }
        : { status: "running", detail: "", fifo: { human_control: held(t), human_idle_ticks: 3 } });
    });
    return { ...fake, methods };
  }

  it("cancels a task still held at the return guard and fails asking for a retry after the hold", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const { rcon, methods } = heldRcon(() => true, () => false, () => now);
    const error = await new Bridge(rcon).enqueueAndWaitResult({ type: "walk_to", target: { x: 1, y: 2 } }, { clock })
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ModError);
    expect((error as Error).message).toMatch(/a human holds the body: task 21 was still running after 570s and was cancelled/);
    expect((error as Error).message).toMatch(/retry the call after the hold ends/);
    expect(now).toBe(DEFAULT_TASK_TIMEOUT_MS);
    expect(methods.at(-1)).toBe("cancel");
  });

  it("does not charge held time to the deadline and marks the result delayed", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    // Held for the first 5 s (samples 100..4800 ms credit 4.7 s), then work until 5.6 s against a 1 s budget.
    const { rcon, methods } = heldRcon((t) => t <= 5_000, (t) => t >= 5_600, () => now);
    const st = await new Bridge(rcon).enqueueAndWaitResult({ type: "mine", target: { x: 0, y: 0 }, count: 1 },
      { clock, timeoutMs: 1_000 });
    expect(st).toEqual({ status: "done", detail: "arrived", human_control: true });
    expect(methods).not.toContain("cancel");
  });

  it("still cancels when the unheld budget runs out after a hold", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const { rcon, methods } = heldRcon((t) => t <= 2_000, () => false, () => now);
    await expect(new Bridge(rcon).enqueueAndWait({ type: "mine", target: { x: 0, y: 0 }, count: 1 },
      { clock, timeoutMs: 1_000 })).rejects.toThrow(/gave up after 1s — task cancelled \(3s wall time including a human hold\)/);
    expect(methods.at(-1)).toBe("cancel");
    expect(now).toBe(2_700); // 1 s budget plus the 1.7 s between held samples 100 and 1800 ms
  });

  it("credits only intervals whose two consecutive samples both show the hold", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    // One isolated held sample (300 ms) between unheld ones credits nothing.
    const { rcon, methods } = heldRcon((t) => t === 300, () => false, () => now);
    await expect(new Bridge(rcon).enqueueAndWait({ type: "mine", target: { x: 0, y: 0 }, count: 1 },
      { clock, timeoutMs: 1_000 })).rejects.toThrow(/gave up after 1s/);
    expect(now).toBe(1_000);
    expect(methods.at(-1)).toBe("cancel");
  });
});

describe("Bridge.call for reads the game runs as jobs", () => {
  const pending = (id: number, kind: string) => ok({ job_id: id, job_status: "pending", kind, fifo: { queue_depth: 0 } });

  it("polls get_job until the job is done and returns its result with the job's FIFO state", async () => {
    const commands: string[] = [];
    let polls = 0;
    const { rcon } = fakeRcon((cmd) => {
      commands.push(cmd);
      if (cmd.includes('"map_summary"')) return pending(4, "map_summary");
      return ++polls < 3 ? ok({ job_id: 4, kind: "map_summary", job_status: "pending", ticks: polls })
        : ok({ job_id: 4, kind: "map_summary", job_status: "done", result: { tick: 99, factory: {} }, fifo: { queue_depth: 2 } });
    });
    const time = fakeClock();
    const summary = await new Bridge(rcon, time.clock).call("map_summary", { detail: "aggregate" });
    expect(summary).toEqual({ tick: 99, factory: {}, fifo: { queue_depth: 2 } });
    expect(commands.slice(1)).toEqual(Array(3).fill(`/silent-command remote.call("agentic","rpc","get_job","${escapeLuaString('{"job_id":4}')}")`));
    expect(time.sleeps).toEqual([50, 100, 250]);
  });

  it("returns a result that fit in the tick at once, and keeps a result's own FIFO state", async () => {
    const { rcon, exec } = fakeRcon(() => ok({ tick: 5, entities: [], fifo: { queue_depth: 1 } }));
    expect(await new Bridge(rcon, fakeClock().clock).call("observe_local", { radius: 15 })).toEqual({ tick: 5, entities: [], fifo: { queue_depth: 1 } });
    expect(exec).toHaveBeenCalledTimes(1);
    const done = fakeRcon((cmd) => cmd.includes('"get_job"')
      ? ok({ job_id: 2, job_status: "done", result: { tick: 6, fifo: { queue_depth: 3 } }, fifo: { queue_depth: 4 } })
      : pending(2, "observe_local"));
    expect(await new Bridge(done.rcon, fakeClock().clock).call("observe_local", {})).toEqual({ tick: 6, fifo: { queue_depth: 3 } });
  });

  it("raises a failed job's error and gives up on a job that does not finish", async () => {
    const failed = fakeRcon((cmd) => cmd.includes('"get_job"')
      ? ok({ job_id: 3, job_status: "failed", error: "connect_entities endpoints must both be force-charted" })
      : pending(3, "connect_entities"));
    await expect(new Bridge(failed.rcon, fakeClock().clock).call("connect_entities", {}))
      .rejects.toThrow(new ModError("connect_entities endpoints must both be force-charted"));
    const forgets: string[] = [];
    const slow = fakeRcon((cmd) => {
      if (cmd.includes("forget")) { forgets.push(cmd); return ok({ job_id: 8, forgotten: true }); }
      return cmd.includes('"get_job"') ? ok({ job_id: 8, job_status: "pending" }) : pending(8, "build_layout");
    });
    const time = fakeClock();
    const late = await new Bridge(slow.rcon, time.clock).call("build_layout", { check_only: true }).catch((e: unknown) => e);
    expect(late).toBeInstanceOf(JobBusyError);
    expect(late).not.toBeInstanceOf(ModError);
    expect((late as Error).message).toMatch(/build_layout was still being computed in the game after 120 s \(job 8, now dropped\)/);
    expect(time.sleeps.reduce((total, ms) => total + ms, 0)).toBeGreaterThanOrEqual(JOB_TIMEOUT_MS);
    // The timed-out job gives its slot back.
    expect(forgets).toEqual([`/silent-command remote.call("agentic","rpc","get_job","${escapeLuaString('{"job_id":8,"forget":true}')}")`]);
  });

  it("drops the job when the caller aborts its poll, and never polls again", async () => {
    const controller = new AbortController();
    const methods: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes("forget")) { methods.push("forget"); return ok({ job_id: 6, forgotten: true }); }
      if (cmd.includes('"get_job"')) { methods.push("get_job"); return ok({ job_id: 6, job_status: "pending" }); }
      methods.push("map_summary"); return pending(6, "map_summary");
    });
    let sleeps = 0;
    const clock: TaskClock = { now: () => 0, sleep: async () => { if (++sleeps === 2) controller.abort(); } };
    await expect(new Bridge(rcon, clock).call("map_summary", {}, controller.signal)).rejects.toBeInstanceOf(TaskCancelledError);
    expect(methods).toEqual(["map_summary", "get_job", "forget"]);
  });

  it("reports full job slots as a busy error, not a mod failure", async () => {
    const { rcon } = fakeRcon(() => Promise.resolve(JSON.stringify({ ok: false,
      error: "JOBS_BUSY: 8 jobs are pending or unread; read their results with get_job before starting another" })));
    const busy = await new Bridge(rcon, fakeClock().clock).call("observe_local", {}).catch((e: unknown) => e);
    expect(busy).toBeInstanceOf(JobBusyError);
    expect((busy as Error).message).toMatch(/^JOBS_BUSY: 8 jobs/);
  });

  it("never polls for a method the game does not run as a job", async () => {
    const { rcon, exec } = fakeRcon(() => ok({ job_id: 1, job_status: "pending" }));
    expect(await new Bridge(rcon, fakeClock().clock).call("plan_status", { plan_id: 1 })).toEqual({ job_id: 1, job_status: "pending" });
    expect(exec).toHaveBeenCalledTimes(1);
  });
});
