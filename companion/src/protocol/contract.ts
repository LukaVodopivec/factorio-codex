import { z } from "zod";

export const PROTOCOL_VERSION = 26;

/** Executable manifest shared by runtime validation and conformance tests. */
export const RPC_METHODS = [
  "ping",
  "spawn_companion",
  "observe_local",
  "inspect",
  "start_research",
  "can_place",
  "find_placement",
  "map_summary",
  "production_requirements",
  "run_snapshot",
  "connect_entities",
  "describe_prototype",
  "progression_status",
  "enqueue",
  "get_task",
  "queue_plan",
  "plan_status",
  "cancel",
  "get_chunk",
  "factory_status",
  "activity_log",
  "event_state",
  "build_layout",
  "build_block",
  "say",
  "say_now",
  "get_job",
  "blueprint_capture",
  "blueprint_create",
  "blueprint_list",
  "blueprint_describe",
  "blueprint_delete",
  "blueprint_export",
  "blueprint_place",
  "place_tiles",
] as const;

export type RpcMethod = (typeof RPC_METHODS)[number];

/** Reads the mod runs as jobs over several ticks: the RPC answers with the
 *  result when it fits the tick, else {job_id, job_status: "pending"}, and
 *  get_job returns the result once it is done. */
export const JOB_METHODS = [
  "observe_local", "inspect", "find_placement", "map_summary", "connect_entities", "build_layout", "build_block",
  "blueprint_capture", "blueprint_describe", "blueprint_place", "place_tiles",
] as const satisfies readonly RpcMethod[];

export function assertProtocolCompatibility(value: { protocol_version?: number }): void {
  if (value.protocol_version !== PROTOCOL_VERSION) {
    throw new Error(
      `protocol mismatch: mod v${value.protocol_version ?? "unknown"}, companion v${PROTOCOL_VERSION} — reinstall the matching mod and restart Factorio`,
    );
  }
}

const successEnvelopeSchema = z.object({
  ok: z.literal(true),
  data: z.unknown().optional(),
  chunked: z.literal(false).optional(),
});

export const chunkedEnvelopeSchema = z.object({
  ok: z.literal(true),
  chunked: z.literal(true),
  id: z.number().int().nonnegative(),
  parts: z.number().int().min(1),
  data: z.string(),
});

const errorEnvelopeSchema = z.object({
  ok: z.literal(false),
  error: z.string().min(1),
});

export const rpcEnvelopeSchema = z.union([
  chunkedEnvelopeSchema,
  successEnvelopeSchema,
  errorEnvelopeSchema,
]);

export type RpcEnvelope = z.infer<typeof rpcEnvelopeSchema>;

export function parseRpcEnvelope(raw: string): RpcEnvelope {
  const json: unknown = JSON.parse(raw);
  return rpcEnvelopeSchema.parse(json);
}
