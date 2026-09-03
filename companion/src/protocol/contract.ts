import { z } from "zod";

export const PROTOCOL_VERSION = 13;

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
  "connect_entities",
  "describe_prototype",
  "progression_status",
  "enqueue",
  "get_task",
  "queue_plan",
  "plan_status",
  "cancel",
  "get_chunk",
] as const;

export type RpcMethod = (typeof RPC_METHODS)[number];

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
