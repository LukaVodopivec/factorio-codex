export interface ChunkedEnvelope { ok: true; chunked: true; id: number; parts: number; data: string }
export interface GetTaskResult { status: "queued" | "running" | "done" | "failed" | "cancelled"; detail?: string }
export interface Position { x: number; y: number }
export interface PlacementCandidate {
  item: string; entity: string; position: Position; direction: number;
  distance: number; distance_from_codex: number; terrain: "land" | "shoreline" | "offshore";
}
export interface PlacementSearchResult { item: string; entity: string; preferred: Position; candidates: PlacementCandidate[] }
export interface MapSummary {
  tick: number; charted_chunks: number;
  resources: Array<{ name: string; entity_count: number; total_amount: number; nearest: Position }>;
  water_edges: Array<{ land: Position; water: Position }>;
  factory_landmarks: Array<{ name: string; type: string; position: Position; direction?: number; status?: string; recipe?: string; observed_tick: number }>;
}
export interface ProductionRequirementNode {
  item: string; required: number; recipe: string; crafts: number; output: number;
  category: string; time: number; ingredients: Record<string, number>; products: Record<string, number>;
}
export interface ProductionRequirements {
  item: string; count: number; nodes: ProductionRequirementNode[];
  raw: Record<string, number>; products: Record<string, number>; total_time: number;
}
export interface PhysicalRoute {
  kind: "belt" | "pipe" | "power"; prototype: string; from: Position; to: Position;
  length: number; steps: Array<{ name: string; x: number; y: number; direction?: number }>;
  physical: true; ghosts: false;
}
export interface ElectricalInspection {
  network_id?: number; energy?: number; buffer_capacity?: number; demand?: number;
  satisfaction?: number; connected_poles?: number;
}
export interface PlanProblem { step?: number; action?: string; entity?: string; position?: Position; status?: string; detail: string }
export interface PlanDiagnostics { route: PlanProblem[]; machines: PlanProblem[] }
export type Task =
  | { type: "walk_to"; target: { x: number; y: number } }
  | { type: "mine"; target: { x: number; y: number }; count?: number }
  | { type: "place" | "rotate" | "set_recipe" | "insert" | "extract" | "craft"; [key: string]: unknown }
  | { type: "build_plan"; steps: unknown[]; auto_craft?: boolean; stop_on_error?: boolean };
