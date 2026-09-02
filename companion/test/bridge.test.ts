import { describe, expect, it, vi } from "vitest";
import { Bridge, DEFAULT_TASK_TIMEOUT_MS, escapeLuaString, ModError, type TaskClock } from "../src/bridge.js";
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
  });

  it("cancels its owned task on abort and never polls again", async () => {
    const controller = new AbortController();
    const methods: string[] = [];
    const { rcon } = fakeRcon((cmd) => {
      if (cmd.includes('"enqueue"')) { methods.push("enqueue"); return ok({ task_id: 12 }); }
      if (cmd.includes('"cancel"')) { methods.push("cancel"); return ok({ cancelled: 1 }); }
      methods.push("get_task"); return ok({ status: "running" });
    });
    const clock: TaskClock = { now: () => 0, sleep: async () => { controller.abort(); } };
    await expect(new Bridge(rcon).enqueueAndWait(
      { type: "mine", target: { x: 0, y: 0 }, count: 2 }, { signal: controller.signal, clock },
    )).rejects.toThrow(/cancelled/);
    expect(methods).toEqual(["enqueue", "cancel"]);
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
