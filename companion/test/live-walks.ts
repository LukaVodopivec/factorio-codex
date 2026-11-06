// Opt-in map-summary growth, native JSON and save/reload proofs. Fixture-only
// exports exist solely in the disposable mod copy; the production mod and MCP
// surface stay unchanged. See LIVE-VALIDATION.md for the measured limits.
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { factorioBinary } from "../src/setup/locate.js";
import { LiveHarness } from "./live-harness.js";
import { evaluateTiming } from "./live-timing.js";

const args = process.argv.slice(2);
const option = (name: string, fallback?: string) => {
  const at = args.indexOf(name);
  if (at < 0) return fallback;
  if (!args[at + 1] || args[at + 1]!.startsWith("--")) throw new Error(`missing ${name} value`);
  return args[at + 1]!;
};
const baselineRef = option("--baseline");
if (!baselineRef || !/^[a-f0-9]{40}$/.test(baselineRef)) throw new Error("--baseline requires the exact baseline commit SHA");
const mode = option("--mode", "equivalence")!;
const version = option("--version", "both")!;
if (!["equivalence", "reload", "growth"].includes(mode)) throw new Error("--mode must be equivalence, reload or growth");
if (!["baseline", "candidate", "both"].includes(version)) throw new Error("--version must be baseline, candidate or both");
const bin = factorioBinary();
if (!bin) throw new Error("Factorio 2.0 executable required (set FACTORIO_BIN)");
const here = path.dirname(fileURLToPath(import.meta.url)), root = path.resolve(here, "../..");
const output = path.join(root, ".agent", "map-summary-walks", `${mode}-${version}`);
fs.mkdirSync(output, { recursive: true });
const baselineSource = execFileSync("git", ["show", `${baselineRef}:mod/agentic-companion/scripts/map_summary.lua`],
  { cwd: root, encoding: "utf8" });
const native = new LiveHarness(bin, 747930220);
const lua = <T = any>(code: string) => native.lua<T>(code);
const hash = (value: string | Buffer) => crypto.createHash("sha256").update(value).digest("hex");
const expect = (ok: unknown, what: string) => { if (!ok) throw new Error(what); };
const receipts: unknown[] = [];
const manifest = {
  baseline: baselineRef, baselineSource: hash(baselineSource),
  candidateSource: hash(fs.readFileSync(path.join(root, "mod/agentic-companion/scripts/map_summary.lua"))),
  graphFixture: hash(fs.readFileSync(path.join(root, "tests/mod/flow_walk_fixture.lua"))),
  nativeFixture: hash(fs.readFileSync(path.join(here, "fixtures/summary-walks.lua"))),
};
const record = (row: unknown) => {
  receipts.push(row);
  fs.writeFileSync(path.join(output, "receipt.json"), JSON.stringify({ mode, version, manifest, receipts }, null, 2));
  console.log(JSON.stringify(row));
};
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => { void native.cleanup().finally(() => process.exit(128 + os.constants.signals[signal])); });
}
async function until<T>(read: () => Promise<T | false | undefined | null>, description: string): Promise<T> {
  for (const deadline = Date.now() + 60_000; ; await sleep(100)) {
    const value = await read();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out: ${description}`);
  }
}
async function readString(expression: string): Promise<string> {
  const bytes = await lua<number>(`return #(${expression})`);
  let value = "";
  for (let start = 1; start <= bytes; start += 65536) value += await lua<string>(`return string.sub(${expression},${start},${start + 65535})`);
  expect(Buffer.byteLength(value) === bytes, "incomplete native string transfer");
  return value;
}
const prepare = (modDir: string) => {
  const sourcePath = path.join(modDir, "scripts/map_summary.lua");
  fs.writeFileSync(sourcePath, fs.readFileSync(sourcePath, "utf8").replace(/return M\s*$/, "M.stage_probe=FLOW_STAGES; return M"));
  fs.writeFileSync(path.join(modDir, "scripts/walk_baseline.lua"), baselineSource.replace(/return M\s*$/, "M.stage_probe=FLOW_STAGES; return M"));
  fs.copyFileSync(path.join(root, "tests/mod/flow_walk_fixture.lua"), path.join(modDir, "scripts/walk_fixture.lua"));
  fs.copyFileSync(path.join(here, "fixtures/summary-walks.lua"), path.join(modDir, "scripts/walk_equivalence.lua"));
  fs.appendFileSync(path.join(modDir, "control.lua"), '\nrequire("scripts.walk_equivalence")\n');
};

try {
  const bridge = await native.start({ prepare });
  const ping = await bridge.call<any>("ping");
  expect(String(ping.factorio_version).startsWith("2.0."), "Factorio 2.0 required");
  await lua(`game.tick_paused=true`);
  record({ fixture: await lua(`return mod("walk_equivalence").physical()`) });

  if (mode === "equivalence") {
    for (const detail of ["aggregate", "full"]) {
      let expected: string | undefined;
      for (const source of ["baseline", "candidate"]) for (const work of [1, 7, 600]) {
        await lua(`storage.eq_state=mod("walk_equivalence").new("${source}","${detail}") storage.eq_json=nil`);
        let steps = 0;
        for (;;) {
          const batch = await lua<any>(`local json,n=mod("walk_equivalence").run("${source}",storage.eq_state,${work})
            if json then storage.eq_json=json end return {done=json~=nil,steps=n}`);
          steps += batch.steps;
          if (batch.done) break;
          expect(steps < 2000000, "summary did not finish");
        }
        const json = await readString("storage.eq_json");
        fs.writeFileSync(path.join(output, `${source}-${detail}-${work}.json`), json);
        if (expected === undefined) expected = json;
        else expect(json === expected, `complete native JSON differs: ${source}/${detail}/${work}`);
        record({ source, detail, work, steps, bytes: Buffer.byteLength(json), sha256: hash(json) });
      }
    }
  } else if (mode === "reload") {
    await lua(`mod("walk_equivalence").actors()`);
    fs.mkdirSync(path.join(native.dir, "saves"), { recursive: true });
    const cases = [
      ...["upstream_proven", "reaches_downstream", "first_reached", "ancestors", "material_upstream", "upstream_products"]
        .map(kind => ({ kind, variant: "walk", stage: undefined as number | undefined })),
      { kind: "upstream_proven", variant: "caller" }, { kind: "first_reached", variant: "caller" },
      { kind: "material_upstream", variant: "caller" }, { kind: "ancestors", variant: "products" },
      { kind: "upstream_proven", variant: "ingredient" }, { kind: "upstream_proven", variant: "fuel" },
      { kind: "upstream_products", variant: "cargo" },
      ...[19, 20, 24].map(stage => ({ kind: "boundary", stage, variant: "boundary" })),
      ...["reaches_downstream", "upstream_products", "first_reached"].map(kind => ({ kind, variant: "full" })),
    ];
    for (let begin = 0; begin < cases.length; begin += 8) {
      const batch: any[] = [];
      for (const test of cases.slice(begin, begin + 8)) {
        const code = "stage" in test && test.stage !== undefined ? `prepare_full("boundary",${test.stage})`
          : test.variant === "full" ? `prepare_full("${test.kind}")` : `prepare_stage("${test.kind}","${test.variant}")`;
        const row = await lua<any>(`return mod("walk_equivalence").${code}`);
        fs.writeFileSync(path.join(output, `${begin}-${row.id}-expected.json`), row.expected);
        delete row.expected;
        batch.push(row);
      }
      const name = `walk-reload-${begin}`, save = path.join(native.dir, "saves", `${name}.zip`);
      await lua(`game.server_save("${name}")`);
      await until(async () => fs.existsSync(save) && fs.statSync(save).size > 0, "native save");
      await native.stop();
      const saveSha = hash(fs.readFileSync(save));
      await native.start({ save });
      expect(await lua(`return game.tick_paused`), "reload changed frozen observations");
      for (const row of batch) {
        const resumed = await until(async () => {
          const result = await lua<any>(`return mod("walk_equivalence").collect(${row.id})`);
          return result.done ? result : false;
        }, `resume ${row.kind}/${row.variant ?? row.stage}`);
        record({ ...row, ...resumed, saveSha });
        fs.writeFileSync(path.join(output, `${begin}-${row.id}-actual.json`), await readString("storage.eq_json"));
      }
    }
  } else {
    await lua(`mod("walk_equivalence").actors() mod("walk_equivalence").profile() game.speed=64 game.tick_paused=false`);
    for (const n of [2400, 24000]) {
      for (const kind of ["upstream_proven", "reaches_downstream", "first_reached", "ancestors", "material_upstream", "upstream_products"]) {
        for (const shape of ["path", "cycle", "branch"]) {
          const inputBytes = await lua<number>(`return mod("walk_equivalence").input("${kind}",${n},"${shape}")`);
          const inputSha = hash(await readString("storage.eq_input_json"));
          let expected: string | undefined;
          for (const source of version === "both" ? ["baseline", "candidate"] : [version]) for (const work of [7, 600]) {
            await lua(`mod("walk_equivalence").prepare("${source}","${kind}",${work})`);
            const ticket = await bridge.call<any>("eq_serialized" as any, {});
            const job = await until(async () => {
              const value = await bridge.call<any>("get_job", { job_id: ticket.job_id });
              expect(value.job_status !== "failed", `native job failed: ${value.error}`);
              return value.job_status === "done" ? value : false;
            }, `${source}/${kind}/${shape}/${n}/${work}`);
            const result = job.result;
            if (expected === undefined) expected = result.json;
            else expect(result.json === expected, "native output differs for identical serialized input");
            record({ source, kind, n, shape, work, inputBytes, inputSha, steps: result.steps,
              outputBytes: Buffer.byteLength(result.json), outputSha: hash(result.json) });
          }
        }
      }
    }
    const tick = await lua<number>("return game.tick");
    const targetTick = (Math.floor(tick / 600) + 2) * 600;
    await until(() => lua<boolean>(`return game.tick>=${targetTick}`), "complete profiler window");
    const observedTick = await lua<number>("return game.tick");
    expect(observedTick >= targetTick, "final profiler boundary was not reached");
    record({ windowWait: { startTick: tick, targetTick, observedTick } });
    const log = fs.readFileSync(native.paths.log, "utf8"), timing = evaluateTiming(log);
    fs.writeFileSync(path.join(output, "server.log"), log);
    fs.writeFileSync(path.join(output, "policy.json"), JSON.stringify(timing, null, 2));
    console.log(timing.detail);
    if (!timing.ok) process.exitCode = 2;
  }
} finally { await native.cleanup(); }
