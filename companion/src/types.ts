export interface ChunkedEnvelope { ok: true; chunked: true; id: number; parts: number; data: string }
export interface GetTaskResult { status: "queued" | "running" | "done" | "partial" | "failed" | "cancelled"; detail?: string; outcome?: Record<string, unknown> }
export interface Position { x: number; y: number }
export interface PlacementCandidate {
  item: string; entity: string; position: Position; direction: number;
  distance: number; distance_from_codex: number; terrain: "land" | "shoreline" | "offshore";
  output_position?: Position; pickup_position?: Position; drop_position?: Position;
  output_precondition?: { endpoint: Position; state: "bound" | "unbound";
    recipient: { name: string; type: string; position: Position } | null;
    requires_player_owned_target_before_placement: true };
  resource_coverage?: Array<{ name: string; entity_count: number; total_amount: number }>;
  fluid_connections?: FluidConnection[];
}
export interface FluidConnection {
  fluidbox_index: number; production_type?: string; filter?: string; connection_type?: string;
  flow_direction?: string; position: Position; target_position?: Position;
  connected_target?: { name: string; type: string; position: Position } | null;
}
export interface PlacementSearchResult {
  item: string; entity: string; preferred: Position;
  output_target?: { name: string; type: string; position: Position };
  rejected_no_compatible_resource?: number;
  candidates: PlacementCandidate[];
}
export interface MapSummary {
  tick: number; summary?: string; charted_chunks?: number;
  resources?: Array<{ name: string; entity_count: number; total_amount: number; nearest: Position; observed_tick: number }>;
  water_edges?: Array<{ land: Position; water: Position; observed_tick: number }>;
  factory_landmarks?: Array<{ name: string; type: string; position: Position; direction?: number; status?: string; recipe?: string; observed_tick: number }>;
  factory: {
    scope: "force_charted"; collected_at_tick: number; consistency: "single_request";
    charted_chunks: number; currently_visible_charted_chunks: number; machine_count: number;
    groups: Array<Record<string, unknown>>; force_flows: Array<Record<string, unknown>>;
    material_flow: { nodes: Array<Record<string, unknown>>; edges: Array<Record<string, unknown>>;
      components: Array<Record<string, unknown>>; diagnostics: Array<Record<string, unknown>>;
      component_count: number; edge_count: number; autonomous_component_count: number;
      validated_component_count: number; products_finished_total: number };
    character_transfers: Record<string, unknown>; omissions: Record<string, number>; partial: boolean;
  };
}
export interface ProductionRequirementNode {
  item: string; required_units: number; recipe: string; recipe_executions: number;
  output_units_per_execution: number; category: string; craft_time_seconds_per_execution: number;
  ingredient_units_per_execution: Record<string, number>; product_units_per_execution: Record<string, number>;
}
export interface ProductionRequirements {
  units: { targets: "item_or_fluid_units"; raw: "item_or_fluid_units"; products: "item_or_fluid_units"; time: "seconds_at_crafting_speed_1" };
  targets: Record<string, number>; nodes: ProductionRequirementNode[];
  raw: Record<string, number>; products: Record<string, number>; total_craft_time_seconds_at_speed_1: number;
}
export interface PhysicalRoute {
  kind: "belt" | "pipe" | "power"; prototype: string; from: Position; to: Position;
  length: number; steps: Array<{ name: string; x: number; y: number; direction?: number }>;
  physical: true; ghosts: false; status?: "completed" | "connected" | "placed_unconnected" | "placed_unverified"; detail?: string;
}
export interface ElectricalInspection {
  network_id?: number; energy?: number; buffer_capacity?: number; demand?: number;
  satisfaction?: number; power_usage?: number; power_production?: number;
  input_flow_limit?: number; output_flow_limit?: number; connected_poles?: number;
}
export interface PlanProblem { step?: number; action?: string; entity?: string; position?: Position; status?: string; detail: string }
export interface PlanDiagnostics { route: PlanProblem[]; machines: PlanProblem[] }
export type Task =
  | { type: "walk_to"; target: { x: number; y: number } }
  | { type: "mine"; target: { x: number; y: number }; count?: number; target_kind?: "natural" | "owned"; allow_fluid_loss?: boolean }
  | { type: "pickup"; target: Position; item: string; count: number }
  | { type: "place" | "rotate" | "set_recipe" | "insert" | "extract" | "craft"; [key: string]: unknown }
  | { type: "build_plan"; steps: unknown[]; auto_craft?: boolean; stop_on_error?: boolean };
