import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relative: string) => fs.readFileSync(path.join(root, relative), "utf8");
const skill = read(".agents/skills/factorio-player/SKILL.md");
const pilot = read(".agents/skills/factorio-player/GOAL-PILOT-v1.md");
const knowledge = read(".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md");
const active = `${skill}\n${pilot}`;

describe("persistent single-pilot contract", () => {
  it("has one role and no dormant coordination implementation", () => {
    expect(fs.existsSync(path.join(root, ".agents/skills/factorio-player/GOAL-STRATEGIST-v1.md"))).toBe(false);
    expect(fs.existsSync(path.join(root, "companion/src/coordination/ledger.ts"))).toBe(false);
    expect(skill).toContain("](GOAL-PILOT-v1.md)");
    expect(active).toMatch(/sole Factorio MCP user[\s\S]*live-state authority[\s\S]*planner[\s\S]*growth owner[\s\S]*milestone owner/i);
    expect(active).toMatch(/no strategist[\s\S]*operations ledger[\s\S]*advisory proposal[\s\S]*report channel[\s\S]*(?:acknowledgement|resend)/i);
    expect(read("companion/src/cli.ts")).not.toMatch(/ledger-apply|--ledger|coordination\/ledger/);
  });

  it("makes reports and intermediate work nonterminal", () => {
    expect(active).toMatch(/waypoint[\s\S]*batch[\s\S]*plan[\s\S]*(?:progress )?report[\s\S]*(?:not a completion|nonterminal)/i);
    expect(active).toMatch(/while later-tick milestone proof is absent[\s\S]*continue whenever[\s\S]*(?:productive work|bounded recovery)/i);
    expect(active).toMatch(/current plan plus one[\s\S]*plan_status.*confirmed successor/i);
    expect(pilot).toMatch(/complete only with later-tick structured milestone proof/i);
  });

  it("makes compounding capacity the default after safety and hard unblocks", () => {
    const normalized = active.replace(/\s+/g, " ");
    expect(normalized).toMatch(/preserve (?:immediate )?safety.*hard production unblock.*before another manual deficit batch.*highest-payback capacity expansion/i);
    expect(normalized).toMatch(/growth objective alongside the milestone/i);
    for (const evidence of ["utilization", "buffers", "work in progress", "service or travel time", "power headroom", "foreseeable recipe demand", "production deltas", "break-even", "future character touches"])
      expect(normalized.toLowerCase()).toContain(evidence);
    expect(normalized).toMatch(/expand the bottleneck[\s\S]*downstream demand[\s\S]*power[\s\S]*resource supply[\s\S]*another measured stage/i);
    expect(normalized).toMatch(/reassess factory-wide flow after every material capacity increase/i);
    expect(normalized).toMatch(/satisfying only the next deficit is never the default/i);
  });

  it("requires payback, headroom, clustered service, and accepted downstream flow", () => {
    expect(active).toMatch(/repeated manual crafting, fueling, hauling, collection[\s\S]*automated or expanded[\s\S]*remaining useful demand/i);
    expect(active).toMatch(/evidence-backed headroom[\s\S]*future demand[\s\S]*reuse likely/i);
    expect(active).toMatch(/fewer, larger, buffer-aware transfers[\s\S]*colocated work/i);
    expect(active).toMatch(/sustained input[\s\S]*physical transfer[\s\S]*accepted downstream output[\s\S]*utilization/i);
    const reporting = active.replace(/\s+/g, " ").toLowerCase();
    for (const evidence of ["reports are nonterminal", "measured capacity increase", "manual bridge", "automation payback"])
      expect(reporting).toContain(evidence);
  });

  it("requires autonomous material flow and declining character labor", () => {
    const normalized = active.replace(/\s+/g, " ").toLowerCase();
    expect(normalized).toMatch(/machine_present.*locally_operating.*autonomous_end_to_end/);
    expect(normalized).toMatch(/physical upstream source.*ordinary factorio entities.*physical downstream sink/);
    expect(normalized).toMatch(/hand-inserted input never proves autonomy/);
    expect(normalized).toMatch(/automation-debt list|automation debt/);
    expect(normalized).toMatch(/character touches per output.*service trips per interval.*trend downward/);
    expect(normalized).toMatch(/permanent physical connection.*bounded number of additional manual batches.*numeric stop condition/);
    expect(normalized).toMatch(/several expected production cycles|several measured cycles/);
    expect(normalized).toMatch(/zero character (?:inventory )?transfers?/);
    expect(normalized).toMatch(/disconnected production island.*transport path.*completed and validated/);
    expect(normalized).toMatch(/reserve.*loop.*automation.*continuous.*self-running.*fully calibrated.*autonomous_end_to_end/);
    expect(normalized).toMatch(/handcraft\/insert\/wait\/extract\/walk.*manual service cycle/);
  });

  it("uses authoritative capabilities and one FIFO physical lane", () => {
    expect(active).toMatch(/exactly one physical Factorio tool call may be in flight/i);
    expect(active).toMatch(/parallelize only read-only observations[\s\S]*revalidate the newest snapshot/i);
    expect(active).toMatch(/progression_status\.enabled_recipes[\s\S]*describe_prototype\(kind="recipe"\)/i);
    expect(active).toMatch(/technology unlock name is not automatically a craftable recipe/i);
    expect(active.replace(/\s+/g, " ").toLowerCase()).toContain("furnaces choose from inserted input and never accept that action");
    const normalized = active.replace(/\s+/g, " ").toLowerCase();
    expect(normalized).toContain("terminal for the unchanged request");
    expect(normalized).toContain("never repeat the same terminal semantic error");
    expect(active).toMatch(/sequential and nontransactional[\s\S]*no rollback/i);
  });

  it("preserves generic physical play and ephemeral coordinates", () => {
    const normalized = `${active}\n${knowledge}`.replace(/\s+/g, " ");
    for (const required of ["one physical character", "raw Lua/console", "hidden map state", "free resources", "exact natural targets", "charted reachable frontier"])
      expect(normalized.toLowerCase()).toContain(required.toLowerCase());
    const normalizedKnowledge = knowledge.replace(/\s+/g, " ").toLowerCase();
    for (const evidence of ["pilot's ephemeral current working context", "expire on reset", "contradictory observation", "referenced-entity mutation", "route failure"])
      expect(normalizedKnowledge).toContain(evidence);
    for (const forbidden of [/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/, /\bfirst (?:mine|craft|place|build|research)\b/i, /\bthen (?:mine|craft|place|build|research)\b/i])
      expect(normalized).not.toMatch(forbidden);
    for (const rejected of ["fixed build order", "prescribed technology order", "external blueprints", "tutorials", "online sequences", "seed/map facts"])
      expect(normalized.toLowerCase()).toContain(rejected);
  });
});
