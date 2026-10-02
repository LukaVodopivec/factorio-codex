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
  it("selects Luna-low-fast and Astra-medium-normal while preserving one writer, body, and FIFO lane", () => {
    expect(active).toMatch(/gpt-6-luna[\s\S]*low[\s\S]*fast mode enabled/i);
    expect(active).toMatch(/gpt-6-astra[\s\S]*medium[\s\S]*normal speed/i);
    expect(active).not.toMatch(/gpt-6\.1-sol/);
    expect(active).toMatch(/pilot[\s\S]*sole (?:Factorio )?(?:MCP|gameplay) writer/i);
    expect(normalized).toMatch(/one body, one physical fifo/);
    expect(normalized).toMatch(/exactly one physical mcp call may be in flight/);
    expect(strategist).toMatch(/never (?:call|use)[\s\S]*(?:movement|mine|mining|craft|placement|insert|extract|recipe mutation|research mutation|queue|cancel|stop)/i);
  });

  it("gives Astra only the named read-only evidence surface and keeps reads outside the physical lane", () => {
    for (const tool of ["connect_status", "map_summary", "progression_status", "production_requirements",
      "describe_prototype", "observe_local", "inspect_entity", "plan_status", "can_place", "find_placement"]) {
      expect(strategist).toContain(`\`${tool}\``);
    }
    expect(strategist).toMatch(/mechanically read-only[\s\S]*(?:never enter|outside)[\s\S]*(?:physical )?FIFO/i);
    expect(strategist).not.toMatch(/`(?:walk_to|mine|craft_items|place_entity|insert_items|extract_items|set_recipe|start_research|queue_plan|run_plan|stop)`/);
  });

  it("makes Astra the compact NOW/NEXT/LATER owner and keeps the pilot fail-open", () => {
    expect(strategist).toMatch(/(?:own|maintain)[\s\S]*NOW[\s\S]*NEXT[\s\S]*LATER/i);
    for (const field of ["objective", "strategic_reason", "completion_condition", "essential_prerequisite"])
      expect(strategist).toContain(`\`${field}\``);
    expect(strategist).toMatch(/`essential_prerequisite` is one outcome sentence \(at most 160 characters\)/);
    expect(pilot).toMatch(/missing, malformed, stale, unavailable[\s\S]*continue/i);
    expect(pilot).toMatch(/fresh (?:physical|exact local) evidence[\s\S]*(?:falsified|falsifies|invalidates)[\s\S]*(?:report|continue)/i);
    expect(active).not.toMatch(/blocking acknowledgement|wait for (?:Astra|the strategist|advice)/i);
  });

  it("prioritizes compounding input growth over a tiny immediate deficit", () => {
    expect(normalized).toMatch(/principal objective is to maximize useful, sustained, autonomous production growth/i);
    expect(normalized).toMatch(/highest-payback capacity expansion.*before another manual deficit batch/i);
    expect(active).toMatch(/tiny immediate science deficit[\s\S]*larger reusable capacity deficit/i);
    expect(normalized).toMatch(/research normally consumes surplus|research consuming surplus/i);
    expect(normalized).toMatch(/factory growth means connected[\s\S]*utilized production/i);
    expect(active).toMatch(/manual (?:work|bridge|batch)[\s\S]*(?:durable|payback|numeric (?:stop|sunset))/i);
    const knowledge = read(".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md").replace(/\s+/g, " ");
    for (const text of [strategist.replace(/\s+/g, " "), knowledge])
      expect(text).toMatch(/input rate \(ore and plates per minute\)/i);
    expect(strategist).toMatch(/Never plan hand-crafted science to push research while raw input is the bottleneck/);
    expect(pilot).toMatch(/Never hand-craft science to push research while raw input is the bottleneck/);
    expect(strategist).toMatch(/principle, not a build or technology order/);
  });

  it("covers the full Space Age horizon without fixing the inner-planet order", () => {
    for (const horizon of ["Nauvis", "orbital platform", "Vulcanus", "Fulgora", "Gleba", "Aquilo", "Solar System Edge"])
      expect(active.replace(/\s+/g, " ")).toContain(horizon);
    expect(normalized).toMatch(/never prescribe a fixed planetary order/);
    expect(active).not.toContain("132,480");
  });

  it("preserves continuation, exact local authority, and non-autonomous terminology", () => {
    expect(pilot).toMatch(/continuation is the default[\s\S]*progress report is not a completion or pause boundary/i);
    expect(pilot).toMatch(/latest exact local state/i);
    expect(active).toMatch(/hand-fed machine[\s\S]*not[\s\S]*(?:autonomous|automation)/i);
    expect(active).toMatch(/reserve[\s\S]*loop[\s\S]*automation[\s\S]*continuous[\s\S]*autonomous_end_to_end/i);
    expect(normalized).toMatch(/`autonomous_end_to_end` only from tool evidence of physical upstream supply/);
  });

  it("yields at report checkpoints without pausing, and keeps Astra on the ledger only", () => {
    const agents = read("AGENTS.md");
    const live = read("docs/LIVE-VALIDATION.md");
    expect(skill).toMatch(/ending\s+the turn is neither a pause nor a completion/i);
    for (const text of [pilot, skill, agents]) expect(text).toMatch(/1,000 bytes/);
    expect(pilot).toMatch(/never calls `update_goal`/);
    expect(agents).toMatch(/native goal continuation, not a supervisor assignment per batch/i);
    expect(strategist).toMatch(/ledger is your only channel to the pilot; never message the pilot/i);
    expect(agents).toMatch(/ledger is Astra's only\s+channel to the pilot/i);
    expect(`${pilot}\n${strategist}`).toMatch(/never mark the goal complete without milestone proof/i);
    expect(agents).toMatch(/calls factorio\s+`stop`[\s\S]*pauses both role goals/i);
    expect(live).toMatch(/call factorio `stop`[\s\S]*`\/goal pause`[\s\S]*`turn\/interrupt`[\s\S]*server stop/i);
    expect(live).toMatch(/resume both role goals[\s\S]*before|resume both role goals[\s\S]*only then start the recorder/i);
    expect(`${strategist}\n${live}`).not.toMatch(/companion\/dist\/cli\.js ledger-apply/);
  });

  it("reserves emergency cancellation to the supervisor and recovers through retained FIFO state", () => {
    const flatSkill = skill.replace(/\s+/g, " ");
    expect(flatSkill).toMatch(/pilot never calls the `stop` tool/);
    for (const boundary of ["ordinary gameplay", "report checkpoints", "turn endings",
      "monitoring timeouts", "package changes", "recovery from failed or partially committed plans"])
      expect(flatSkill).toContain(boundary);
    expect(flatSkill).toMatch(/supervisor alone may use `stop` for an explicit the owner stop, retained-work reconciliation, or recorded emergency cancellation needed for physical quiescence during replacement/);
    expect(flatSkill).toMatch(/A TUI interruption alone does not authorize physical cancellation/);
    expect(flatSkill).toMatch(/a role told of it never calls `stop`, makes no further write/i);
    expect(pilot).toMatch(/If the supervisor says the owner stopped the run, do not call `stop`/);
    expect(pilot).toMatch(/obtain fresh structured state and inspect exact known plan IDs with `plan_status`/);
    expect(pilot).toMatch(/A monitoring timeout leaves the plan pending/);
    expect(pilot).toMatch(/Retain completed physical effects; there is no rollback/);
    expect(pilot).toMatch(/Reconcile active and queued work[\s\S]*existing FIFO[\s\S]*without duplicating committed or pending steps or blanket-cancelling queued work/);
  });

  it("forbids thread polling and re-reads the hard rules after compaction", () => {
    const agents = read("AGENTS.md").replace(/\s+/g, " ");
    const live = read("docs/LIVE-VALIDATION.md").replace(/\s+/g, " ");
    for (const text of [skill, pilot, strategist].map((entry) => entry.replace(/\s+/g, " ")).concat(agents))
      expect(text).toMatch(/never call `list_threads`, `read_thread`, or `wait_threads`/i);
    expect(skill.replace(/\s+/g, " ")).toMatch(/after any context compaction, re-read your goal file and this file before any other call; the pilot then re-reads the ledger, and Astra the notebook index/i);
    expect(pilot).toMatch(/After any context compaction, re-read this file, `SKILL\.md`, and the ledger before any other call/);
    expect(strategist).toMatch(/After any context compaction, re-read this file, `SKILL\.md`, and `notebook\/README\.md` before any other call/);
    expect(live).toMatch(/The pilot's GO text names Astra's exact thread ID/);
    expect(live).toMatch(/Never call list_threads, read_thread or wait_threads; after any compaction re-read your goal file and SKILL\.md/);
  });

  it("keeps the notebook an Astra-written learning store, never a control channel", () => {
    const agents = read("AGENTS.md").replace(/\s+/g, " ");
    const flat = [skill, strategist].map((entry) => entry.replace(/\s+/g, " "));
    for (const text of [flat[0], agents]) {
      expect(text).toMatch(/not a broker, a second ledger, or a control channel/);
      expect(text).toMatch(/at most 2 KB[\s\S]*about 64 KB/);
    }
    expect(flat[0]).toMatch(/Astra alone writes it/);
    expect(flat[0]).toMatch(/never imported or copied external content, and never world coordinates/);
    expect(flat[1]).toMatch(/never import or copy external content/);
    expect(flat[1]).toMatch(/Notes never carry instructions for the pilot; those travel only in the ledger/);
    expect(pilot).toMatch(/Read the notes it names \(paths relative to the ledger's directory\) and no other notebook file/);
    expect(pilot).toMatch(/Never write `operations\.json` or the notebook/);
  });

  it("keeps the body busy and the ledger read at its checkpoints", () => {
    expect(pilot).toMatch(/Never end a turn with an empty FIFO/);
    expect(skill).toMatch(/The pilot never ends a\s+turn with an empty FIFO/);
    expect(pilot).toMatch(/An inspection or scouting walk is not productive/);
    expect(pilot).toMatch(/Travel to placements you have already checked does not end a plan/);
    expect(pilot).toMatch(/with `connect_entities` \(up to 25 tiles per call\)/);
    expect(pilot).toMatch(/at every report checkpoint, after every compaction, and immediately before any manual service batch/);
    expect(pilot).toMatch(/about 30,000 game ticks[\s\S]*Re-read the ledger just before/);
    expect(strategist).toMatch(/Revise the ledger only when NOW, NEXT, LATER, a package, or an assumption changes/);
    expect(strategist).toMatch(/Drop a package once the pilot reports it queued, or once fresh reads show its placements already standing/);
    for (const text of [pilot, strategist]) expect(text).toMatch(/A second hand batch of the same item (?:is|counts as) a service cycle/);
    expect(pilot).not.toMatch(/no safe successor/);
  });

  it("states which physical calls hold the only slot and keeps the launch block transport-complete", () => {
    const server = read("companion/src/mcp/server.ts");
    expect(server).toMatch(/run_plan[\s\S]*block until the plan is terminal/);
    expect(server).toMatch(/queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot/);
    const live = read("docs/LIVE-VALIDATION.md");
    expect(live).not.toMatch(/mcp_servers\.[a-z-]+\.enabled=/);
    expect(live).toMatch(/session-launcher --name factorio-strategist --model gpt-6-astra --reasoning-effort medium --fast off/);
    expect(live).toMatch(/mcp_servers\.factorio-readonly=\{command=[^}]*args=\["--surface","read-only"\][^}]*enabled_tools=/);
    expect(pilot).not.toMatch(/mcp_servers/);
  });

  it("lets Astra design coupled layouts as validated packages that Luna queues unchanged", () => {
    const agents = read("AGENTS.md");
    expect(strategist).toMatch(/Design every coupled layout yourself/);
    expect(strategist).toMatch(/one `can_place` batch[\s\S]*`overlaps_batch`/);
    expect(strategist).toMatch(/Coordinates appear only inside validated build packages; NOW, NEXT, and LATER stay coordinate-free/);
    expect(strategist).toMatch(/owned-entity removal[\s\S]*never movement, pickup, resource mining, or crafting/);
    expect(strategist).toMatch(/Every ledger update restates them/);
    expect(pilot).toMatch(/design that one coupled connection yourself/);
    expect(pilot).toMatch(/batched `can_place`[\s\S]*`queue_plan` its steps unchanged/);
    expect(pilot).toMatch(/never repair a package's geometry/);
    expect(agents).toMatch(/designs every coupled\s+layout as a validated build package/);
    expect(pilot).toMatch(/jq -c '\{revision, source_tick, run, assumptions, NOW: \.task_list\.NOW, build_packages\}'/);
    expect(strategist).toMatch(/completes a segment ends with a `wait_for_item` on the terminal output followed by a validation step/);
    expect(strategist).toMatch(/A segment is complete only when every node has a physical feed, fuel included/);
    expect(skill).toMatch(/transfer window opens\s+when the step starts/);
    expect(skill).toMatch(/one exact\s+node position is\s+enough/);
    for (const text of [agents, skill, pilot]) expect(text).toMatch(/under about 300\s+bytes/);
    expect(pilot).toMatch(/A report checkpoint is a package queued or falsified, a validation result, a falsified ledger assumption or note, a supervisor stop, or about three minutes of game time \(10,800 ticks\) since your last report/);
    expect(pilot).toMatch(/never a correction or follow-up/);
  });

  it("lets a located structural row win and treats flow-only failures as one longer re-validation", () => {
    const flat = [pilot, strategist, skill].map((entry) => entry.replace(/\s+/g, " "));
    for (const text of [flat[1], flat[2]]) expect(text).toMatch(/located structural row (?:always wins|is repaired)/);
    expect(flat[0]).toMatch(/only at a located structural blocker and its `related_edge`/);
    for (const text of [flat[0], flat[2]]) {
      expect(text).toMatch(/every row is throughput, transient, or evidence/);
      expect(text).toMatch(/(?:\(at most 300 seconds\)|longer `duration_seconds` \(at most 300\))/);
    }
    expect(flat[2]).toMatch(/Check a structural relationship diagnostic against the component's edges first; once the edge is confirmed missing it is a located structural row/);
    expect(skill).toMatch(/`class` structural, throughput, transient, or\s+evidence/);
    expect(flat[2]).toMatch(/An evidence row \(an ambiguous diagnostic included\) is a hypothesis\. Inspect locally, but never rotate, remove, or move anything for it/);
    expect(pilot).toMatch(/if it fails again, report `false-negative <package>`/);
    expect(strategist).toMatch(/On `false-negative <package>`, record a suspected validator false negative in `assumptions`/);
    expect(flat[2]).toMatch(/`FACTORY_COMPONENT_NOT_READY` \(stage `readiness`\)[\s\S]*segment's existing buffer or consumer[\s\S]*Only `physical_source_downstream_path_unproven`/);
    expect(pilot).toMatch(/Inventory-proven `blocked_output` means the terminal buffer is full: empty it as a named bridge or report it, and never add a chest or sink/);
  });

  it("keeps the intro's hints overridable and removal guarded", () => {
    const knowledge = read(".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md").replace(/\s+/g, " ");
    expect(knowledge).toMatch(/hints are starting points that newer structured evidence may override/);
    expect(knowledge).toMatch(/fuel takeoff sits upstream so surplus never starves the fuel loop/);
    expect(knowledge).toMatch(/Each segment ends in a consumer or at most one terminal buffer[\s\S]*never by adding a chest or sink/);
    expect(knowledge).toMatch(/same structural blocker failing a segment twice means redesign/);
    expect(knowledge).toMatch(/fuel-return inserter over a full fuel slot\) is normal/);
    expect(knowledge).toMatch(/zero utilization at that sample only/);
    expect(normalized).not.toMatch(/exactly one terminal buffer/);
    expect(skill.replace(/\s+/g, " ")).toMatch(/A package removal step removes one owned entity \(`target_kind` `owned`, `expected_name`, count 1\)\. Removal is refused while the entity holds items, fuel included, or while hand-crafting is queued/);
    expect(pilot).toMatch(/or a removal whose target is gone\) and queue the rest in order/);
  });

  it("keeps durable gameplay instructions generic and text-only", () => {
    for (const text of [skill, pilot, strategist]) {
      expect(text).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
      expect(text).not.toMatch(/\b(?:first|start by)\s+(?:mine|craft|place|build|research)\b/i);
    }
    expect(skill.replace(/\s+/g, " ")).toMatch(/Never use screenshots as gameplay evidence, raw Lua or console, cheats, teleport/);
  });
});
