export interface ChunkedEnvelope { ok: true; chunked: true; id: number; parts: number; data: string }
export interface GetTaskResult { status: "queued" | "running" | "done" | "partial" | "failed" | "cancelled"; detail?: string; outcome?: Record<string, unknown>;
  /** Read from the mod: the body's FIFO state, including the current human hold. */
  fifo?: { human_control?: boolean };
  /** Set by the bridge: a human hold delayed this task (delayed, not failed). */
  human_control?: boolean }
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
    /** Read over several ticks (a job): started_tick to collected_at_tick. */
    scope: "force_charted"; started_tick: number; collected_at_tick: number; consistency: "spread_over_ticks";
    charted_chunks: number; currently_visible_charted_chunks: number; machine_count: number;
    /** Productive machines the registry counts: the one count factory_status and tooling use. */
    registry_machine_count: number;
    groups: Array<Record<string, unknown>>; force_flows: Array<Record<string, unknown>>;
    material_flow: { nodes: Array<Record<string, unknown>>; edges: Array<Record<string, unknown>>;
      components: Array<Record<string, unknown>>; diagnostics: Array<Record<string, unknown>>;
      component_count: number; edge_count: number; products_finished_total: number;
      /** Production lines the mod tracks (factory_status lines), whole factory. */
      line_count: number; running_line_count: number; self_sustaining_line_count: number; hand_fed_line_count: number };
    character_transfers: Record<string, unknown>; omissions: Record<string, number>; partial: boolean;
  };
  // Present only when named in `include`; own-force and charted-chunk scope.
  stockpiles?: Array<{ item: string; total: number; holders_omitted: number;
    holders: Array<{ entity: string; position: Position; count: number; kind: "chest" | "machine_output" | "belt" }> }>;
  stockpiles_omitted?: number;
  sites?: Array<{ chunk: Position; position: Position; machines: Record<string, number> }>; sites_omitted?: number;
  patches?: Array<{ name: string; amount: number; tiles: number; bbox: { left_top: Position; right_bottom: Position }; centroid: Position }>;
  patches_omitted?: number;
  power?: { networks_omitted: number; networks: PowerRow[] };
  problems?: Array<{ entity: string; position: Position; status: string }>; problems_total?: number;
  /** Every problem machine counted by normalized status, including rows past the cap. */
  problems_by_status?: Record<string, number>;
  force_flows_all?: Array<{ name: string; kind: "item" | "fluid"; produced_per_minute?: number; consumed_per_minute?: number;
    lifetime_produced: number; lifetime_consumed: number }>;
  force_flows_all_omitted?: number;
}
/** One electric network (factory_status power, map_summary include power). */
export interface PowerRow {
  network_id: number; satisfaction: number; production_w?: number; demand_w: number;
  /** Available now: steam/burner nameplate plus solar at the light now. */
  capacity_w: number;
  /** Day average with solar at its average light (planets only). */
  sustained_w?: number; headroom_w?: number;
  sources: Array<{ kind: "steam" | "solar" | "burner" | "nuclear" | "other"; count: number; nameplate_w: number; production_w?: number }>;
  accumulators: { count: number; stored_j: number; capacity_j: number; charge: number } | null;
  night_s?: number;
  /** Only while sustained_w < demand_w. */
  add_to_cover?: { steam_engine?: number; solar_panel?: number; accumulator?: number };
}
export type LineState = "running" | "starved" | "output_full" | "no_fuel" | "no_power" | "no_heat" | "disabled" | "idle";
export interface FactoryLine {
  id: number | string; product?: string; entity?: string; machines: number; working: number; state: LineState;
  rate_per_min?: number; hand_fed: boolean; self_sustaining: boolean; position: Position; hand_transfers?: number;
  /** Why the worst machine stops: a fluid name, no_recipe, recipe_not_researched, burnt_result, an item. */
  cause?: string; cause_position?: Position;
  /** Lowest heat-source temperature on a line with a reactor or heat exchanger. */
  temperature?: number;
}
/** factory_status sections:["logistics"]: robot networks nearest the body. */
export interface LogisticsSection {
  networks: Array<{ network_id: number; cells: number; cells_read?: number;
    robots: { logistic: { all: number; available: number }; construction: { all: number; available: number } };
    charging_queue: number; coverage: Array<{ position: Position; logistic_radius: number; construction_radius: number }>;
    contents: Array<{ item: string; count: number }> }>;
  omitted_networks?: number;
}
/** inspect_entity envelope: a remote (own-force, charted) read widens the evidence class and scope. */
export interface InspectionResult {
  tick: number;
  /** The tick the read began, when it spread over several (about 15 entities a tick). */
  first_tick?: number;
  evidence_class: "fresh_local_exact" | "fresh_exact_local_and_charted_remote";
  scope: "within_30_tiles_of_codex_at_source_tick" | "within_30_tiles_or_own_force_charted_at_source_tick";
  entities: Array<Record<string, unknown>>;
  /** Positions past the 64 read. */
  omitted?: number;
}
/** Human takeover state carried by every fifo block and observe_local.character. */
export interface HumanControl { human_control: boolean; human_idle_ticks?: number }
/** mine outcome when own mining drills already mine the hand-mined resource. */
export interface MineDrillHint { drill_produced: true; drills: number; stockpile_total?: number }
/** pickup_items outcome for a belt source. */
export interface BeltPickupOutcome { source: "belt"; item: string; requested: number; picked_up: number;
  belt: { name: string; position: Position } }
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
