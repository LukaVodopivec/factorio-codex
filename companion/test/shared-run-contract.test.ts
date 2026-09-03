import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const skillRoot = path.join(root, ".agents/skills/factorio-player");
const read = (name: string) => fs.readFileSync(path.join(skillRoot, name), "utf8");
const skill = read("SKILL.md");
const strategist = read("GOAL-STRATEGIST-v1.md");
const pilot = read("GOAL-PILOT-v1.md");
const knowledge = read("PLAYER-KNOWLEDGE-v1.md");
const performance = fs.readFileSync(path.join(root, "docs/AGENT-PLAY-PERFORMANCE.md"), "utf8");
const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
const liveValidation = fs.readFileSync(path.join(root, "docs/LIVE-VALIDATION.md"), "utf8");
const roleGuidance = performance.match(/For active role coordination,[\s\S]*?(?=\n## Peaceful rocket benchmark)/)?.[0] ?? "";
const prompts = [strategist, pilot];
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
    expect(skill).toMatch(/Do\s+not create another run file, append log/i);
  });

  it("locks parent initialization, permissions, and phase-separated ownership", () => {
    expect(skill).toMatch(/parent creates the run\s+directory with mode `0700` and initializes the file with mode `0600`/i);
    expect(skill).toMatch(/after\s+initialization, the strategist is the sole host-ledger writer/i);
    expect(strategist).toMatch(/parent creates the fresh `0700` run directory and initializes[\s\S]*the one `0600` `operations\.json`[\s\S]*sole host-ledger writer/i);
    expect(pilot).toMatch(/read the single `operations\.json` but never write it/i);
    expect(pilot).toMatch(/sole authority for live structured state/i);
  });

  it("locks the operations snapshot fields and atomic replacement", () => {
    for (const field of ["schema version", "run/save identity", "monotonic revision", "source tick", "phase", "success", "latest pilot observation", "capacity", "utilization", "current plan", "queued successor", "predecessor", "preconditions"])
      expect(skill.toLowerCase()).toContain(field);
    for (const field of ["schema_version", "run", "revision", "source_tick", "phase", "success", "capacity", "utilization", "bottleneck", "current_plan", "queued_successor", "fallbacks", "current_bom", "next_bom", "latest_observation", "decisions", "strategy_proposal", "invalidations", "outcome"])
      expect(skill).toContain(`\`${field}\``);
    for (const field of ["run", "save_identity", "revision", "source_tick", "proposal_id", "objective", "bottleneck", "falsifiable_hypothesis", "expected_measurable_effect", "assumptions", "preconditions", "safe_bounds", "numeric_stop", "invalidation", "confidence", "next_objective"])
      expect(skill).toContain(`\`${field}\``);
    expect(allInstructions).not.toContain("specialist_advice");
    for (const field of ["id", "release_sha", "baseline_save_sha256", "save_identity", "created_at"])
      expect(skill).toContain(`\`${field}\``);
    expect(skill).toMatch(/`outcome` object/i);
    for (const field of ["GO UTC/monotonic/tick", "deadline", "collection UTC/monotonic/tick", "latency", "`SNAPSHOT_AT_20M`", "progress vector", "throughput", "cancellation/drain evidence", "diagnosis"])
      expect(skill).toContain(field);
    expect(skill).toMatch(/20-minute snapshot is not a binary success gate/i);
    expect(allInstructions).not.toMatch(/PASS_AT_20M|MISS_AT_20M/);
    expect(strategist).toMatch(/Rewrite the file atomically through (?:a `0600` )?adjacent temporary file and rename/i);
    expect(strategist).toMatch(/`0600` adjacent temporary file[\s\S]*verify the final file remains `0600`/i);
    expect(allInstructions).not.toMatch(/file watching|filesystem watcher|message broker|sqlite|postgres|mysql/i);
  });

  it("enforces revision tick and immutable save freshness", () => {
    for (const text of [skill, strategist, pilot]) {
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
    expect(strategist).toMatch(/increment revision by exactly one/i);
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
    for (const text of [skill, strategist, pilot]) {
      expect(text).toMatch(/exact net deficit[\s\S]*carried stock[\s\S]*machine buffers\/output[\s\S]*(?:work in progress|WIP)/i);
      expect(text).toMatch(/machine unlock or fuel consumer[\s\S]*uptime/i);
      expect(text).toMatch(/payback[\s\S]*item\/time units[\s\S]*break-even/i);
      expect(text).toMatch(/numeric stop/i);
      expect(text).toMatch(/capacity/i);
      expect(text).toMatch(/utilization/i);
    }
    for (const text of [skill, pilot]) {
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
    for (const text of [skill, pilot, knowledge]) {
      for (const phrase of ["authoritative state", "current bottleneck", "falsifiable hypothesis", "measurable effect", "safe action", "retain", "revise", "discard", "provenance", "uncertainty"])
        expect(text.toLowerCase()).toContain(phrase);
      expect(text).toMatch(/opening script[\s\S]*fixed build order[\s\S]*named route/i);
      expect(text).not.toMatch(/first (?:mine|craft|build|place)[^\n]{0,120}then/i);
      expect(text).not.toMatch(/(?:at|by) minute \d+/i);
    }
    for (const phrase of ["authoritative pilot report", "current bottleneck", "falsifiable hypothesis", "measurable effect", "retain", "revise", "discard", "provenance", "uncertainty"])
      expect(strategist.toLowerCase()).toContain(phrase);
    expect(strategist).toMatch(/opening script[\s\S]*fixed build order[\s\S]*named route/i);
  });

  it("coalesces reports into bounded coordinate-free strategy proposals", () => {
    expect(strategist).toMatch(/Coalesce superseded pilot reports by newest source tick/i);
    expect(skill).toMatch(/superseded reports[\s\S]*not one revision per stale\s+report/i);
    expect(strategist).toMatch(/zero Factorio MCP access/i);
    expect(strategist).toMatch(/sole host-ledger writer[\s\S]*atomically[\s\S]*revision by exactly one/i);
    expect(strategist).toMatch(/`current_plan`[\s\S]*`queued_successor`[\s\S]*pilot-reported MCP facts[\s\S]*never infer them from your proposal/i);
    expect(strategist).toMatch(/strategy_proposal[\s\S]*run[\s\S]*save_identity[\s\S]*revision[\s\S]*source_tick[\s\S]*proposal_id[\s\S]*objective[\s\S]*bottleneck[\s\S]*falsifiable_hypothesis[\s\S]*expected_measurable_effect[\s\S]*assumptions[\s\S]*preconditions[\s\S]*safe_bounds[\s\S]*numeric_stop[\s\S]*invalidation[\s\S]*confidence[\s\S]*next_objective/i);
    expect(strategist).toMatch(/at most one unique proposal per source tick[\s\S]*never replace or resend[\s\S]*single-use/i);
    expect(strategist).toMatch(/coordinate-free[\s\S]*non-executable advice[\s\S]*never an envelope, plan, exact-coordinate command, approval, gate, acknowledgement protocol, resend request, debate/i);
    expect(pilot).toMatch(/strategy_proposal[\s\S]*non-executable advice[\s\S]*never approves, gates, enqueues, or commands[\s\S]*no acknowledgement, resend, or debate/i);
    expect(pilot).toContain("`run_plan` terminal");
    expect(pilot).toMatch(/material bottleneck, technology, production, or expansion change[\s\S]*repeated distinct failure/i);
    expect(pilot).toMatch(/natural boundary[\s\S]*at most one proposal for a source tick[\s\S]*every precondition exactly once[\s\S]*accept or discard[\s\S]*single-use/i);
    for (const text of [skill, pilot, roleGuidance]) {
      expect(text).toMatch(/one useful item or incidental\s+non-production loot/i);
      expect(text).toMatch(/automation utilization[\s\S]*current(?:-plus-| plan, and its grounded | plan and its grounded )successor/i);
    }
    expect(roleGuidance).toMatch(/coalesces superseded pilot reports[\s\S]*current_plan[\s\S]*queued_successor[\s\S]*pilot-reported MCP\s+facts/i);
    expect(roleGuidance).toMatch(/strategy_proposal[\s\S]*safe bounds[\s\S]*numeric[\s\S]*non-executable advice/i);
    expect(pilot).toMatch(/no post-snapshot gameplay/i);
    expect(strategist).toMatch(/material-flow contradiction[\s\S]*MCP observability gap/i);
    for (const text of [strategist, pilot, roleGuidance]) {
      for (const phrase of ["output", "physical sink", "observable", "capacity"]) expect(text.toLowerCase()).toContain(phrase);
      expect(text).toMatch(/measured deltas/i);
    }
    expect(roleGuidance).toMatch(/general learning-loop rules/i);
    expect(roleGuidance).not.toMatch(/first (?:mine|craft|build|place)[^\n]{0,120}then|(?:at|by) minute \d+/i);
  });

  it("starts bounded state-driven physical work without awaiting a proposal", () => {
    expect(pilot).toMatch(/At `GO`[\s\S]*authoritative initial observation[\s\S]*immediately follow the bootstrap policy[\s\S]*do not wait for a proposal or ledger update/i);
    expect(pilot).toMatch(/already-carried automation[\s\S]*verified visible resource[\s\S]*exact physical sink[\s\S]*visible dry waypoint[\s\S]*nearest measured blocker[\s\S]*numeric stop/i);
    expect(pilot).toMatch(/same sole writer, body, and FIFO lane/i);
    expect(pilot).toMatch(/never a fixed item, resource, order, coordinate, route, or timed phase/i);
    expect(strategist).toMatch(/pilot's newest matching run\/save report is authoritative for game facts/i);
    expect(roleGuidance).toMatch(/At `GO`[\s\S]*bounded safe physical work[\s\S]*numeric\s+stop[\s\S]*no second writer, body, or[\s\S]*lane/i);
  });

  it("keeps pilot continuity autonomous and proposals advisory single-use", () => {
    expect(pilot).toMatch(/read the ledger once at startup[\s\S]*never read it before or after each MCP call/i);
    expect(pilot).toMatch(/Never wait for the strategist, a proposal, a ledger read, or a ledger write/i);
    expect(pilot).toMatch(/permanently own the local bottleneck, action, and fallback choice plus the current plan and one grounded queued successor/i);
    expect(pilot).toMatch(/latest MCP result wins/i);
    expect(pilot).toMatch(/Keep useful work queued before reporting/i);
    expect(strategist).toMatch(/restart[\s\S]*rebuild entirely from the ledger[\s\S]*without requesting replay or pausing the pilot/i);
    expect(skill).toMatch(/strategist restarts[\s\S]*rebuilds entirely from the ledger without[\s\S]*pausing the pilot or requesting replay/i);
    expect(skill).toMatch(/at most one unique,[\s\S]*single-use proposal per source tick/i);
    expect(strategist).toMatch(/at most one unique proposal per source tick/i);
    expect(pilot).toMatch(/at most one proposal for a source tick/i);
    expect(roleGuidance).toMatch(/at most one unique proposal per\s+source tick/i);
    for (const text of [skill, strategist, pilot, roleGuidance])
      expect(text).toMatch(/(?:accepts\s+or\s+discards|accept\s+or\s+discard)/i);
    for (const text of [skill, pilot, roleGuidance])
      expect(text).toMatch(/natural (?:plan )?boundary/i);
    expect(strategist).toMatch(/zero Factorio MCP access/i);
    expect(strategist).toMatch(/never an envelope, plan, exact-coordinate command, approval, gate[\s\S]*instruction to enqueue/i);
    expect(fs.existsSync(path.join(skillRoot, "GOAL-MASTER-v1.md"))).toBe(false);
    expect(fs.existsSync(path.join(skillRoot, "GOAL-SPECIALIST-v1.md"))).toBe(false);
  });

  it("preserves deterministic stale invalidation productive overlap and boundaries", () => {
    for (const text of [skill, pilot]) {
      expect(text).toMatch(/deterministic MCP (?:state and tool results|tools|evidence)|latest MCP result/i);
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
    expect(strategist).toMatch(/zero Factorio MCP access[\s\S]*pilot is the sole gameplay writer and sole authority for live structured state/i);
    expect(strategist).toMatch(/pilot-reported MCP facts[\s\S]*Reject regressing[\s\S]*stale facts/i);
    expect(fs.readdirSync(skillRoot).sort()).toEqual([
      "GOAL-PILOT-v1.md", "GOAL-STRATEGIST-v1.md",
      "PLAYER-KNOWLEDGE-v1.md", "SKILL.md",
    ]);
    expect(pilot).toMatch(/only Factorio MCP user and ordinary gameplay writer/i);
  });
});
