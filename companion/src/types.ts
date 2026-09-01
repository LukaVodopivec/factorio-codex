export interface ChunkedEnvelope { ok: true; chunked: true; id: number; parts: number; data: string }
export interface GetTaskResult { status: "queued" | "running" | "done" | "failed" | "cancelled"; detail?: string }
export type Task =
  | { type: "walk_to"; target: { x: number; y: number } }
  | { type: "mine"; target: { x: number; y: number } }
  | { type: "place" | "rotate" | "set_recipe" | "insert" | "extract" | "craft"; [key: string]: unknown }
  | { type: "build_plan"; steps: unknown[]; auto_craft?: boolean; stop_on_error?: boolean };
