// Shared by the opt-in live suite and deterministic synthetic-log tests.
export const TICK_BUDGET_MS = 8;
export const TICK_CEILING_MS = 10;

// RPCs and job work share one budget per game tick. GC time is included;
// gc_freed only annotates an observed heap decrease, never an exemption.
export function profile(log: string) {
  const rpcs: { method: string; tick: number; ms: number }[] = [], windows: number[] = [];
  const jobTicks: { kinds: string[]; tick: number; ms: number }[] = [];
  const ticks = new Map<number, { units: bigint; precision: number; methods: string[] }>();
  const add = (at: number, duration: string, methods: string[]) => {
    const [whole, fraction = ""] = duration.split(".");
    const tick = ticks.get(at) ?? { units: 0n, precision: 0, methods: [] };
    const precision = Math.max(tick.precision, fraction.length);
    // Sum the printed decimals exactly: binary addition can turn a logged
    // 0.05 + 7.98 + 1.97 = 10 ms into 10.000000000000002 ms.
    tick.units = tick.units * 10n ** BigInt(precision - tick.precision)
      + BigInt(whole! + fraction) * 10n ** BigInt(precision - fraction.length);
    tick.precision = precision;
    tick.methods.push(...methods);
    ticks.set(at, tick);
  };
  for (const match of log.matchAll(/ rpc (\S+) tick (\d+) Duration: ([\d.]+)ms/g)) {
    rpcs.push({ method: match[1]!, tick: Number(match[2]), ms: Number(match[3]) });
    add(Number(match[2]), match[3]!, [match[1]!]);
  }
  for (const match of log.matchAll(/ job_tick (\d+) (\S+) Duration: ([\d.]+)ms/g)) {
    jobTicks.push({ kinds: match[2]!.split(","), tick: Number(match[1]), ms: Number(match[3]) });
    add(Number(match[1]), match[3]!, match[2]!.split(",").map((kind) => `job:${kind}`));
  }
  for (const match of log.matchAll(/ on_tick (\d+) ticks Duration: ([\d.]+)ms/g)) windows.push(Number(match[2]) / Number(match[1]));
  const gc = new Set([...log.matchAll(/ gc_freed (\d+) \S+$/gm)].map((match) => Number(match[1])));
  return { rpcs, jobTicks, windows, ticks: [...ticks].map(([tick, row]) => ({
    tick, ms: Number(row.units) / 10 ** row.precision, methods: row.methods, gc: gc.has(tick),
  })) };
}

export const describeTick = (row: { tick: number; ms: number; methods: string[]; gc: boolean }) =>
  `tick ${row.tick} ${row.ms.toFixed(2)} ms (${row.methods.join(", ")}; GC heap decrease ${row.gc ? "observed" : "not observed"})`;

// Always evaluate a complete log prefix, not concatenated scenario slices:
// overlapping reads then neither duplicate work nor reset the suite allowance.
// Scenario checkpoints may precede the first complete on_tick window.
export function evaluateTiming(log: string, { requireWindows = true } = {}) {
  const measured = profile(log);
  const { rpcs, jobTicks, windows, ticks } = measured;
  const excursions = ticks.filter((row) => row.ms > TICK_BUDGET_MS);
  const errors: string[] = [];
  if (!rpcs.length) errors.push("missing RPC timing evidence");
  if (!jobTicks.length) errors.push("missing job timing evidence");
  if (requireWindows && !windows.length) errors.push("missing on_tick window timing evidence");
  if (excursions.length > 1) errors.push(`${excursions.length} distinct ticks exceed ${TICK_BUDGET_MS} ms; at most one allowed`);
  if (excursions.some((row) => row.ms > TICK_CEILING_MS)) errors.push(`measured tick exceeds hard ceiling ${TICK_CEILING_MS} ms`);
  if (windows.some((ms) => ms > TICK_BUDGET_MS)) errors.push(`on_tick window average exceeds ${TICK_BUDGET_MS} ms/tick`);
  const slowest = ticks.reduce<(typeof ticks)[number] | undefined>((worst, row) => (!worst || row.ms > worst.ms ? row : worst), undefined);
  const detail = `${rpcs.length} RPCs; ${jobTicks.length} job ticks; ${ticks.length} measured ticks; slowest ${slowest ? describeTick(slowest) : "unavailable"}; `
    + `nominal-budget excursions (${excursions.length}, allowance 1): ${excursions.map(describeTick).join("; ") || "none"}; `
    + `${windows.length} on_tick windows, worst average ${windows.length ? Math.max(...windows).toFixed(3) : "unavailable"} ms/tick`
    + (errors.length ? `; ${errors.join("; ")}` : "");
  return { ...measured, excursions, errors, ok: errors.length === 0, detail };
}
