export const toolPayloads = {
  target: ({ x, y, arrival_mode = "exact", arrival_radius = 1 }: { x: number; y: number; arrival_mode?: "exact" | "vicinity"; arrival_radius?: number }) => ({
    target: { x, y }, arrival_mode, arrival_radius,
  }),
  mine: ({ x, y, count, target_kind, allow_fluid_loss, expected_name, observed_tick }: { x: number; y: number; count?: number; target_kind?: "natural" | "owned"; allow_fluid_loss?: boolean; expected_name?: string; observed_tick?: number }) => ({ target: { x, y }, count, ...(target_kind ? { target_kind } : {}), ...(allow_fluid_loss ? { allow_fluid_loss: true } : {}), ...(expected_name ? { expected_name } : {}), ...(observed_tick === undefined ? {} : { observed_tick }) }),
  pickup: ({ x, y, item, count }: { x: number; y: number; item: string; count: number }) => ({ target: { x, y }, item, count }),
  craft: ({ recipe, crafts, wait_for_completion }: { recipe: string; crafts: number; wait_for_completion?: boolean }) => ({ recipe, count: crafts, ...(wait_for_completion === undefined ? {} : { wait_for_completion }) }),
  place: ({ x, y, name, direction, input_target, output_target }: { x: number; y: number; name: string; direction?: number; input_target?: { x: number; y: number }; output_target?: { x: number; y: number } }) => ({ item: name, position: { x, y }, direction, ...(input_target ? { input_target } : {}), ...(output_target ? { output_target } : {}) }),
  insert: ({ x, y, items: values }: { x: number; y: number; items: Record<string, number> }) => ({ target: { x, y }, items: values }),
  extract: ({ x, y, items: values }: { x: number; y: number; items?: Record<string, number> }) => values === undefined ? ({ target: { x, y }, all: true }) : ({ target: { x, y }, items: values }),
  recipe: ({ x, y, recipe }: { x: number; y: number; recipe: string }) => ({ target: { x, y }, recipe }),
  rotate: ({ x, y, direction }: { x: number; y: number; direction?: number }) => ({ target: { x, y }, direction }),
  inspect: (positions: Array<{ x: number; y: number }>) => ({ targets: positions }),
  placement: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  canPlace: (placements: Array<{ x: number; y: number; name: string; direction?: number }>) => ({ placements: placements.map((placement) => toolPayloads.placement(placement)) }),
  buildPlan: (steps: Array<{ x: number; y: number; name: string; [key: string]: unknown }>, rest: Record<string, unknown>) => ({ ...rest, steps: steps.map(({ x, y, name, ...step }) => ({ ...step, item: name, position: { x, y } })) }),
  findPlacement: ({ item, preferred, radius, directions, limit, input_target, output_target, output_recipient_item }: {
    item: string; preferred: { x: number; y: number }; radius: number; directions: number[]; limit: number;
    input_target?: { x: number; y: number }; output_target?: { x: number; y: number }; output_recipient_item?: string;
  }) => ({ item, preferred, radius, directions, limit,
    ...(input_target ? { input_target } : {}), ...(output_target ? { output_target } : {}),
    ...(output_recipient_item ? { output_recipient_item } : {}) }),
  productionRequirements: ({ targets, technology, location, recipe_choices, flow_precision }: {
    targets?: Record<string, number>; technology?: string; location?: string;
    recipe_choices?: Record<string, string>; flow_precision?: string;
  }) => ({ ...(targets ? { targets } : {}), ...(technology ? { technology } : {}),
    ...(location ? { location } : {}), ...(recipe_choices ? { recipe_choices } : {}),
    ...(flow_precision ? { flow_precision } : {}) }),
  connectEntities: ({ kind, prototype, from, to, max_length }: { kind: "belt" | "pipe" | "power"; prototype: string; from: { x: number; y: number }; to: { x: number; y: number }; max_length: number }) => ({ kind, prototype, from, to, max_length }),
};

export function normalizeCanPlace(value: any, placements: Array<{ name: string; x: number; y: number; direction?: number }>): any {
  if (!value || !Array.isArray(value.results)) return value;
  return { ...value, results: value.results.map((entry: any, index: number) => {
    const requested = placements[index];
    if (!requested) return entry;
    return {
      ...entry,
      item: requested.name,
      position: entry?.position ?? { x: requested.x, y: requested.y },
      direction: requested.direction ?? 0,
      ...(entry?.can_place === false && typeof entry.reason !== "string" ? { reason: "placement rejected by Factorio" } : {}),
      ...(entry?.output_lands_on === false ? { output_lands_on: null } : {}),
      ...(entry?.pickup_from === false ? { pickup_from: null } : {}),
      ...(entry?.overlaps_batch === undefined ? {} : { overlaps_batch: luaArray(entry.overlaps_batch) }),
    };
  }) };
}

function luaArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (value && typeof value === "object" && Object.keys(value).length === 0) return [];
  return value as unknown[];
}

// queue_plan/run_plan steps for one candidate: placements in build order, then
// the requested fuel into every burner inlet among them.
function placementPlanSteps(value: unknown, fuel?: Record<string, number>): any[] {
  const buildSteps: any[] = Array.isArray(value) ? value : [];
  const places = buildSteps.map((step) => ({
    action: "place_entity", x: step.x, y: step.y, name: step.name,
    ...(step.direction === undefined ? {} : { direction: step.direction }),
    ...(step.input_target ? { input_target: step.input_target } : {}),
    ...(step.output_target ? { output_target: step.output_target } : {}),
  }));
  const fuelSteps = fuel && Object.keys(fuel).length > 0
    ? buildSteps.filter((step) => step.fuel_inlet === true).map((step) => ({ action: "insert_items", x: step.x, y: step.y, items: fuel }))
    : [];
  return [...places, ...fuelSteps];
}

export function normalizePlacementSearch(value: any, fuel?: Record<string, number>): any {
  if (!value || typeof value !== "object") return value;
  return { ...value, candidates: luaArray(value.candidates).map((candidate: any) => ({
    ...candidate,
    build_steps: luaArray(candidate?.build_steps),
    ...(Array.isArray(luaArray(candidate?.build_steps)) ? { plan_steps: placementPlanSteps(luaArray(candidate?.build_steps), fuel) } : {}),
    ...(candidate?.output_target === false ? { output_target: null } : {}),
    ...(candidate?.output_position === undefined ? {} : { output_precondition: {
      endpoint: candidate.output_position,
      state: candidate.output_target && candidate.output_target !== false ? "bound" : "unbound",
      recipient: candidate.output_target && candidate.output_target !== false ? candidate.output_target : null,
      requires_player_owned_target_before_placement: true,
    } }),
    ...(candidate?.fluid_connections === undefined ? {} : { fluid_connections: luaArray(candidate.fluid_connections) }),
    ...(candidate?.resource_coverage === undefined ? {} : { resource_coverage: luaArray(candidate.resource_coverage) }),
  })) };
}

export function normalizeMapSummary(value: any): any {
  if (!value || typeof value !== "object") return value;
  const factory = value.factory && typeof value.factory === "object" ? value.factory : undefined;
  const materialFlow = factory?.material_flow && typeof factory.material_flow === "object" ? factory.material_flow : undefined;
  const transfers = factory?.character_transfers && typeof factory.character_transfers === "object" ? factory.character_transfers : undefined;
  return {
    ...value,
    resources: luaArray(value.resources),
    water_edges: luaArray(value.water_edges),
    factory_landmarks: luaArray(value.factory_landmarks),
    ...(factory ? { factory: {
      ...factory,
      groups: luaArray(factory.groups),
      force_flows: luaArray(factory.force_flows),
      ...(materialFlow ? { material_flow: { ...materialFlow,
        nodes: luaArray(materialFlow.nodes), edges: luaArray(materialFlow.edges),
        components: luaArray(materialFlow.components), diagnostics: luaArray(materialFlow.diagnostics),
      } } : {}),
      ...(transfers ? { character_transfers: { ...transfers,
        inserted_items: luaArray(transfers.inserted_items), extracted_items: luaArray(transfers.extracted_items),
        target_actions: luaArray(transfers.target_actions), events: luaArray(transfers.events),
        validations: luaArray(transfers.validations),
      } } : {}),
    } } : {}),
  };
}

export function normalizeProductionRequirements(value: any): any {
  if (!value || typeof value !== "object") return value;
  const deterministic = value.deterministic_requirements && typeof value.deterministic_requirements === "object"
    ? { ...value.deterministic_requirements, nodes: luaArray(value.deterministic_requirements.nodes),
      ambiguities: luaArray(value.deterministic_requirements.ambiguities),
      variable_operating_requirements: luaArray(value.deterministic_requirements.variable_operating_requirements) }
    : undefined;
  return { ...value, nodes: luaArray(value.nodes),
    ...(deterministic ? { deterministic_requirements: deterministic } : {}),
    missing_technologies: luaArray(value.missing_technologies),
    trigger_conditions: luaArray(value.trigger_conditions),
    force_flows: luaArray(value.force_flows),
    ambiguities: luaArray(value.ambiguities),
    variable_operating_requirements: luaArray(value.variable_operating_requirements),
  };
}

export function normalizePhysicalRoute(value: any): any {
  return value && typeof value === "object" ? { ...value, steps: luaArray(value.steps) } : value;
}

export function normalizeInspection(value: any): any {
  if (!value || !Array.isArray(value.entities)) return value;
  return { ...value, entities: value.entities.map((entity: any) => {
    if (!entity || entity.error) return entity;
    if (entity.drop_target === false) entity = { ...entity, drop_target: null };
    if (entity.fluid_connections !== undefined) entity = { ...entity,
      fluid_connections: luaArray(entity.fluid_connections).map((connection: any) => connection?.connected_target === false
        ? { ...connection, connected_target: null } : connection) };
    const hasElectricalMarker = entity.electrical !== undefined || entity.electric_network_id !== undefined
      || entity.electric_buffer_capacity !== undefined || entity.electric_demand !== undefined
      || entity.electric_satisfaction !== undefined || entity.connected_poles !== undefined;
    if (!hasElectricalMarker) return entity;
    const electrical = entity.electrical ?? {
      network_id: entity.electric_network_id,
      energy: entity.energy,
      buffer_capacity: entity.electric_buffer_capacity,
      demand: entity.electric_demand,
      satisfaction: entity.electric_satisfaction,
      connected_poles: entity.connected_poles,
    };
    const populated = Object.fromEntries(Object.entries(electrical).filter(([, item]) => item !== undefined));
    return Object.keys(populated).length > 0 ? { ...entity, electrical: populated } : entity;
  }) };
}

export function normalizePlanDiagnostics(value: any): any {
  if (!value || typeof value !== "object") return value;
  const active = value.diagnostics && typeof value.diagnostics === "object" ? value.diagnostics : undefined;
  const route = active?.route ? [{
    action: active.action,
    status: active.route.phase,
    detail: active.route.failure ?? `native path ${active.route.phase ?? "active"}`,
    retries: active.route.retries,
    request_tick: active.route.request_tick,
    last_progress_tick: active.route.last_progress_tick,
  }] : [];
  if (Array.isArray(value.outcomes)) route.push(...value.outcomes
    .filter((outcome: any) => outcome?.status === "failed" || outcome?.status === "cancelled")
    .map((outcome: any) => ({ step: outcome.step, action: outcome.action, detail: outcome.error ?? outcome.result ?? outcome.status })));
  const entities = Array.isArray(value.observation?.entities) ? value.observation.entities : [];
  const machines = entities
    .filter((entity: any) => entity?.status && !["working", "normal"].includes(entity.status))
    .map((entity: any) => ({ entity: entity.name, position: entity.position, status: entity.status, detail: `machine status: ${entity.status}` }));
  if (active?.machine) machines.unshift({
    position: active.machine.position,
    status: "active_target",
    detail: `active ${active.action ?? "plan"} target`,
  });
  const inspections = Array.isArray(value.outcomes) ? value.outcomes
    .filter((outcome: any) => outcome?.action === "inspect_entities" && typeof outcome?.result?.tick === "number")
    .map((outcome: any) => ({ step: outcome.step, inspection_tick: outcome.result.tick,
      entities: luaArray(outcome.result.entities), omitted_entities: outcome.result.omitted_entities ?? 0 })) : [];
  const auditTicks = inspections.map((entry: any) => entry.inspection_tick);
  const physicalAudit = inspections.length > 0 ? {
    audit_id: typeof value.plan_id === "number" ? `plan-${value.plan_id}` : "run-plan",
    start_tick: Math.min(...auditTicks), end_tick: Math.max(...auditTicks),
    snapshot_skew_ticks: Math.max(...auditTicks) - Math.min(...auditTicks), clusters: inspections,
    partial: value.status !== "completed" || inspections.some((entry: any) => entry.omitted_entities > 0),
    evidence_class: "time_skewed_physical_tour",
    semantics: "ordinary movement followed by local inspection; snapshots are not simultaneous",
  } : undefined;
  return {
    ...value,
    ...(value.transitions === undefined ? {} : { transitions: luaArray(value.transitions) }),
    diagnostics: { route, machines },
    ...(physicalAudit ? { physical_audit: physicalAudit } : {}),
  };
}

// The body idled while the caller reasoned; say so where the pilot looks next.
export function queuedPlanSummary(queued: { plan_id: number; body_idle_ticks?: number }): string {
  const idle = Math.floor((queued.body_idle_ticks ?? 0) / 60);
  return idle >= 10
    ? `queued plan ${queued.plan_id}; the body sat idle ${idle} s before it: queue work that outlasts your next decision and keep a successor queued`
    : `queued plan ${queued.plan_id}`;
}
