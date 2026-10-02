import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relative: string) => fs.readFileSync(path.join(root, relative), "utf8");
const skill = read(".agents/skills/factorio-player/SKILL.md");
const pilot = read(".agents/skills/factorio-player/GOAL-PILOT-v1.md");
const strategist = read(".agents/skills/factorio-player/GOAL-STRATEGIST-v1.md");
const active = `${skill}\n${pilot}\n${strategist}`;
const normalized = active.replace(/\s+/g, " ").toLowerCase();

describe("persistent two-brain coordination contract", () => {
  it("selects Luna-low-fast and Sol-medium-normal while preserving one writer, body, and FIFO lane", () => {
    expect(active).toMatch(/gpt-6-luna[\s\S]*low[\s\S]*fast mode enabled/i);
    expect(active).toMatch(/gpt-6\.1-sol[\s\S]*medium[\s\S]*normal[- ]speed/i);
    expect(active).toMatch(/pilot[\s\S]*sole (?:Factorio )?(?:MCP|gameplay) writer/i);
    expect(active).toMatch(/one body, one physical\s+FIFO/i);
    expect(strategist).toMatch(/never (?:call|use)[\s\S]*(?:movement|mine|mining|craft|placement|insert|extract|recipe mutation|research mutation|queue|cancel|stop)/i);
  });

  it("gives Sol only the named read-only evidence surface and keeps reads outside the physical lane", () => {
    for (const tool of ["connect_status", "map_summary", "progression_status", "production_requirements",
      "describe_prototype", "observe_local", "inspect_entity", "plan_status", "can_place", "find_placement"]) {
      expect(strategist).toContain(`\`${tool}\``);
    }
    expect(strategist).toMatch(/mechanically read-only[\s\S]*(?:never enter|outside)[\s\S]*(?:physical )?FIFO/i);
    expect(strategist).not.toMatch(/`(?:walk_to|mine|craft_items|place_entity|insert_items|extract_items|set_recipe|start_research|queue_plan|run_plan|stop)`/);
  });

  it("makes Sol the compact NOW/NEXT/LATER owner and keeps the pilot fail-open", () => {
    expect(strategist).toMatch(/(?:own|maintain)[\s\S]*NOW[\s\S]*NEXT[\s\S]*LATER/i);
    for (const field of ["objective", "strategic_reason", "completion_condition", "essential_prerequisite"])
      expect(strategist).toContain(`\`${field}\``);
    expect(pilot).toMatch(/missing, malformed, stale, unavailable[\s\S]*continue/i);
    expect(pilot).toMatch(/fresh (?:physical|exact local) evidence[\s\S]*(?:falsified|falsifies|invalidates)[\s\S]*(?:report|continue)/i);
    expect(active).not.toMatch(/blocking acknowledgement|wait for (?:Sol|the strategist|advice)/i);
  });

  it("prioritizes structural compounding growth over a tiny immediate deficit", () => {
    expect(normalized).toMatch(/principal objective is to maximize useful, sustained, autonomous production growth/i);
    expect(normalized).toMatch(/highest-payback capacity expansion.*before another manual deficit batch/i);
    expect(active).toMatch(/tiny immediate science deficit[\s\S]*larger reusable capacity deficit/i);
    expect(normalized).toMatch(/research normally consumes surplus|research consuming surplus/i);
    expect(normalized).toMatch(/factory growth means connected[\s\S]*utilized production/i);
    expect(active).toMatch(/manual (?:work|bridge|batch)[\s\S]*(?:durable|payback|numeric stop)/i);
  });

  it("covers the full Space Age horizon without fixing the inner-planet order", () => {
    for (const horizon of ["Nauvis", "orbital platform", "Vulcanus", "Fulgora", "Gleba", "Aquilo", "Solar System Edge"])
      expect(active).toContain(horizon);
    expect(active).toMatch(/never prescribe a fixed planetary order/i);
    expect(active).not.toContain("132,480");
  });

  it("preserves continuation, exact local authority, and non-autonomous terminology", () => {
    expect(pilot).toMatch(/continuation is the default[\s\S]*progress report is not a completion or pause boundary/i);
    expect(pilot).toMatch(/latest exact local state/i);
    expect(active).toMatch(/hand-fed machine[\s\S]*not[\s\S]*(?:autonomous|automation)/i);
    expect(active).toMatch(/reserve[\s\S]*loop[\s\S]*automation[\s\S]*continuous[\s\S]*autonomous_end_to_end/i);
  });

  it("yields at report checkpoints without pausing, and keeps Sol on the ledger only", () => {
    const agents = read("AGENTS.md");
    const live = read("docs/LIVE-VALIDATION.md");
    for (const text of [pilot, skill]) {
      expect(text).toMatch(/end (?:your|the) turn[\s\S]*neither a pause nor a completion/i);
      expect(text).toMatch(/1,000 bytes/);
    }
    expect(pilot).toMatch(/never calls `update_goal`/);
    expect(agents).toMatch(/native goal continuation, not a supervisor assignment per batch/i);
    expect(strategist).toMatch(/ledger is your only channel to the pilot; never message the pilot/i);
    expect(agents).toMatch(/ledger is Sol's only channel to\s+the pilot/i);
    expect(`${pilot}\n${strategist}`).toMatch(/never mark the goal complete without milestone proof/i);
    expect(agents).toMatch(/calls factorio\s+`stop`[\s\S]*pauses both role goals/i);
    expect(live).toMatch(/call factorio `stop`[\s\S]*`\/goal pause`[\s\S]*`turn\/interrupt`[\s\S]*server stop/i);
    expect(live).toMatch(/resume both role goals[\s\S]*before|resume both role goals[\s\S]*only then start the recorder/i);
    expect(`${strategist}\n${live}`).not.toMatch(/companion\/dist\/cli\.js ledger-apply/);
  });

  it("states which physical calls hold the only slot and keeps the launch block transport-complete", () => {
    const server = read("companion/src/mcp/server.ts");
    expect(server).toMatch(/run_plan[\s\S]*block until the plan is terminal/);
    expect(server).toMatch(/queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot/);
    const live = read("docs/LIVE-VALIDATION.md");
    expect(live).not.toMatch(/mcp_servers\.[a-z-]+\.enabled=/);
    expect(live).toMatch(/mcp_servers\.factorio-readonly=\{command=[^}]*args=\["--surface","read-only"\][^}]*enabled_tools=/);
    expect(pilot).not.toMatch(/mcp_servers/);
  });

  it("lets Sol design coupled layouts as validated packages that Luna queues unchanged", () => {
    const agents = read("AGENTS.md");
    expect(strategist).toMatch(/design every coupled layout yourself/i);
    expect(strategist).toMatch(/one `can_place` batch[\s\S]*`overlaps_batch`/);
    expect(strategist).toMatch(/Coordinates appear only inside validated build packages; NOW, NEXT, and LATER stay coordinate-free/);
    expect(strategist).toMatch(/never movement, pickup, mining, or crafting/);
    expect(strategist).toMatch(/Every ledger update restates the pending packages/);
    expect(pilot).toMatch(/fail open: design that one coupled connection yourself/);
    expect(pilot).toMatch(/batched `can_place`[\s\S]*`queue_plan` its steps unchanged/);
    expect(pilot).toMatch(/never repair a package's geometry/);
    expect(pilot).toMatch(/without a valid package keep working rather than waiting/i);
    expect(pilot).toMatch(/empty `find_placement` result is terminal for that unchanged request/);
    expect(agents).toMatch(/designs every coupled layout as a validated build\s+package/);
    expect(pilot).toMatch(/After `GO`, before any ledger read, report, or long deliberation, make sure a plan is queued/);
    expect(pilot).toMatch(/jq -c '\{revision, source_tick, run, assumptions, NOW: \.task_list\.NOW, build_packages\}'/);
    expect(pilot).toMatch(/When a validation fails, stay at that site: queue the fixes for its `nonproductive_status:\*`[\s\S]*`blocked_output` blockers yourself[\s\S]*which a hand insertion cannot clear/);
    expect(strategist).toMatch(/next package repairs the layout blockers it names[\s\S]*at that site before any other objective/);
    expect(strategist).toMatch(/completes a segment ends with a `wait_for_item` on the segment's terminal output[\s\S]*followed by a validation step/);
    expect(skill).toMatch(/transfer window opens\s+when the step starts/);
    for (const text of [agents, skill, pilot]) expect(text).toMatch(/under about 300 bytes/);
    expect(skill).toMatch(/one\s+exact node position is enough/);
    expect(strategist).toMatch(/A segment is complete only when every node has a physical feed, fuel included/);
    expect(pilot).toMatch(/After `GO`, never call `read_thread` or `wait_threads`, and call `list_threads` only once if you lack Sol's thread ID/);
    expect(pilot).toMatch(/a `plan_status` summary saying the FIFO is empty means it is not/);
    expect(pilot).toMatch(/size each queued plan to outlast the next one[\s\S]*rather than a lone one-rock or one-item plan/);
    expect(skill).toMatch(/size each plan to outlast the pilot's next decision/);
  });

  it("keeps durable gameplay instructions generic and text-only", () => {
    for (const text of [skill, pilot, strategist]) {
      expect(text).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
      expect(text).not.toMatch(/\b(?:first|start by)\s+(?:mine|craft|place|build|research)\b/i);
      expect(text).toMatch(/(?:no|never|do not|without)[\s\S]*(?:screenshot|raw Lua|console|teleport|hidden map|blueprint|fixed)/i);
    }
  });
});
