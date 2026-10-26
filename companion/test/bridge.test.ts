import { describe, expect, it, vi } from "vitest";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS, escapeLuaString, JOB_TIMEOUT_MS, JobBusyError, ModError, OutcomeUnknownError, TaskCancelledError,
  type TaskClock } from "../src/bridge.js";
import { RconError } from "../src/rcon.js";
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

  it.each([
    ["transport", () => { throw new RconError("connection closed"); }],
    ["mod refusal", () => Promise.resolve(JSON.stringify({ ok: false, error: "status unavailable" }))],
    ["unexpected error", () => { throw new Error("monitor failed"); }],
    ["malformed envelope", () => Promise.resolve("not JSON")],
    ["null reply", () => ok(null)],
    ["invalid status", () => ok({ status: "nonsense" })],
  ])("does not cancel or re-enqueue accepted tasks after %s", async (_name, fail) => {
    let reads = 0;
    const latest = { status: "running", detail: "walking" };
    const { rcon, exec } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) return ok({ task_id: 45 });
      if (++reads === 1) return ok(latest);
      return fail();
    });
    const error = await new Bridge(rcon).enqueueAndWaitResult(
      { type: "walk_to", target: { x: 1, y: 2 } }, { clock: fakeClock().clock })
      .catch((error: unknown) => error);
    expect(error).toBeInstanceOf(OutcomeUnknownError);
    expect(error).toMatchObject({ accepted: { task_id: 45 }, lastKnown: latest,
      message: expect.stringContaining("physical state is unknown") });
    expect(exec.mock.calls.map(([cmd]) => /rpc","([^"]+)"/.exec(cmd)?.[1]))
      .toEqual(["enqueue", "get_task", "get_task"]);
  });

  it("cancels and rejects on timeout", async () => {
    const cancelled: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) return ok({ task_id: 9 });
      if (cmd.includes('"cancel"')) {
        cancelled.push(cmd);
        return ok({ cancelled: 1 });
      }
      return ok({ status: cancelled.length ? "cancelled" : "running", detail: "" });
    });
    const time = fakeClock();
    await expect(
      new Bridge(rcon).enqueueAndWait(
        { type: "walk_to", target: { x: 1, y: 2 } },
        { clock: time.clock, timeoutMs: 300, role: "supervisor" },
      ),
    ).rejects.toThrow(/gave up/);
    expect(cancelled).toHaveLength(1);
    expect(cancelled[0]).toContain(escapeLuaString(JSON.stringify({ task_id: 9, origin: "walk_to/supervisor/direct-task-timeout" })));
  });

  it("confirms exact-task cancellation after abort", async () => {
    const controller = new AbortController();
    const methods: string[] = [];
    const cancels: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) { methods.push("enqueue"); return ok({ task_id: 12 }); }
      if (cmd.includes('"cancel"')) { methods.push("cancel"); cancels.push(cmd); return ok({ cancelled: 1 }); }
      methods.push("get_task"); return ok({ status: "cancelled" });
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    await expect(new Bridge(rcon).enqueueAndWait(
      { type: "mine", target: { x: 0, y: 0 }, count: 2 }, { signal: controller.signal, clock, tool: "mine", role: "pilot" },
    )).rejects.toThrow(/cancelled/);
    expect(methods).toEqual(["enqueue", "cancel", "get_task"]);
    // An interrupted turn's cancel names the session role of this process.
    expect(cancels[0]).toContain(escapeLuaString(JSON.stringify({ task_id: 12, origin: "mine/pilot/abort" })));
  });

  it.each([
    ["abort", "fence", "running"], ["deadline", "fence", "running"],
    ["abort", "transport", "unavailable"], ["deadline", "transport", "running"],
    ["abort", "malformed", "malformed"], ["deadline", "zero", "mismatched"],
    ["deadline", "acknowledged", "running"], ["abort", "acknowledged", "unavailable"],
  ])("retains task evidence after %s with %s cancel and %s readback", async (trigger, cancel, readback) => {
    const controller = new AbortController();
    let now = 0, requested = false;
    const latest = { status: "running", detail: "historical progress", outcome: { inserted: 7 } };
    const clock: TaskClock = { now: () => now, sleep: async (ms) => {
      now += ms;
      if (trigger === "abort" && now > 100) controller.abort();
    } };
    const { rcon, exec } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) return ok({ task_id: 92 });
      if (cmd.includes('"cancel"')) {
        requested = true;
        if (cancel === "fence") return Promise.resolve(JSON.stringify({ ok: false, error: "WRITER_RETIRED: newer writer" }));
        if (cancel === "transport") throw new RconError("transport lost");
        return ok(cancel === "malformed" ? {} : { cancelled: cancel === "zero" ? 0 : 1 });
      }
      if (!requested || readback === "running") return ok(latest);
      if (readback === "unavailable") throw new RconError("readback unavailable");
      return ok(readback === "mismatched" ? { task_id: 93, status: "done" } : { status: "nonsense" });
    });
    const output = await new Bridge(rcon).enqueueAndWaitResult(
      { type: "walk_to", target: { x: 1, y: 2 } },
      { clock, timeoutMs: 300, signal: controller.signal, tool: "walk_to", role: "pilot" }).catch((error: unknown) => error);
    expect(output).toBeInstanceOf(OutcomeUnknownError);
    expect(output).toMatchObject({ accepted: { task_id: 92 }, lastKnown: latest,
      cancellation: { origin: `walk_to/pilot/${trigger === "abort" ? "abort" : "direct-task-timeout"}` } });
    expect((output as Error).message).toContain("was not confirmed");
    expect((output as Error).message).not.toMatch(/task cancelled|was cancelled|retry the call/);
    if (cancel === "fence") expect(output).toMatchObject({ cancellation: { code: "WRITER_RETIRED", error: expect.stringContaining("newer writer") } });
    if (cancel === "transport") expect(output).toMatchObject({ cancellation: { error: expect.stringContaining("transport lost") } });
    if (cancel === "malformed") expect(output).toMatchObject({ cancellation: { error: expect.stringContaining("malformed") } });
    const methods = exec.mock.calls.map(([cmd]) => /rpc","([^"]+)"/.exec(cmd)?.[1]);
    expect(methods).toEqual(trigger === "abort" ? ["enqueue", "get_task", "cancel", "get_task"]
      : ["enqueue", "get_task", "get_task", "cancel", "get_task"]);
    const command = exec.mock.calls.find(([cmd]) => cmd.includes('"cancel"'))![0];
    expect(command).toContain(escapeLuaString(JSON.stringify({ task_id: 92,
      origin: `walk_to/pilot/${trigger === "abort" ? "abort" : "direct-task-timeout"}` })));
  });

  it.each(["done", "partial", "failed", "cancelled"] as const)("preserves terminal task %s when cancel acknowledges zero", async (status) => {
    const controller = new AbortController();
    const terminal = { status, detail: "native outcome", outcome: { inserted: 7 } };
    const { rcon, exec } = fakeRcon((cmd) => cmd.includes('"enqueue"') ? ok({ task_id: 92 })
      : cmd.includes('"cancel"') ? ok({ cancelled: 0 }) : ok(terminal));
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    const result = await new Bridge(rcon).enqueueAndWaitResult({ type: "walk_to", target: { x: 1, y: 2 } },
      { clock, signal: controller.signal });
    expect(result).toMatchObject({ ...terminal, ...(status === "cancelled" ? { detail: "the task was cancelled" } : {}),
      task_id: 92, cancellation: { acknowledgement: { cancelled: 0 } } });
    expect(exec).toHaveBeenCalledTimes(3);
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
    let cancelled = false;
    const fake = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) { methods.push("enqueue"); return ok({ task_id: 21 }); }
      if (cmd.includes('"cancel"')) { methods.push("cancel"); cancelled = true; return ok({ cancelled: 1 }); }
      methods.push("get_task");
      const t = now();
      return ok(cancelled ? { status: "cancelled" } : done(t) ? { status: "done", detail: "arrived", fifo: { human_control: held(t) } }
        : { status: "running", detail: "", fifo: { human_control: held(t), human_idle_ticks: 3 } });
    });
    return { ...fake, methods };
  }

  it("cancels a task still held at the return guard and fails asking for a retry after the hold", async () => {
    let now = 0;
    const clock: TaskClock = { now: () => now, sleep: async (ms) => { now += ms; } };
    const { rcon, methods } = heldRcon(() => true, () => false, () => now);
    const error = await new Bridge(rcon).enqueueAndWait({ type: "walk_to", target: { x: 1, y: 2 } }, { clock })
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ModError);
    expect((error as Error).message).toMatch(/a human holds the body: task 21 was still running after 570s and was cancelled/);
    expect((error as Error).message).toMatch(/retry the call after the hold ends/);
    expect(now).toBe(DEFAULT_TASK_TIMEOUT_MS);
    expect(methods.slice(-2)).toEqual(["cancel", "get_task"]);
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
    expect(methods.slice(-2)).toEqual(["cancel", "get_task"]);
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
    expect(methods.slice(-2)).toEqual(["cancel", "get_task"]);
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

  it("waits for a large plan_status the game encodes over ticks, as for any job", async () => {
    const { rcon } = fakeRcon((cmd) => cmd.includes('"get_job"')
      ? ok({ job_id: 3, kind: "plan_status", job_status: "done", result: { plan_id: 9, status: "completed", outcomes: [] } })
      : pending(3, "plan_status"));
    expect(await new Bridge(rcon, fakeClock().clock).call("plan_status", { plan_id: 9 }))
      .toEqual({ plan_id: 9, status: "completed", outcomes: [] });
  });

  it("never polls for a method the game does not run as a job", async () => {
    const { rcon, exec } = fakeRcon(() => ok({ job_id: 1, job_status: "pending" }));
    expect(await new Bridge(rcon, fakeClock().clock).call("activity_log", {})).toEqual({ job_id: 1, job_status: "pending" });
    expect(exec).toHaveBeenCalledTimes(1);
  });
});
