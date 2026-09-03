export const toolPayloads = {
  target: (value: { x: number; y: number }) => ({ target: value }),
  mine: ({ x, y, count, target_kind, allow_fluid_loss }: { x: number; y: number; count?: number; target_kind?: "natural" | "owned"; allow_fluid_loss?: boolean }) => ({ target: { x, y }, count, ...(target_kind ? { target_kind } : {}), ...(allow_fluid_loss ? { allow_fluid_loss: true } : {}) }),
  pickup: ({ x, y, item, count }: { x: number; y: number; item: string; count: number }) => ({ target: { x, y }, item, count }),
  craft: ({ recipe, crafts, wait_for_completion }: { recipe: string; crafts: number; wait_for_completion?: boolean }) => ({ recipe, count: crafts, ...(wait_for_completion === undefined ? {} : { wait_for_completion }) }),
  place: ({ x, y, name, direction, output_target }: { x: number; y: number; name: string; direction?: number; output_target?: { x: number; y: number } }) => ({ item: name, position: { x, y }, direction, ...(output_target ? { output_target } : {}) }),
  insert: ({ x, y, items: values }: { x: number; y: number; items: Record<string, number> }) => ({ target: { x, y }, items: values }),
  extract: ({ x, y, items: values }: { x: number; y: number; items?: Record<string, number> }) => values === undefined ? ({ target: { x, y }, all: true }) : ({ target: { x, y }, items: values }),
  recipe: ({ x, y, recipe }: { x: number; y: number; recipe: string }) => ({ target: { x, y }, recipe }),
  rotate: ({ x, y, direction }: { x: number; y: number; direction?: number }) => ({ target: { x, y }, direction }),
  inspect: (positions: Array<{ x: number; y: number }>) => ({ targets: positions }),
  placement: ({ x, y, name, direction }: { x: number; y: number; name: string; direction?: number }) => ({ item: name, position: { x, y }, direction }),
  canPlace: (placements: Array<{ x: number; y: number; name: string; direction?: number }>) => ({ placements: placements.map((placement) => toolPayloads.placement(placement)) }),
  buildPlan: (steps: Array<{ x: number; y: number; name: string; [key: string]: unknown }>, rest: Record<string, unknown>) => ({ ...rest, steps: steps.map(({ x, y, name, ...step }) => ({ ...step, item: name, position: { x, y } })) }),
  findPlacement: ({ item, preferred, radius, directions, limit, output_target }: { item: string; preferred: { x: number; y: number }; radius: number; directions: number[]; limit: number; output_target?: { x: number; y: number } }) => ({ item, preferred, radius, directions, limit, ...(output_target ? { output_target } : {}) }),
  productionRequirements: ({ targets, recipe_choices }: { targets: Record<string, number>; recipe_choices?: Record<string, string> }) => ({ targets, recipe_choices }),
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
    };
  }) };
}

function luaArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (value && typeof value === "object" && Object.keys(value).length === 0) return [];
  return value as unknown[];
}

export function normalizePlacementSearch(value: any): any {
  if (!value || typeof value !== "object") return value;
  return { ...value, candidates: luaArray(value.candidates).map((candidate: any) => ({
    ...candidate,
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
  return value && typeof value === "object" ? {
    ...value,
    resources: luaArray(value.resources),
    water_edges: luaArray(value.water_edges),
    factory_landmarks: luaArray(value.factory_landmarks),
  } : value;
}

export function normalizeProductionRequirements(value: any): any {
  return value && typeof value === "object" ? { ...value, nodes: luaArray(value.nodes) } : value;
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
  return {
    ...value,
    ...(value.transitions === undefined ? {} : { transitions: luaArray(value.transitions) }),
    diagnostics: { route, machines },
  };
}
