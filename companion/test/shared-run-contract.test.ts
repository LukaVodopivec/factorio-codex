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
const prompts = [master, pilot, specialist];
const allInstructions = [skill, ...prompts].join("\n");

describe("shared gameplay run contract", () => {
  it("uses one explicit run directory and exact file ownership", () => {
    const runPath = "${XDG_STATE_HOME:-$HOME/.local/state}/factorio-codex/runs/<run-id>";
    for (const text of [skill, ...prompts]) expect(text).toContain(runPath);

    expect(skill).toMatch(/parent\s+alone writes `manifest\.json`/i);
    expect(skill).toMatch(/master alone writes `master-envelope\.json`\s+and `decisions\.md`/i);
    expect(skill).toMatch(/pilot alone writes `pilot-state\.json`, append-only\s+`pilot-events\.jsonl`, and `landmarks\.json`/i);
    expect(skill).toMatch(/specialist alone writes\s+`specialist-notes\.md`/i);
    expect(skill).toMatch(/Every participant reads every shared-run file/i);

    expect(master).toMatch(/write exactly `master-envelope\.json` and `decisions\.md`/i);
    expect(pilot).toMatch(/write exactly `pilot-state\.json`, `pilot-events\.jsonl`, and `landmarks\.json`/i);
    expect(specialist).toMatch(/write exactly `specialist-notes\.md`/i);
    for (const prompt of prompts) {
      expect(prompt).toMatch(/read every shared-run file/i);
      expect(prompt).toMatch(/never write `manifest\.json` or another role's files/i);
    }
  });

  it("requires atomic snapshots and one append-only event log", () => {
    expect(skill).toMatch(/Rewrite files atomically[\s\S]*temporary file and rename/i);
    expect(skill).toMatch(/only `pilot-events\.jsonl` is appended, one complete\s+JSON object per line/i);
    expect(pilot).toMatch(/Atomically rewrite `pilot-state\.json` and `landmarks\.json`[\s\S]*temporary file and rename/i);
    expect(pilot).toMatch(/Append one complete JSON object per line to `pilot-events\.jsonl`; never rewrite it/i);
  });

  it("keeps coordinates run-local and invalidates them on every named event", () => {
    for (const phrase of ["reset", "contradictory observation", "referenced-entity mutation", "route failure"])
      expect(allInstructions.toLowerCase()).toContain(phrase);
    expect(skill).toMatch(/Run coordinates may appear only in `pilot-state\.json`, `pilot-events\.jsonl`,\s+or `landmarks\.json`/i);
    expect(pilot).toMatch(/Never copy coordinates into `PLAYER-KNOWLEDGE-v1\.md`, master files, or specialist notes/i);

    const knowledge = read("PLAYER-KNOWLEDGE-v1.md");
    expect(knowledge).toMatch(/No world position[\s\S]*coordinate pair[\s\S]*landmark position[\s\S]*entity location[\s\S]*route belongs in this file/i);
    expect(knowledge).toMatch(/Run-local\s+coordinates stay in the pilot-owned shared-run files/i);
  });

  it("preserves deterministic planning, stale invalidation, and productive overlap", () => {
    for (const text of [skill, ...prompts]) {
      expect(text).toMatch(/deterministic MCP (?:state and tool results|tools)/i);
      expect(text).toMatch(/current plan[\s\S]*(?:one|exactly one) prepared successor/i);
      expect(text).toMatch(/invalidate stale|invalidat(?:e|ion).*stale/i);
      expect(text).toMatch(/productive (?:work )?overlap|productive work overlapping|overlap(?:ping)?[\s\S]*production/i);
    }
  });

  it("adds no coordination machinery and keeps the peaceful one-writer text-only boundary", () => {
    for (const text of [skill, ...prompts]) {
      expect(text).toMatch(/peaceful[\s\S]*enemy bases disabled/i);
      expect(text).toMatch(/no combat tool/i);
      expect(text).not.toMatch(/\bbiters?\b|\bdefen[cd]e?\b/i);
      expect(text).toMatch(/(?:no (?:second|another)|another) body|(?:one|sole) physical Codex body/i);
      expect(text).toMatch(/no screenshots|never (?:invoke|use) screenshots/i);
      expect(text).toMatch(/raw Lua\/console/i);
    }
    expect(fs.readdirSync(skillRoot).sort()).toEqual([
      "GOAL-MASTER-v1.md",
      "GOAL-PILOT-v1.md",
      "GOAL-SPECIALIST-v1.md",
      "PLAYER-KNOWLEDGE-v1.md",
      "SKILL.md",
    ]);
    expect(allInstructions).not.toMatch(/file watching|filesystem watcher|message broker|sqlite|postgres|mysql/i);
    expect(allInstructions).not.toMatch(/future[\s\S]{0,40}(?:combat|enemy|biter)|\bbiters?\b|\bdefen[cs]e?\b/i);
    expect(pilot).toMatch(/only ordinary MCP action writer/i);
    expect(master).toMatch(/sole ordinary MCP action writer/i);
    expect(specialist).toMatch(/strictly read-only/i);
  });
});
