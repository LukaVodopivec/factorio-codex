import { z } from "zod";

export const roleProfileSchema = z.object({
  id: z.enum(["pilot", "strategist", "mining", "logistics"]),
  role: z.enum(["pilot", "strategist", "advisor"]),
  model: z.enum(["gpt-6-luna", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra"]),
  reasoning: z.enum(["low", "medium", "high", "xhigh", "max"]),
  fast: z.boolean(),
  ledger_writer: z.boolean(),
}).strict();
export type RoleProfile = z.infer<typeof roleProfileSchema>;

export const profileListSchema = z.array(roleProfileSchema).min(1).max(4).superRefine((roles, ctx) => {
  const issue = (message: string) => ctx.addIssue({ code: "custom", message });
  if (new Set(roles.map(r => r.id)).size !== roles.length) issue("role ids must be unique");
  const pilots = roles.filter(r => r.role === "pilot"), writers = roles.filter(r => r.ledger_writer);
  if (pilots.length !== 1) issue("exactly one pilot controls the physical body");
  if (writers.length !== 1) issue("exactly one role writes the ledger");
  if (roles.filter(r => r.role === "strategist").length !== (roles.length === 1 ? 0 : 1))
    issue("a multi-agent run has exactly one strategist");
  if (writers[0]?.role !== (roles.length === 1 ? "pilot" : "strategist"))
    issue("the solo pilot or multi-agent strategist owns the ledger");
  if (pilots[0]?.id !== "pilot" || roles.some(r => r.role === "strategist" && r.id !== "strategist"))
    issue("pilot and strategist use pilot and strategist ids");
  if (roles.some(r => r.role === "advisor" && !["mining", "logistics"].includes(r.id)))
    issue("advisors use mining or logistics ids");
});

// Historical files retain their original shape and requested profiles.
const historicalProfile = z.object({ model: z.string().min(1).max(80), reasoning: z.string().min(1).max(40),
  fast: z.boolean().optional() }).strict();
export const runRolesSchema = z.union([profileListSchema,
  z.object({ pilot: historicalProfile, strategist: historicalProfile }).strict()]);
export type RunRoles = z.infer<typeof runRolesSchema>;
export function roleProfiles(roles: RunRoles): RoleProfile[] {
  if (Array.isArray(roles)) return roles;
  return profileListSchema.parse([
    { id: "pilot", role: "pilot", ...roles.pilot, fast: roles.pilot.fast ?? false, ledger_writer: false },
    { id: "strategist", role: "strategist", ...roles.strategist, fast: roles.strategist.fast ?? false, ledger_writer: true },
  ]);
}

export function initialProfiles(count: number): RoleProfile[] {
  if (!Number.isInteger(count) || count < 1 || count > 4) throw new Error("agent count must be 1 through 4");
  return profileListSchema.parse([
    { id: "pilot", role: "pilot", model: "gpt-6-luna", reasoning: "low", fast: true, ledger_writer: count === 1 },
    ...(count > 1 ? [{ id: "strategist", role: "strategist", model: "gpt-6.1-sol", reasoning: "medium", fast: false, ledger_writer: true }] : []),
    ...(count > 2 ? [{ id: "mining", role: "advisor", model: "gpt-6.1-sol", reasoning: "medium", fast: false, ledger_writer: false }] : []),
    ...(count > 3 ? [{ id: "logistics", role: "advisor", model: "gpt-6.1-sol", reasoning: "medium", fast: false, ledger_writer: false }] : []),
  ]);
}
