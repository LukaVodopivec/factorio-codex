import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const skillRoot = path.join(root, ".agents/skills/factorio-player");
const read = (name: string) => fs.readFileSync(path.join(skillRoot, name), "utf8");
const skill = read("SKILL.md");
const master = read("GOAL-MASTER-v1.md");
const pilot = read("GOAL-PILOT-v1.md");
const specialist = read("GOAL-SPECIALIST-v1.md");
const knowledge = read("PLAYER-KNOWLEDGE-v1.md");
const performance = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
const roleGuidance = performance.match(/For role coordination,[\s\S]*?(?=\n## Peaceful rocket benchmark)/)?.[0] ?? "";
const prompts = [master, pilot, specialist];
const allInstructions = [skill, ...prompts, knowledge].join("\n");
const ledgerPath = "/run/user/<uid>/factorio-codex/runs/<run-id>/operations.json";

describe("shared gameplay run contract", () => {
  it("records the exact satisfactory Candidate B R7 result without overstating current-source validation", () => {
    const joined = `${performance}\n${liveValidation}`;
    for (const value of [
      "616de9daf11ffdc03f946dd1f76732f4544539801f0f28db62959bcf8f1eea8e",
      "80a5874eabc8d9822e7c8d24dd36b68ece4e26e6",
      "d8d3600e4eb0a1d0087d1c9810070e514c4491c7abf05e63f01f14f58b3a2106",
      "2026-09-03T06:26:52.063455112Z", "2026-09-03T06:46:52.065339056Z",
      "2026-09-03T06:46:16.362Z", "2026-09-03T06:46:24.228Z",
      "2026-09-03T06:47:08Z", "source_tick=95498",
    ]) expect(joined).toContain(value);
    const result = performance.slice(performance.indexOf("#### Candidate B R7 recorded result"));
    expect(result).toMatch(/SNAPSHOT_AT_20M[\s\S]*iron-plate=40[\s\S]*copper-plate=10[\s\S]*copper-ore=8[\s\S]*wood=2[\s\S]*furnace output[\s\S]*iron-plate=10/i);
    expect(result).toMatch(/queue depth was zero[\s\S]*active task was `null`[\s\S]*crafting queue was zero/i);
    expect(result).toMatch(/35\.7 seconds before the deadline[^\n]*showed[\s\S]*nine iron\s+plates[\s\S]*active craft at\s+progress `0\.73`[\s\S]*exact\s+pre-deadline lower bound is therefore 49 processed iron plates/i);
    expect(result).toMatch(/accepted\s+automated[\s\S]*copper and iron drill-to-chest extraction[\s\S]*copper-plate=10[\s\S]*Electronics unlock[\s\S]*before the deadline/i);
    expect(result).toMatch(/tenth furnace plate and Steam Power are collection-confirmed[\s\S]*overwhelmingly likely[\s\S]*not exact-deadline proof[\s\S]*49 as the exact cutoff lower bound[\s\S]*tighter tick attribution/i);
    expect(result).toMatch(/satisfactory automation-first progress vector[\s\S]*not rocket completion/i);
    expect(result).toMatch(/manual tree-fuel trips[\s\S]*manual chest\/furnace transfers[\s\S]*trapped[^\n]*layout[\s\S]*ledger\/message lag[\s\S]*stale envelopes[\s\S]*false\s+post-deadline attribution/i);
    expect(result).toMatch(/nil mining-drill `drop_target`[\s\S]*runtime target becomes authoritative only after first output/i);
    expect(result).toMatch(/c56a5f5149f381fd0cc88860a24259f3f9b62e89[\s\S]*published during R7[\s\S]*neither the\s+deployed artifact nor benchmarked/i);
    expect(result).toMatch(/No post-deadline gameplay occurred[\s\S]*no work visible[\s\S]*collection latency is attributed to the deadline/i);
    expect(result).not.toMatch(/rocket (?:launched|completed)|R7 (?:passed|failed)|PASS_AT_20M|MISS_AT_20M/i);
    expect(result).not.toMatch(/\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)/);
  });

  it("documents exact R6 structured placement, inspection, path, and transition evidence", () => {
    for (const text of [readme, liveValidation]) {
      expect(text).toMatch(/output_position[\s\S]*recipient[\s\S]*null/i);
      expect(text).toMatch(/drill[\s\S]*output\s+position[\s\S]*(?:recipient|drop_target_bound)/i);
      expect(text).toMatch(/drop_target_bound/i);
      expect(text).toMatch(/furnace[\s\S]*fuel[\s\S]*input[\s\S]*output buffers[\s\S]*inventory exists/i);
      expect(text).toMatch(/immediate charted[\s\S]*collision segment[\s\S]*blocker/i);
      expect(text).toMatch(/queued[\s\S]*running[\s\S]*waiting[\s\S]*(?:truthful )?final transition/i);
    }
  });
  it("uses one exact ephemeral operations ledger and removes every retired run file", () => {
    for (const text of [skill, ...prompts]) expect(text).toContain(ledgerPath);
    for (const retired of [
      "XDG_STATE_HOME", "manifest.json", "master-envelope.json", "decisions.md",
      "pilot-state.json", "pilot-events.jsonl", "landmarks.json", "specialist-notes.md",
    ]) expect(allInstructions).not.toContain(retired);
    expect(skill).toMatch(/exactly one ephemeral\s+ledger/i);
    expect(skill).toMatch(/Do not create another run file, append log/i);
  });

  it("locks parent initialization, permissions, and phase-separated ownership", () => {
    expect(skill).toMatch(/parent creates the run\s+directory with mode `0700` and initializes the file with mode `0600`/i);
    expect(skill).toMatch(/after\s+initialization, the master is the sole host-ledger writer/i);
    expect(master).toMatch(/parent creates the `0700` directory and initializes[\s\S]*the single `0600` `operations\.json`[\s\S]*sole host-ledger writer/i);
    expect(pilot).toMatch(/read the single `operations\.json` but never write it/i);
    expect(pilot).toMatch(/sole authority for the latest observation/i);
    expect(specialist).toMatch(/read the single `operations\.json` but never write it/i);
    expect(specialist).toMatch(/strictly read-only/i);
  });

  it("locks the operations snapshot fields and atomic replacement", () => {
    for (const field of ["schema version", "run/save identity", "monotonic revision", "source tick", "phase", "success", "latest pilot observation", "capacity", "utilization", "current plan", "queued successor", "predecessor", "preconditions"])
      expect(skill.toLowerCase()).toContain(field);
    for (const field of ["schema_version", "run", "revision", "source_tick", "phase", "success", "capacity", "utilization", "bottleneck", "current_plan", "queued_successor", "fallbacks", "current_bom", "next_bom", "latest_observation", "decisions", "specialist_advice", "invalidations", "outcome"])
      expect(skill).toContain(`\`${field}\``);
    for (const field of ["id", "release_sha", "baseline_save_sha256", "save_identity", "created_at"])
      expect(skill).toContain(`\`${field}\``);
    expect(skill).toMatch(/`outcome` object/i);
    for (const field of ["GO UTC/monotonic/tick", "deadline", "collection UTC/monotonic/tick", "latency", "`SNAPSHOT_AT_20M`", "progress vector", "throughput", "cancellation/drain evidence", "diagnosis"])
      expect(skill).toContain(field);
    expect(skill).toMatch(/20-minute snapshot is not a binary success gate/i);
    expect(allInstructions).not.toMatch(/PASS_AT_20M|MISS_AT_20M/);
    expect(master).toMatch(/Rewrite it atomically through (?:a `0600` )?adjacent temporary file and rename/i);
    expect(master).toMatch(/`0600` adjacent temporary file[\s\S]*verify the final file remains `0600`/i);
    expect(allInstructions).not.toMatch(/file watching|filesystem watcher|message broker|sqlite|postgres|mysql/i);
  });

  it("enforces revision tick and immutable save freshness", () => {
    for (const text of [skill, master, pilot, specialist]) {
      expect(text).toMatch(/revision/i);
      expect(text).toMatch(/source tick/i);
      expect(text).toMatch(/save identity/i);
      expect(text).toMatch(/regress/i);
    }
    expect(skill).toMatch(/save identity regresses or disagrees with live structured state/i);
    expect(skill).toMatch(/parent writes revision `0`/i);
    expect(skill).toMatch(/is exactly prior\s+revision plus one/i);
    expect(skill).toMatch(/revision `0` with both[\s\S]*`source_tick` and `latest_observation` set to `null`/i);
    expect(skill).toMatch(/preserves `run` byte-for-byte/i);
    expect(skill).toMatch(/After the first pilot observation,[\s\S]*`source_tick` never decreases[\s\S]*equals `latest_observation\.source_tick`/i);
    expect(skill).toMatch(/a\s+reset, tick rollback, or save identity mismatch requires a fresh parent-created\s+run ID and ledger/i);
    expect(master).toMatch(/monotonic revision/i);
    expect(pilot).toMatch(/reject regressing source ticks or a mismatched save identity/i);
  });

  it("invalidates coordinate state and keeps durable knowledge coordinate-free", () => {
    for (const phrase of ["reset", "contradictory observation", "referenced-entity mutation", "route failure"])
      expect(allInstructions.toLowerCase()).toContain(phrase);
    expect(skill).toMatch(/Remove affected coordinates from the\s+ledger/i);
    expect(knowledge).toMatch(/coordinates may exist only in the ephemeral `operations\.json` ledger/i);
    expect(knowledge).toMatch(/No world position[\s\S]*coordinate pair[\s\S]*landmark position[\s\S]*entity location[\s\S]*route belongs in this file/i);
  });

  it("requires quantified automation payback and a real queued successor", () => {
    for (const text of [skill, master, pilot, specialist]) {
      expect(text).toMatch(/exact net deficit[\s\S]*carried stock[\s\S]*machine buffers\/output[\s\S]*(?:work in progress|WIP)/i);
      expect(text).toMatch(/machine unlock or fuel consumer[\s\S]*uptime/i);
      expect(text).toMatch(/payback[\s\S]*item\/time units[\s\S]*break-even/i);
      expect(text).toMatch(/numeric stop/i);
      expect(text).toMatch(/capacity/i);
      expect(text).toMatch(/utilization/i);
      expect(text).toMatch(/actually queued/i);
      expect(text).toMatch(/reason (?:none|no .*successor)/i);
    }
    expect(pilot).toMatch(/call `queue_plan`[\s\S]*returned `plan_id` and `after_plan_id`[\s\S]*matching `plan_status` values verbatim[\s\S]*confirms status `queued`[\s\S]*never reconstruct or relabel IDs from memory[\s\S]*`queued_successor: null`/i);
    expect(skill).toMatch(/Report the returned[\s\S]*`plan_id` and echoed `after_plan_id` verbatim from structured results[\s\S]*never reconstruct, substitute, or[\s\S]*relabel either ID from memory/i);
    expect(skill).toMatch(/never\s+prepend a redundant `walk_to`/i);
    expect(pilot).toMatch(/Never prepend `walk_to` to a positional action that already auto-approaches/i);
  });

  it("requires positive compatible drill coverage before physical placement", () => {
    for (const text of [skill, pilot]) {
      expect(text).toMatch(/never physically place a mining drill[\s\S]*`find_placement` candidate[\s\S]*`resource_coverage` is present[\s\S]*positive compatible coverage/i);
      expect(text).toMatch(/missing or empty coverage requires more structured observation and[\s\S]*revalidation, not placement/i);
    }
    expect(performance).toMatch(/omitted uncharted coverage[\s\S]*deterministic rejection of charted candidates with zero compatible\s+resources/i);
  });

  it("teaches a state-driven learning loop without a disguised opening route", () => {
    for (const text of [skill, master, pilot, specialist, knowledge]) {
      for (const phrase of ["authoritative state", "current bottleneck", "falsifiable hypothesis", "measurable effect", "safe action", "retain", "revise", "discard", "provenance", "uncertainty"])
        expect(text.toLowerCase()).toContain(phrase);
      expect(text).toMatch(/opening script[\s\S]*fixed build order[\s\S]*named route/i);
      expect(text).not.toMatch(/first (?:mine|craft|build|place)[^\n]{0,120}then/i);
      expect(text).not.toMatch(/(?:at|by) minute \d+/i);
    }
  });

  it("coalesces reports into bounded single-use decision envelopes", () => {
    expect(master).toMatch(/coalesce pilot reports and specialist memos by newest source\s+tick/i);
    expect(master).toMatch(/Superseded reports do not cause ledger rewrites/i);
    expect(master).toMatch(/first decision immediately after one authoritative preflight[\s\S]*first ledger revision[\s\S]*broad state-grounded[\s\S]*physical envelope[\s\S]*end your turn/i);
    for (const phrase of ["broad goal-conditioned envelope", "bottleneck remains valid", "safe bounds", "numeric stops"])
      expect(master.toLowerCase()).toContain(phrase);
    expect(master).toMatch(/locally\s+adaptive fallbacks/i);
    expect(master).toMatch(/never issue the same plan ID or envelope twice/i);
    expect(pilot).toMatch(/each master envelope and plan ID as single-use/i);
    expect(pilot).toMatch(/without\s+per-action approval[\s\S]*never repeat an executed envelope or plan ID/i);
    expect(pilot).toContain("`run_plan` terminal");
    expect(pilot).toMatch(/material bottleneck[\s\S]*terminal outcomes[\s\S]*invalidations/i);
    expect(pilot).toMatch(/only outcome-labeled terminal, material-bottleneck, or invalidation evidence/i);
    for (const text of [skill, master, pilot, specialist, roleGuidance]) {
      expect(text).toMatch(/one useful item or incidental\s+non-production loot/i);
      expect(text).toMatch(/automation utilization[\s\S]*current(?:-plus-| plan, and its grounded | plan and its grounded )successor/i);
    }
    expect(specialist).toMatch(/at most one attributed,\s+coalescible evidence memo per new ledger revision/i);
    expect(roleGuidance).toMatch(/coalesces superseded reports[\s\S]*never reissues an executed plan ID/i);
    expect(roleGuidance).toMatch(/broad goal-conditioned envelope[\s\S]*numeric\s+stops[\s\S]*locally adaptive fallbacks/i);
    expect(master).toMatch(/freeze[\s\S]*cancel[\s\S]*drain[\s\S]*diagnos[\s\S]*fresh[\s\S]*baseline/i);
    expect(pilot).toMatch(/no post-snapshot gameplay/i);
    expect(specialist).toMatch(/at most one[\s\S]*per new ledger revision/i);
    expect(specialist).toMatch(/material-flow\s+contradiction/i);
    expect(specialist).toMatch(/MCP observability gap/i);
    for (const text of [master, pilot, specialist, roleGuidance]) {
      for (const phrase of ["output", "physical sink", "observable", "capacity"]) expect(text.toLowerCase()).toContain(phrase);
      expect(text).toMatch(/measured deltas/i);
    }
    expect(roleGuidance).toMatch(/general learning-loop rules/i);
    expect(roleGuidance).not.toMatch(/first (?:mine|craft|build|place)[^\n]{0,120}then|(?:at|by) minute \d+/i);
  });

  it("starts bounded state-driven physical work while the first master envelope is prepared", () => {
    expect(pilot).toMatch(/At `GO`[\s\S]*authoritative initial observation[\s\S]*awaiting the first master envelope[\s\S]*pre-authorized bootstrap envelope/i);
    expect(pilot).toMatch(/already-carried automation[\s\S]*verified visible resource[\s\S]*exact physical sink[\s\S]*visible dry waypoint[\s\S]*nearest measured blocker[\s\S]*numeric stop/i);
    expect(pilot).toMatch(/Report the first material result[\s\S]*first master envelope supersedes this default/i);
    expect(pilot).toMatch(/same sole writer, body, and FIFO lane/i);
    expect(pilot).toMatch(/never a fixed item, resource, order, coordinate, route, or timed phase/i);
    expect(master).toMatch(/initial observation[\s\S]*already supplied by the pilot[\s\S]*pre-authorized bootstrap work[\s\S]*master envelope then supersedes/i);
    expect(roleGuidance).toMatch(/At `GO`[\s\S]*pre-authorized bootstrap envelope[\s\S]*numeric\s+stop[\s\S]*no second writer, body, or[\s\S]*lane/i);
  });

  it("preserves deterministic stale invalidation productive overlap and boundaries", () => {
    for (const text of [skill, ...prompts]) {
      expect(text).toMatch(/deterministic MCP (?:state and tool results|tools|evidence)/i);
      expect(text).toMatch(/invalidat(?:e|ion).*stale/i);
      expect(text).toMatch(/productive (?:work )?overlap|productive work overlapping|overlap(?:ping)?[\s\S]*production/i);
      expect(text).toMatch(/peaceful[\s\S]*enemy bases disabled/i);
      expect(text).toMatch(/no combat tool/i);
      expect(text).not.toMatch(/\bbiters?\b|\bdefen[cd]e?\b/i);
      expect(text).toMatch(/(?:no (?:second|another)|another) body|(?:one|sole) physical Codex body/i);
      expect(text).toMatch(/never use screenshots or screen capture for live gameplay perception[\s\S]*action selection/i);
      expect(text).toMatch(/raw Lua\/console/i);
      expect(text).toMatch(/scripted\s+mining/i);
      expect(text).toMatch(/imported blueprints/i);
    }
    expect(fs.readdirSync(skillRoot).sort()).toEqual([
      "GOAL-MASTER-v1.md", "GOAL-PILOT-v1.md", "GOAL-SPECIALIST-v1.md",
      "PLAYER-KNOWLEDGE-v1.md", "SKILL.md",
    ]);
    expect(pilot).toMatch(/only ordinary MCP action writer/i);
  });
});
