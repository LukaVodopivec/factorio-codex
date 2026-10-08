import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { READ_ONLY_TOOLS } from "../src/mcp/server.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relative: string) => fs.readFileSync(path.join(root, relative), "utf8");
const flat = (text: string) => text.replace(/\s+/g, " ");
const skill = read(".agents/skills/factorio-player/SKILL.md");
const pilot = read(".agents/skills/factorio-player/GOAL-PILOT-v1.md");
const strategist = read(".agents/skills/factorio-player/GOAL-STRATEGIST-v1.md");
const knowledge = read(".agents/skills/factorio-player/PLAYER-KNOWLEDGE-v1.md");
const reference = read(".agents/skills/factorio-player/FACTORIO-REFERENCE.md");
const benchmark = flat(read(".agents/skills/factorio-player/GOAL-BENCHMARK-v1.md"));
const agents = flat(read("AGENTS.md"));
const live = flat(read("docs/LIVE-VALIDATION.md"));
const readme = flat(read("README.md"));
const active = `${skill}\n${pilot}\n${strategist}`;
const normalized = flat(active).toLowerCase();
const registered = new Set([...read("companion/src/mcp/server.ts").matchAll(/registerTool\("([a-z_]+)"/g)].map((match) => match[1]));

describe("persistent two-brain coordination contract", () => {
  it("uses complete role-labelled MCP tables in pilot and supervisor launch examples", () => {
    for (const role of ["pilot", "supervisor"]) {
      expect(live).toContain(`mcp_servers.factorio={command="./scripts/start-factorio-mcp",args=["--role","${role}"],enabled=true,required=true,startup_timeout_sec=180,tool_timeout_sec=600}`);
      expect(live).not.toContain(`mcp_servers.factorio.args=["--role","${role}"]`);
    }
    expect(live).not.toContain("The pilot needs no MCP override");
  });

  it("keeps the instructions short, with shared rules only in SKILL.md", () => {
    // Per-role budgets, not one summed cap: what matters is how much each role
    // must attend to at once (instruction-following falls as rules pile up, and
    // a passage in the middle of a long read is easily lost), not context capacity.
    const bytes = (...texts: string[]) => texts.reduce((total, text) => total + Buffer.byteLength(text, "utf8"), 0);
    const benchmarkGoal = read(".agents/skills/factorio-player/GOAL-BENCHMARK-v1.md");
    for (const goal of [pilot, strategist, benchmarkGoal]) {
      expect(bytes(skill, goal)).toBeLessThan(25_000); // the compaction re-read set
      expect(bytes(skill, goal, knowledge)).toBeLessThan(30_500); // the startup set
    }
    expect(bytes(reference)).toBeLessThan(10_500);
    expect(skill).not.toMatch(/## Engineering reuse/);
    for (const text of [pilot, strategist]) expect(flat(text)).toMatch(/SKILL\.md's human takeover and stop rules apply/);
  });

  it("tells the benchmark strategist that ledger order needs no chaining and a partial predecessor cancels its successor", () => {
    expect(benchmark).toMatch(/The FIFO already runs packages in ledger order, so set after_package_id only for a real dependency/);
    expect(benchmark).toMatch(/a package whose predecessor ends partial, failed or cancelled is cancelled/);
  });

  it("states the showcase purpose and asks each role to say what it intends", () => {
    expect(flat(skill)).toMatch(/The run shows how two bots think about and architect a factory/);
    expect(flat(skill)).toMatch(/Before each decision, say in a sentence or two what you see and what you intend/);
    for (const text of [pilot, strategist]) expect(flat(text)).toMatch(/in a sentence or two/);
    expect(flat(skill)).toMatch(/The mod does the chores/);
    expect(agents).toMatch(/Project goal: Show how Codex bots think about and architect a Factorio factory/);
  });

  it("selects pilot gpt-6-luna/low/Fast and strategist gpt-6.1-sol/medium/normal around one writer, body, and FIFO lane", () => {
    expect(active).toMatch(/gpt-6-luna[\s\S]*low[\s\S]*fast mode enabled/i);
    expect(active).toMatch(/gpt-6\.1-sol[\s\S]*medium[\s\S]*normal speed/i);
    expect(active).not.toMatch(/gpt-6-astra/);
    expect(active).toMatch(/pilot[\s\S]*sole gameplay writer/i);
    expect(normalized).toMatch(/one body, one physical fifo/);
    expect(normalized).toMatch(/exactly one physical mcp call may be in flight/);
    expect(strategist).toMatch(/never (?:call|use)[\s\S]*(?:movement|mining|crafting|placement|queue|cancel|stop)/i);
  });

  it("gives the strategist exactly the read-only surface, with layout checks as dry runs", () => {
    for (const tool of READ_ONLY_TOOLS) expect(strategist).toContain(`\`${tool}\``);
    expect(strategist).toMatch(/mechanically read-only[\s\S]*never enter[\s\S]*physical FIFO/i);
    expect(strategist).not.toMatch(/`(?:walk_to|mine|craft_items|place_entity|insert_items|extract_items|set_recipe|start_research|queue_plan|run_plan|get_items|stop)`/);
    expect(live).toContain(`enabled_tools=[${READ_ONLY_TOOLS.map((tool) => `"${tool}"`).join(",")}]`);
  });

  it("makes factory_status the single read and next_event the only wait", () => {
    expect(flat(skill)).toMatch(/`factory_status` is the single routine read/);
    for (const state of ["running", "starved", "output_full", "no_fuel", "no_power", "no_heat", "disabled", "idle"]) expect(skill).toContain(`\`${state}\``);
    for (const event of ["plan_ended", "queue_empty", "new_problem", "package_failed", "orders_changed", "human_hold_started", "human_hold_ended"])
      expect(skill).toContain(`\`${event}\``);
    expect(flat(pilot)).toMatch(/Call `next_event` \(up to 120 s\) with `next_action`'s `since_tick` or the last `tick` seen/);
    expect(flat(pilot)).toMatch(/Never poll `plan_status`, `factory_status`, or any read in a loop/);
    expect(flat(strategist)).toMatch(/Never poll in a loop/);
  });

  it("drops validation, proofs, evidence classes, reports, and ledger-revision protocol", () => {
    for (const text of [skill, pilot, strategist, knowledge]) {
      expect(text).not.toMatch(/validate_factory_component|duration_seconds|autonomous_end_to_end|evidence class|evidence_class|fresh_local_exact|character_transfer_observed|validation window|service debt|report checkpoint|jq -c|send_message_to_thread` to the exact thread/);
    }
    expect(flat(skill)).toMatch(/Do not monitor, prove, or keep books/);
    expect(flat(skill)).toMatch(/A line is good when `factory_status` says `running`; expansion never waits for more proof than that/);
    expect(flat(pilot)).toMatch(/\*\*No reports\.\*\* You send no messages to the strategist/);
    expect(agents).toMatch(/There are no pilot reports, ledger reads by shell, revision checks, or package revalidation/);
    expect(agents).not.toMatch(/steam gate|validate_factory_component|under about 300 bytes/);
    expect(live).not.toMatch(/### Live steam gate before GO|## Full graph and downstream acceptance validation|supervision_record\.py steam-gate/);
    expect(readme).not.toMatch(/validate_factory_component` uses|FACTORY_COMPONENT_NOT_READY|steam gate/);
  });

  it("keeps packages out of the ledger before GO and gives package_failed to the strategist alone", () => {
    expect(flat(strategist)).toMatch(/Every ledger write before `GO`, the init included, has `build_packages: \[\]`; write your first package only after `GO`/);
    expect(flat(strategist)).toMatch(/all listed packages together at most 8 KB; drop a package from the list once `activity_log` shows it queued/);
    expect(strategist).not.toMatch(/1-200 steps, at most 8 KB/);
    expect(agents).toMatch(/The strategist writes no build package before `GO`/);
    expect(live).toMatch(/`build_packages: \[\]` \(required for every write before `GO`/);
    expect(flat(pilot)).toMatch(/On `package_failed`, leave the redesign to the strategist and never rebuild a package's purpose or geometry yourself/);
    expect(flat(pilot)).toMatch(/Any result with `body\.fifo_empty` true \(and no human hold\) means the body is idle: queue work before waiting again/);
  });

  it("re-observes after an explicit stop until the body is idle", () => {
    expect(agents).toMatch(/waits at least 2 s, re-observes `observe_local`[\s\S]*calls `stop` again and re-observes until idle; then finishes the recorder/);
    expect(live).toMatch(/wait at least 2 s[\s\S]*call factorio `stop` again and re-observe until idle; only then run recorder FINISH/);
  });

  it("documents the writer fence and unknown outcomes for a replacement, and keeps them out of the gameplay rules", () => {
    expect(live).toMatch(/refuses every write that carries an older one with `WRITER_RETIRED`/);
    expect(live).toMatch(/after that only `cancel` does, so the supervisor's\s+`stop` always works/);
    expect(live).toMatch(/The supervisor's process \(`--role supervisor`, full surface\) claims nothing\s+and labels its writes/);
    expect(live).toMatch(/must not start the factorio MCP with `--role pilot`\s+or inherit `FACTORIO_CODEX_ROLE=pilot`/);
    expect(live).toMatch(/supervisor's factorio MCP runs with `--role supervisor`/);
    expect(live).toMatch(/The fence cancels nothing: plans the old pilot already queued stay committed/);
    expect(live).toMatch(/`status: "outcome_unknown"` with code `OUTCOME_UNKNOWN`: the call may or may not have run in the game/);
    expect(active).not.toMatch(/writer generation|WRITER_RETIRED|client_key/);
  });

  it("lets packages queue themselves while the strategist stays the sole ledger writer", () => {
    expect(flat(skill)).toMatch(/The pilot's bridge queues each new package into the FIFO itself, in ledger order, after the mod's placement check, with no pilot turn/);
    expect(flat(skill)).toMatch(/the ledger is the strategist's only channel to the pilot/);
    expect(strategist).toMatch(/ledger is your only channel to the pilot; never message the pilot/i);
    expect(agents).toMatch(/The ledger is the strategist's only channel to the pilot/);
    expect(agents).toMatch(/queues each new package into the FIFO by itself, in ledger order, as a plan with source `package:<id>`/);
    expect(flat(pilot)).toMatch(/The bridge queues the strategist's packages, not you/);
    expect(pilot).toMatch(/Never write `operations\.json` or `notebook\/strategist\/`/);
    expect(flat(strategist)).toMatch(/Size packages as whole blocks: `build_layout` or `blueprint_place` steps, never single placements/);
    expect(flat(strategist)).toMatch(/Keep at least one package queued ahead so the body never waits for a design/);
    expect(flat(strategist)).toMatch(/Rewrite the ledger only when NOW changes, a new package is ready, or labs need research, about six times an hour at most; never to record progress, which `activity_log` holds/);
    expect(flat(strategist)).toMatch(/Give each package a new `package_id`/);
    expect(flat(strategist)).toMatch(/`essential_prerequisite` is one outcome sentence \(at most 160 characters\)/);
    for (const field of ["objective", "strategic_reason", "completion_condition", "essential_prerequisite"]) expect(strategist).toContain(`\`${field}\``);
    expect(`${strategist}\n${live}`).not.toMatch(/companion\/dist\/cli\.js ledger-apply/);
  });

  it("makes the pilot the foreman who queues goal-level work", () => {
    expect(flat(pilot)).toMatch(/You are the foreman, not the hands/);
    expect(flat(pilot)).toMatch(/Queue multi-step, goal-level work[\s\S]*?Never queue single-step or walk-only plans/);
    expect(flat(skill)).toMatch(/These actions walk to their own targets: never queue a `walk_to` before them\. `wait_for_item` does not walk and reads within 30 tiles or charted own machines/);
    expect(flat(pilot)).toMatch(/Hand-mining and hand-crafting take the body's time; drills and assemblers work while the body does something else\. The packs for the research that unlocks assemblers can only be hand-crafted\./);
    expect(flat(strategist)).toMatch(/Only the packs for the research that unlocks assemblers must be hand-crafted\./);
    expect(flat(pilot)).toMatch(/Pass `after_plan_id` only when a plan needs the earlier plan's effects/);
    for (const action of ["get_items", "build_layout", "blueprint_place"]) expect(skill).toContain(`\`${action}\``);
  });

  it("lets every role, benchmark roles included, know that Automation needs hand-crafted science that never scores", () => {
    const roleFiles = [skill, pilot, strategist, knowledge, reference, benchmark].map(flat);
    for (const text of roleFiles) expect(text).not.toMatch(/never (?:hand-craft|plan hand-crafted) science/i);
    const benchmarkGoal = flat(benchmark);
    expect(benchmarkGoal).toMatch(/A hand-crafted item or pack never scores itself; only what machines make and labs consume counts\. Yet Automation, the research that unlocks assemblers, can only use hand-crafted packs, since no assembler exists before it\./);
    expect(flat(reference)).toMatch(/Assemblers are locked until the Automation research completes, and its packs exist before any assembler can make them: those few packs are hand-crafted\. They do not score/);
  });

  it("tells the benchmark strategist to keep a package queued ahead of the pilot", () => {
    const strategistDuties = flat(benchmark).match(/Strategist \(multi-agent only\):[^\n]*?(?= Advisors \()/)?.[0] ?? "";
    expect(strategistDuties).toMatch(/Keep a package queued ahead of the pilot so the body never waits for a design\./);
  });

  it("teaches the 0.21.1 building tools in plain words", () => {
    const flatSkill = flat(skill);
    expect(flatSkill).toMatch(/when a build works, store it once \(`blueprint_capture`[\s\S]*stamp it again with `blueprint_place`, never piece by piece/);
    expect(flatSkill).toMatch(/Blueprints belong to this run; `blueprint_export` is a string for notes, never imported/);
    expect(flatSkill).toMatch(/`move_entity` picks up one of your buildings with its contents/);
    expect(flatSkill).toMatch(/use `explore`[\s\S]*Never scout with chains of walks/);
    expect(flatSkill).toMatch(/`connect_entities` lays one belt, pipe, or pole route of up to 200 pieces[\s\S]*a long route is one call/);
    expect(flatSkill).toMatch(/Crafting runs in the background: `craft_items` returns at once/);
    expect(flatSkill).toMatch(/The ledger writer picks research: the bridge queues the ledger's `research` list once per revision \(`activity_log` shows it\)/);
    expect(flatSkill).not.toMatch(/`start_research` takes a list/);
    expect(flat(strategist)).toMatch(/After `GO`, list up to seven technologies in queue order as the ledger's `research`/);
    expect(flat(strategist)).toMatch(/When `research_finished` or `research_idle` says labs are idle, write the next list/);
    // Benchmark roles read GOAL-BENCHMARK instead: its ledger writer, solo pilot or strategist, lists research.
    const benchmark = flat(read(".agents/skills/factorio-player/GOAL-BENCHMARK-v1.md"));
    const research = "After GO, keep labs busy by listing research (up to seven technologies in queue order) as the ledger's `research`; the bridge queues it.";
    expect(benchmark).toContain(`queue your plans directly, so nothing is queued twice. ${research}`);
    expect(benchmark).toContain(`build packages with their surface. ${research}`);
    expect(flatSkill).toMatch(/`plan_ended` carries each step's outcome and the inventory change/);
    expect(flatSkill).toMatch(/Any item may be used anywhere, crafted or machine-made/);
    expect(skill).not.toMatch(/at most 25 pieces/);
    for (const tool of ["blueprint_capture", "blueprint_place", "move_entity", "explore", "connect_entities", "deconstruct_area", "upgrade_area", "copy_settings", "build_ghosts", "start_research"])
      expect(registered).toContain(tool);
    expect(flat(pilot)).toMatch(/never a `walk_to` before an action: actions walk to their own targets/);
    expect(flat(pilot)).toMatch(/never wait for a package with an empty queue/);
    expect(flat(pilot)).toMatch(/A machine fed or emptied by hand, like a line with `hand_transfers`, is not automated: each hand transfer costs body time that a belt, inserter, or chest would not\./);
    expect(flat(pilot)).toMatch(/You send no messages to the strategist, nor to anyone else after `GO`/);
    expect(flat(pilot)).toMatch(/mark it blocked only when `factory_status` shows no productive action and no order is open/);
    expect(flat(strategist)).toMatch(/a package may start with `blueprint_capture` steps \(made after its `after_package_id` package ends\)/);
    expect(flat(strategist)).toMatch(/Package steps walk to their own targets: never add walk steps/);
    expect(flat(strategist)).toMatch(/Packages written before an emergency stop stay held until you rewrite the ledger/);
    for (const text of [agents, live, readme]) expect(text).not.toMatch(/latch/i);
    expect(agents).toMatch(/It never waits for a pilot plan: it holds packages only during a human hold and while the ledger is older than the last `stop`/);
    expect(live).toMatch(/It never waits for a pilot plan: it holds packages only during a human hold and while the ledger file is older than the last `stop`/);
  });

  it("keeps the opening, automation-first, and power hints as principles", () => {
    const flatKnowledge = flat(knowledge);
    expect(flatKnowledge).toMatch(/Plates gate every machine, and fuel pays only when it feeds something that makes progress\. Choose what to automate from what you carry and the patches in view/);
    expect(flat(strategist)).toMatch(/Judge progress by what machines make and by research on machine-made science, not by ore piles/);
    expect(flatKnowledge).toMatch(/Ore or plates piling up in chests should feed more machines .* a pile is not progress/);
    expect(flat(strategist)).toMatch(/This is a principle, not a build or technology order/);
    expect(flat(strategist)).toMatch(/A power shortage \(`factory_status` power satisfaction below 100%\) slows every machine on the network, so new electric consumers add little until generation catches up; weigh that when choosing NOW/);
    expect(flat(strategist)).not.toMatch(/more generation is NOW|before any other expansion/);
    expect(flatKnowledge).toMatch(/A shortage \(`power` satisfaction below 100%\) slows every machine on the network, so new consumers add little until generation catches up/);
    expect(flatKnowledge).not.toMatch(/add generation whenever/);
    expect(flatKnowledge).toMatch(/The principles are generic ways to plan ahead that newer structured evidence may override\. None is a build order/);
  });

  it("covers the Space Age horizon without fixing the planet order", () => {
    for (const horizon of ["Nauvis", "orbital platform", "Vulcanus", "Fulgora", "Gleba", "Aquilo", "Solar System Edge"])
      expect(flat(active)).toContain(horizon);
    expect(normalized).toMatch(/never prescribe a fixed planetary order/);
    expect(normalized).toMatch(/principal objective is to maximize useful, sustained, autonomous production growth/);
    expect(normalized).toMatch(/research normally consumes surplus/);
  });

  it("shows the thinking in the game as output only", () => {
    expect(agents).toMatch(/spawned with `-c model_reasoning_summary=detailed`/);
    expect(agents).toMatch(/game chat never controls the bot, and the panel never triggers a takeover hold/);
    expect(live).toMatch(/codex --model gpt-6-luna -c model_reasoning_effort=low -c service_tier=fast -c features\.fast_mode=true \\? ?-c model_reasoning_summary=detailed/);
    expect(live).toMatch(/codex --model gpt-6\.1-sol -c model_reasoning_effort=medium \\? ?-c model_reasoning_summary=detailed/);
    expect(live).not.toMatch(/session-launcher|session-status|codex-real|relay_steer/);
    expect(live).toMatch(/mcp_servers\.factorio-readonly=\{command=[^}]*args=\["--surface","read-only"[^\]]*\][^}]*enabled_tools=/);
    expect(live).not.toMatch(/mcp_servers\.[a-z-]+\.enabled=/);
    for (const text of [readme, live]) expect(text).toMatch(/--pilot-rollout[\s\S]*--strategist-rollout/);
    expect(readme).toMatch(/The feed is output only: game chat never controls the bot/);
  });

  it("starts every documented role session without web search, multi-agent tools or memories", () => {
    // Keys and their effect verified against Codex CLI 0.159.2; features.multi_agent=false left the tools in place,
    // and agents.enabled=false alone kept them when a user config enables multi_agent_v2.
    const isolation = [`-c 'web_search="disabled"'`, "-c agents.enabled=false", "-c features.memories=false", "-c features.multi_agent_v2=false"];
    const launches = (relative: string) => {
      const text = read(relative).replace(/\\\n\s*/g, " ");
      return [...text.matchAll(/^codex (.+)$/gm), ...text.matchAll(/`codex ([^`]+)`/g)].map((match) => match[1]);
    };
    const documented = { "README.md": 3, "docs/LIVE-VALIDATION.md": 2, "prompts/pilot.md": 1 };
    for (const [relative, count] of Object.entries(documented)) {
      const lines = launches(relative);
      expect(lines, relative).toHaveLength(count);
      for (const line of lines) {
        for (const flag of isolation) expect(line, relative).toContain(flag);
        expect(line).not.toMatch(/--search|web_search="(?:cached|indexed|live)"|features\.multi_agent=|features\.shell_tool=false|agents\.enabled=true|features\.multi_agent_v2=true|features\.memories=true/);
      }
    }
    expect(live).toMatch(/`web_search="disabled"` removes the web tool[\s\S]*`agents\.enabled=false` removes the multi-agent tools[\s\S]*`features\.memories=false` stops stored memories[\s\S]*`agents\.enabled=false` alone does not cover `multi_agent_v2`[\s\S]*the strategist keeps `ledger-apply`[\s\S]*the shell can still read earlier run\s+folders/);
  });

  it("keeps continuation native and forbids thread tools, with a compaction re-read", () => {
    for (const text of [skill, pilot, strategist].map(flat).concat(agents))
      expect(text).toMatch(/never call `list_threads`, `read_thread`, or `wait_threads`|never call `list_threads`, `read_thread`, or `wait_threads`/i);
    expect(flat(skill)).toMatch(/After any context compaction, re-read your goal file and this file before any other call, then your notebook index/);
    expect(pilot).toMatch(/After any context compaction, re-read this file and `SKILL\.md` before any other call, then your notebook index/);
    expect(strategist).toMatch(/After any context compaction, re-read this file, `SKILL\.md`, and `notebook\/strategist\/INDEX\.md` before any other call/);
    expect(flat(skill)).toMatch(/Ending the turn is neither a pause nor a completion/);
    expect(pilot).toMatch(/Ending a turn never calls `update_goal`/);
    expect(agents).toMatch(/native goal continuation, not a supervisor assignment per batch/i);
    expect(`${pilot}\n${strategist}`).toMatch(/Never mark the goal complete without milestone proof/);
    expect(live).toMatch(/The pilot's GO text names the strategist's exact thread ID/);
    expect(live).toMatch(/Never call list_threads, read_thread or wait_threads; after any compaction re-read your goal file and SKILL\.md, then your notebook INDEX\.md/);
  });

  it("reserves stop to the supervisor", () => {
    expect(flat(skill)).toMatch(/Never call the `stop` tool: it is the supervisor's emergency cancellation/);
    expect(pilot).toMatch(/To abandon a stalled wait, queue the corrective plan without `after_plan_id`: it runs while the wait is parked\. Otherwise let the wait's bounded timeout end it/);
    expect(pilot).toMatch(/Retain completed physical effects; there is no rollback/);
    expect(agents).toMatch(/`stop` is the supervisor's recorded emergency cancellation \(the pilot never calls it\)/);
    expect(agents).toMatch(/calls factorio `stop`[\s\S]*pauses both role goals/);
    expect(live).toMatch(/call factorio `stop`[\s\S]*`\/goal pause`[\s\S]*`turn\/interrupt`[\s\S]*server stop/i);
    expect(live).toMatch(/only then start the recorder/);
  });

  it("treats a human_control hold as the human playing, never idleness or failure", () => {
    expect(flat(skill)).toMatch(/`human_control: true` \([^)]*\) means the player is playing the body/);
    expect(flat(skill)).toMatch(/A hold is neither idleness nor failure\. Never fight for the body; wait for `human_hold_ended`/);
    expect(flat(skill)).toMatch(/A direct tool call that fails with a human-hold reason is retried after the hold/);
    expect(strategist).toMatch(/A `human_control` hold is the player playing the body; it is neither idleness nor failure/);
    expect(agents).toMatch(/A hold is neither idleness nor failure\. The supervisor never nudges or replaces during a hold, records it as human input/);
    expect(live).toMatch(/### Takeover rehearsal before GO/);
    expect(live).toMatch(/\| `human_control: true` \(the human player playing the body\) \| No idle claim, nudge, or replacement\./);
    expect(live).toMatch(/The rehearsal needs the human player's real input, so it runs only when the supervisor's assignment says in so many words that the human player has agreed to do the takeover rehearsal now/);
  });

  it("adapts idleness evidence so upkeep is not pilot activity", () => {
    expect(agents).toMatch(/`active_task` absent or with source `upkeep`, `queue_depth == 0`, and `crafting\.queue_size == 0`/);
    expect(agents).toMatch(/Upkeep is the mod's work, not pilot activity/);
    expect(agents).toMatch(/except changes made by an `upkeep` plan/);
    expect(live).toMatch(/`active_task` absent or with `source: "upkeep"`/);
    expect(live).toMatch(/Only an `upkeep` plan active/);
    expect(flat(agents)).toMatch(/The strategist, not the supervisor, turns low growth into NOW/);
  });

  it("gives each role its own notebook folder as a learning store, never a control channel", () => {
    for (const text of [flat(skill), agents]) {
      expect(text).toMatch(/not a broker, a second ledger, or a control channel/);
      expect(text).toMatch(/[Ee]ach role writes only its own folder and reads anything/);
      expect(text).toMatch(/no total size cap/i);
      expect(text).toMatch(/exact positions, maps, and infrastructure inventories/);
      expect(text).toMatch(/nothing is read from another run/i);
      expect(text).toMatch(/Notes are knowledge, never instructions/);
    }
    expect(flat(skill)).toMatch(/`notebook\/strategist\/` and `notebook\/pilot\/`/);
    expect(flat(strategist)).toMatch(/Notes never carry instructions for the pilot; those travel only in the ledger/);
    expect(agents).toMatch(/ledger remains the only command channel and the strategist its only writer/);
    expect(live).toMatch(/each role writes one note and its `INDEX\.md` in its own folder and reads back the other role's note/);
    for (const text of [flat(skill), flat(pilot), flat(strategist), agents, readme, live]) expect(text).toMatch(/`(?:notebook\/(?:strategist|pilot)\/)?INDEX\.md`/);
  });

  it("teaches the 0.22.0 tools, power model and build-time settings in plain words", () => {
    const flatSkill = flat(skill);
    expect(flatSkill).toMatch(/`add_to_cover` lists both ways to cover demand, `steam` \(engines, boilers, pumps\) and `solar` \(panels, accumulators\): you choose/);
    expect(flatSkill).toMatch(/`sections: \['logistics'\]` shows robot networks/);
    expect(flatSkill).toMatch(/`configure_entity` sets what a building's window sets[\s\S]*changes only what you name/);
    expect(flatSkill).toMatch(/Give `build_layout` entities `settings` \(and `mirror`, and `belt_to_ground_type: input\|output` for an underground belt\) instead to build a sorter or a mall already configured/);
    expect(flatSkill).toMatch(/`place_tiles` lays landfill[\s\S]*nearest tiles first, walking along[\s\S]*`check_only` counts the items/);
    expect(flatSkill).toMatch(/`set_requests` sets what a requester or buffer chest asks robots for\. Only robots deliver/);
    expect(flatSkill).toMatch(/`extract_items` and `insert_items` take an `inventory`/);
    expect(flatSkill).toMatch(/Plan steps only: `equip` wears armor[\s\S]*`flush_fluid` empties a pipe or tank system/);
    for (const tool of ["configure_entity", "place_tiles", "set_requests"]) expect(registered).toContain(tool);
    for (const step of ["equip", "flush_fluid"]) expect(registered).not.toContain(step);
    expect(flat(strategist)).toMatch(/a site cut off by water starts with a `place_tiles` landfill step; steps after it or after a removal \(mine, deconstruct, move\), and a successor package, are checked only when they run\. Give layout entities their `settings`/);
    expect(flat(knowledge)).toMatch(/solar panels with accumulators are an option that needs no fuel/);
    expect(flat(knowledge)).toMatch(/Filter inserters and filtered splitters sort mixed belts, such as Fulgora's scrap/);
    expect(flat(knowledge)).toMatch(/Landfill joins a site across water; Aquilo's ocean takes ice platform/);
  });

  it("teaches the 0.22.2 rocket and platform tools and the remote rule in plain words", () => {
    const flatSkill = flat(skill);
    expect(flatSkill).toMatch(/\*\*To space\.\*\*/);
    expect(flatSkill).toMatch(/A rocket silo needs power and stacks 50 rocket parts \(each a processing unit, low density structure, and rocket fuel\)/);
    expect(flatSkill).toMatch(/`create_platform` registers a platform over the body's planet at once\. It waits until a rocket brings its starter pack: launching the pack creates the platform/);
    expect(flatSkill).toMatch(/`launch_rocket` loads a ready rocket with the cargo you name[\s\S]*with no rocket ready it fails at once with the part count/);
    expect(flatSkill).toMatch(/`platform_status` is your platform screen[\s\S]*`ghosts\.missing`: what must still go up/);
    expect(flatSkill).toMatch(/Platforms are built only from ghosts the hub fulfils from its own items/);
    expect(flatSkill).toMatch(/With `target: \{platform\}`, `set_requests` sets what the hub keeps stocked[\s\S]*`get_items` takes from a landing pad/);
    expect(flatSkill).toMatch(/Space platforms are the one exception[\s\S]*everything on a planet keeps reach/);
    expect(flatSkill).toMatch(/Remote: `create_platform` and every step with `platform`/);
    for (const event of ["rocket_ready", "rocket_launched", "cargo_delivered", "platform_state_changed"]) expect(skill).toContain(`\`${event}\``);
    for (const tool of ["platform_status", "create_platform", "launch_rocket", "set_requests"]) expect(registered).toContain(tool);
    expect(READ_ONLY_TOOLS).toContain("platform_status");
    expect(flat(strategist)).toMatch(/A platform package holds `create_platform` and the starter-pack `launch_rocket`; its `build_layout` or `blueprint_place` package with `platform` comes once `platform_status` shows a hub/);
    expect(flatSkill).toMatch(/marks entities and foundation tiles touching existing foundation, after `cargo_delivered`/);
    expect(flatSkill).toMatch(/as direct tools `set_recipe`, `configure_entity` and `set_requests` answer at once, the rest queue in the FIFO/);
    expect(agents).toMatch(/Space platforms are the exception: `create_platform` and steps that name a `platform` act on that platform without the body, as the game's remote view does; everything on a planet keeps physical reach/);
  });

  it("teaches the 0.22.3 planets, travel, surfaces and the win in plain words", () => {
    const flatSkill = flat(skill);
    expect(flatSkill).toMatch(/\*\*Other planets\.\*\*/);
    for (const planet of ["Vulcanus", "Fulgora", "Gleba", "Aquilo"]) expect(flatSkill).toMatch(new RegExp(`- Each planet adds a science pack and one constraint\\.[\\s\\S]*${planet}`));
    expect(flatSkill).toMatch(/`set_platform_route` sets a platform's stops \(unlocked locations, each with the game's wait conditions\) at once, without the body/);
    expect(flatSkill).toMatch(/`travel \{to: "platform:<n>"\}` rides the next ready rocket[\s\S]*`travel \{to: "<planet>"\}` waits aboard until the platform reaches the planet, then lands you by pod/);
    expect(flatSkill).toMatch(/Queue the destination's work in the same plan after the `travel` step/);
    expect(flatSkill).toMatch(/Nauvis keeps running and stays readable while you are away, but upkeep reaches 96 tiles from the body/);
    expect(flatSkill).toMatch(/You land with only what you carry\. A cargo landing pad's requests pull items from platforms in orbit, and leaving a planet takes a rocket from a silo there/);
    expect(flatSkill).toMatch(/The game is won when any of our platforms reaches the solar system edge; the body need not be aboard/);
    expect(flatSkill).toMatch(/Each package names its `surface` \(a planet\) and queues only while the body is there[\s\S]*`waiting_surface`, which is not a failure\. Only the pilot travels: a package never holds `travel`/);
    expect(flatSkill).toMatch(/A `research_idle` problem means no research runs and labs are idle/);
    for (const word of ["frozen", "travel_phase", "platform_arrived", "body_surface_changed", "SURFACE_LEFT", "roots", "surface_limited"]) expect(skill).toContain(`\`${word}\``);
    for (const tool of ["travel", "set_platform_route"]) {
      expect(registered).toContain(tool);
      expect(READ_ONLY_TOOLS).not.toContain(tool as never);
    }
    expect(flat(pilot)).toMatch(/\*\*Other planets\.\*\* Travel is yours alone/);
    expect(flat(strategist)).toMatch(/plus `surface` \(its planet; a platform package's launch planet\)/);
    expect(flat(strategist)).toMatch(/Only the pilot travels: a package never holds `travel`/);
    expect(agents).toMatch(/The body reaches another planet only through `travel` \(rocket, platform, landing pod\), never by teleport/);
    expect(agents).toMatch(/a package never holds `travel`, which is the pilot's alone/);
    expect(agents).toMatch(/So is a `travel` step waiting for a rocket or for its platform to arrive; the body aboard a platform or in a cargo pod is neither a hold nor idle/);
    expect(readme).toContain(`The full surface has ${registered.size} tools; the read-only surface used by the strategist has ${READ_ONLY_TOOLS.length}`);
    expect(readme).toMatch(/with no research active no lab is fed, and `factory_status` shows a `research_idle` problem/);
    expect(readme).not.toMatch(/no planet-travel tools/);
    expect(live).toMatch(/For the 0\.22\.3 release \(other planets\), record these observable checks/);
  });

  it("allows this run's positions, forbids anything from another run, and reads remotely while acting needs reach", () => {
    expect(flat(skill)).toMatch(/A resumed save of the same factory continues its run\. Only coordinates from another run are forbidden/);
    expect(flat(skill)).toMatch(/cross-run coordinates \(from another run, an imported map, or seed knowledge\)/);
    expect(agents).toMatch(/Nothing is read from another run; a resumed save of the same factory continues its run/);
    expect(flat(knowledge)).toMatch(/nothing carries over to another run/);
    expect(flat(skill)).toMatch(/Reading is remote; acting needs reach\. Everything the force has charted may be read/);
    expect(agents).toMatch(/uncharted terrain through MCP\. Everything the force has charted may be read; acting still needs physical reach/);
    expect(flat(skill)).toMatch(/Never use screenshots as gameplay evidence, raw Lua or console, cheats, teleport/);
  });

  it("names only callable tools and documents the release's upgrade path", () => {
    const named = [...pilot.matchAll(/`tools\.mcp__factorio__([a-z_]+)`/g)].map((match) => match[1]);
    expect(named.length).toBeGreaterThan(0);
    for (const tool of named) expect(registered).toContain(tool);
    for (const tool of [...skill.matchAll(/`([a-z_]+)`/g)].map((match) => match[1]!))
      if (/^(?:get_items|build_layout|blueprint_place|factory_status|next_event|activity_log|queue_plan|run_plan|build_plan|connect_entities|place_entity|insert_items)$/.test(tool)) expect(registered).toContain(tool);
    expect(pilot).toContain("`tools.mcp__factorio__<tool>` with one prefix");
    expect(pilot).not.toMatch(/mcp__factorio__(?:mcp__|codex_tui__|send_message_to_thread|execution_settings)/);
    const server = read("companion/src/mcp/server.ts");
    expect(server).toMatch(/run_plan[\s\S]*block until the plan is terminal/);
    expect(server).toMatch(/queue_plan returns immediately, while run_plan and single physical tools hold the only physical slot/);
    expect(live).toMatch(/### Resume with a mod upgrade/);
    expect(live).toMatch(/completes as a no-op with code `REMOVED_ACTION`/);
  });

  it("enables the bots' thinking: an Architecture rule, a base plan, and principles instead of scripts", () => {
    const flatSkill = flat(skill);
    expect(skill).toMatch(/## Purpose\n[\s\S]*?\n## Architecture\n[\s\S]*?\n## Roles\n/);
    expect(skill.indexOf("## Architecture")).toBeLessThan(skill.indexOf("## Roles"));
    expect(flatSkill).toMatch(/Plan the base before siting any block, and keep that plan as the factory grows/);
    expect(flatSkill).toMatch(/A building on ore keeps drills off that ore, and a block with no free ground around it cannot grow or be reached/);
    expect(flatSkill).toMatch(/read the patch outlines \(`bbox` in `factory_status` patches\) and the dry run's `on_ore` report/);
    expect(flatSkill).toMatch(/The layout is your own design/);
    for (const field of ["on_ore", "mixed_ore", "open_fluid_ports", "resource_coverage"]) expect(skill).toContain(`\`${field}\``);
    expect(flatSkill).toMatch(/`find_placement` lists free spots nearest first/);
    expect(flat(strategist)).toMatch(/\*\*Base plan\.\*\* Keep a standing base plan \(SKILL\.md's Architecture\) as a note in `notebook\/strategist\/`, named in `INDEX\.md`/);
    expect(flat(strategist)).toMatch(/Revise it when a new patch, technology or planet changes the picture, and say why/);
    const solo = benchmark.match(/In a solo trial[^\n]*?(?= Strategist \()/)?.[0] ?? "";
    const duties = benchmark.match(/Strategist \(multi-agent only\):[^\n]*?(?= Advisors \()/)?.[0] ?? "";
    for (const text of [solo, duties]) expect(text).toMatch(/SKILL\.md's Architecture base plan in your notebook, named in its INDEX\.md/);
    expect(flat(pilot)).toMatch(/following NOW and SKILL\.md's Architecture/);
    expect(pilot).not.toMatch(/opening hint/);
    // The removed prescriptions stay out of every instruction file.
    for (const text of [skill, pilot, strategist, knowledge, reference, benchmark].map(flat)) {
      expect(text).not.toMatch(/first ten minutes|fuel-first|common fast planet order|About 10 iron|Opening scale|Research hint/i);
      expect(text).not.toMatch(/Automation, Logistics, Electronics/);
      expect(text).not.toMatch(/as early as research allows|Right after red and green science|as soon as their parts exist/);
      expect(text).not.toMatch(/steam needs water|whole blocks or this run's blueprints/i);
      expect(text).not.toContain("build_block");
    }
    for (const text of [agents, readme]) expect(text).not.toContain("build_block");
    expect(live).not.toMatch(/"build_block"|`build_block` `power`|each `build_block` kind/);
    expect(flat(knowledge)).toMatch(/\*\*Sizing\.\*\* Size a line from the rate you need: `production_requirements` with `per_minute`/);
    expect(flat(knowledge)).toMatch(/\*\*Research\.\*\* Choose research for what it unlocks at the current bottleneck\. In 2\.0 some technologies unlock by a trigger/);
    // The geometry facts a hand-designed layout needs, in the reference.
    const flatReference = flat(reference);
    expect(flatReference).toMatch(/## Geometry/);
    expect(flatReference).toMatch(/A mining drill drops its output onto the tile just past the edge it faces/);
    expect(flatReference).toMatch(/direction 0 picks up north and drops south/);
    expect(flatReference).toMatch(/One boiler makes steam for two steam engines/);
    expect(flatReference).toMatch(/An offshore pump stands at the shore/);
    // A boiler, not steam, needs water: Vulcanus makes steam from acid and calcite.
    for (const text of [flat(skill), flatReference]) expect(text).toMatch(/a boiler needs water/i);
    expect(flat(knowledge)).toMatch(/\*\*Compounding\.\*\* A producer pays back for every minute it runs, so one placed sooner returns more; parts left in the inventory return nothing/);
    expect(benchmark).toMatch(/Design coupled layouts yourself as build_layout steps or this run's blueprints/);
    // Every role reads the geometry at startup, and each pointer says it is there.
    for (const goal of [pilot, strategist]) expect(flat(goal)).toMatch(/\*\*Start and compaction\.\*\* Read `SKILL\.md`, `PLAYER-KNOWLEDGE-v1\.md`, `FACTORIO-REFERENCE\.md`/);
    expect(flatSkill).toMatch(/\[reference\]\(FACTORIO-REFERENCE\.md\) covers rates, geometry for your own layouts/);
    expect(benchmark).toMatch(/FACTORIO-REFERENCE\.md \(how rates, energy, flow problems, bootstrap dependencies, research and layout geometry work/);
    expect(agents).toMatch(/`FACTORIO-REFERENCE\.md` explains [^`]*the geometry of layouts/);
    expect(readme).toMatch(/a reference for rates and layout geometry \(`FACTORIO-REFERENCE\.md`\)/);
  });

  it("gives an unassisted run only mechanics, rates, harness rules and generic principles, never strategy", () => {
    // The owner publishes these runs as unassisted: no site, count, order, timing or opening the bots did not choose.
    for (const text of [skill, pilot, strategist, knowledge, reference, benchmark].map(flat)) {
      expect(text).not.toMatch(/Ore patches are for drills|go on free ground beside the patches|near your `GO` position/);
      expect(text).not.toMatch(/Hand-(?:craft|mine) only|hand-craft just those few|worth their crafting time early/i);
      expect(text).not.toMatch(/Build power before|Build fuel feeds instead|Prefer the cheapest entity|before power exists/);
      expect(text).not.toMatch(/heating towers first|turrets first|science feeds first|Bring in your inventory/);
      expect(text).not.toMatch(/Keep the first platforms minimal/);
      expect(text).not.toMatch(/mining row|smelting column|assembler row|fuel takeoff sits upstream/);
      expect(text).not.toMatch(/Speed hints|from fast play|size iron for green|placed early pays back/i);
      // Ratios are facts about what keeps what busy; a count to build is a guide.
      expect(text).not.toMatch(/\b(?:build|place|use) \d+ (?:electric |burner |stone )?(?:drills?|furnaces?|assemblers?)/i);
    }
    // Wiki-level ratio facts are present, phrased as how the game works.
    const flatKnowledge = flat(knowledge);
    expect(flatKnowledge).toMatch(/One electric drill's ore keeps 1\.6 stone furnaces busy/);
    expect(flatKnowledge).toMatch(/A full yellow belt carries the ore of 30 electric drills and keeps 48 stone furnaces busy/);
    expect(flatKnowledge).toMatch(/5 assemblers making red make as many packs as 6 making green/);
    expect(flatKnowledge).toMatch(/3 assemblers making copper cable keep 2 making electronic circuits busy/);
    expect(flatKnowledge).toMatch(/\*\*Space Age\.\*\*[^*]*Quality brings the edge no closer\./);
    const server = read("companion/src/mcp/server.ts");
    expect(server).not.toMatch(/hand-mining still helps|so it needs a connection/);
  });

  it("states hand service as a fact everywhere: a line served by hand is not automated and costs body time", () => {
    const server = flat(read("companion/src/mcp/server.ts"));
    for (const text of [skill, pilot, strategist, knowledge, reference, server, readme].map(flat))
      expect(text).not.toMatch(/needs a (?:connection|permanent (?:feed|supply))|not another (?:trip|hand transfer)/);
    expect(server).toMatch(/hand_transfers: served by hand twice or more in ten minutes, so not yet automated; hand_seconds: body time that hand service took/);
    expect(flat(pilot)).toMatch(/like a line with `hand_transfers`, is not automated: each hand transfer costs body time/);
    expect(flat(strategist)).toMatch(/A line that stays `hand_fed` or shows `hand_transfers` is served by hand: not automated, and it costs body time \(`hand_seconds`\)\./);
    expect(flat(knowledge)).toMatch(/\*\*Hand work\.\*\* A line served by hand is not automated: each transfer costs body time \(`hand_seconds`\)/);
    expect(readme).toMatch(/`hand_transfers`: such a line is served by hand, not automated, and costs body time/);
  });

  it("heads the strategist's progress principle as automated progress, not an order", () => {
    expect(flat(strategist)).toMatch(/\*\*Automated progress\.\*\* Judge progress by what machines make/);
    expect(strategist).not.toMatch(/Automation first/);
  });

  it("keeps durable gameplay instructions generic and text-only", () => {
    for (const text of [skill, pilot, strategist, knowledge]) {
      expect(text).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
      expect(text).not.toMatch(/\b(?:first|start by)\s+(?:mine|craft|place|build|research)\b/i);
    }
  });
});
