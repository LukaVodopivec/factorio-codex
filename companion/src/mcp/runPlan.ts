import { z } from "zod";
import { DEFAULT_TASK_TIMEOUT_MS, holdAwareDeadline, outcomeUnknown, TaskCancelledError, type TaskClock } from "../bridge.js";
import { RconError } from "../rcon.js";
import type { Bridge } from "../bridge.js";
import { normalizeObservation } from "./observation.js";

const position = { x: z.number(), y: z.number() };
const point = z.object(position).strict();
const items = z.record(z.string(), z.number().int().positive());
const offset = z.object({ dx: z.number(), dy: z.number() }).strict();
const direction = z.number().int().min(0).max(15);
const itemName = z.string().min(1);
/** null or false is "none" (the mod receives false: a Lua table cannot hold null). */
const orNone = <T extends z.ZodType>(value: T) => z.union([value, z.null(), z.literal(false)])
  .transform((setting) => setting === null ? false as const : setting);
const named = { message: "name at least one setting" };
const side = z.enum(["left", "none", "right"]);
/** What a player sets in an entity's window: one object for configure_entity,
 *  layout and blueprint entities and build_plan steps. */
export const settingsGroups = {
  inserter: z.object({ filters: z.array(itemName).max(5).optional(), mode: z.enum(["whitelist", "blacklist"]).optional(),
    stack_size: z.number().int().min(0).optional(), spoil_priority: z.enum(["fresh_first", "spoiled_first", "none"]).optional() })
    .strict().refine((group) => Object.keys(group).length > 0, named).optional(),
  splitter: z.object({ input_priority: side.optional(), output_priority: side.optional(), filter: orNone(itemName).optional() })
    .strict().refine((group) => Object.keys(group).length > 0, named).optional(),
  chest: z.object({ slots: orNone(z.number().int().min(0)).optional(), storage_filter: orNone(itemName).optional() })
    .strict().refine((group) => Object.keys(group).length > 0, named).optional(),
  /** An asteroid collector's chunk filters; [] clears them. */
  collector: z.object({ filters: z.array(itemName).optional() })
    .strict().refine((group) => Object.keys(group).length > 0, named).optional(),
  /** A rocket silo's automatic requests (the game's transitional requests). */
  silo: z.object({ auto_requests: z.boolean().optional() })
    .strict().refine((group) => Object.keys(group).length > 0, named).optional(),
};
const SETTINGS_MESSAGE = "settings name at least one of inserter, splitter, chest, collector or silo";
export const settingsIssue = (value: Partial<Record<keyof typeof settingsGroups, unknown>>) =>
  Object.keys(settingsGroups).every((group) => value[group as keyof typeof settingsGroups] === undefined) ? SETTINGS_MESSAGE : null;
export const entitySettings = z.object(settingsGroups).strict()
  .refine((value) => settingsIssue(value) === null, { message: SETTINGS_MESSAGE });
/** An entity's inventories by role (extract_items, insert_items); rocket is a silo's rocket cargo. */
export const inventoryRole = z.enum(["main", "input", "output", "fuel", "burnt_result", "modules", "trash", "robots", "material", "rocket"]);
/** A space platform by name or index (the mod's one resolver). */
export const platformSelector = z.union([z.string().min(1).max(60), z.number().int().min(1)]);
/** A surface: a planet name ("nauvis", "vulcanus", ...), "platform:<index>",
 *  or {platform: name or index}. */
export const surfaceRef = z.union([z.string().min(1).max(80), z.object({ platform: platformSelector }).strict()]);
/** A stored blueprint's name (the mod's rule). */
export const blueprintName = z.string().min(1).max(64)
  .regex(/^[A-Za-z0-9][A-Za-z0-9 ._-]*$/, "blueprint names are letters, digits, spaces, dots, dashes or underscores");
type Fields = Record<string, unknown>;
const isFields = (value: unknown): value is Fields => !!value && typeof value === "object" && !Array.isArray(value);
const SPOIL_FROM_BLUEPRINT: Record<string, string> = { "fresh-first": "fresh_first", "spoiled-first": "spoiled_first" };
const filterName = (filter: unknown) => typeof filter === "string" ? filter
  : isFields(filter) && typeof filter.name === "string" ? filter.name : undefined;
/** 0.21.1 blueprint fields (what free-form layout settings held then) as
 *  typed settings, by the fields each group's window has: a filtering
 *  inserter's filters, mode, stack size and spoil priority; a splitter's
 *  priorities and filter; a chest's bar (0.21.1 kept the inventory's bar
 *  index: slots = bar - 1). Anything else is dropped. */
function legacySettings(old: Fields): Fields | undefined {
  const out: Fields = {};
  const inserter: Fields = {};
  if (old.use_filters === true && Array.isArray(old.filters)) {
    const names = [...old.filters].filter(isFields)
      .sort((a, b) => Number(a.index ?? 0) - Number(b.index ?? 0))
      .map(filterName).filter((name): name is string => !!name).slice(0, 5);
    if (names.length > 0) inserter.filters = names;
  }
  if (old.filter_mode === "blacklist") inserter.mode = "blacklist";
  if (typeof old.override_stack_size === "number" && old.override_stack_size > 0) inserter.stack_size = old.override_stack_size;
  if (typeof old.spoil_priority === "string" && SPOIL_FROM_BLUEPRINT[old.spoil_priority]) inserter.spoil_priority = SPOIL_FROM_BLUEPRINT[old.spoil_priority];
  if (Object.keys(inserter).length > 0) out.inserter = inserter;
  const splitter: Fields = {};
  for (const sideField of ["input_priority", "output_priority"]) {
    if (old[sideField] === "left" || old[sideField] === "right") splitter[sideField] = old[sideField];
  }
  const filter = filterName(old.filter);
  if (filter) splitter.filter = filter;
  if (Object.keys(splitter).length > 0) out.splitter = splitter;
  if (typeof old.bar === "number") out.chest = { slots: Math.max(0, Math.floor(old.bar) - 1) };
  return Object.keys(out).length > 0 ? out : undefined;
}
/** A 0.21.1 layout entity kept its underground end (settings.type), mirror
 *  and blueprint fields in free-form settings; an operations ledger or a
 *  notebook from then still holds them. They become belt_to_ground_type,
 *  mirror and typed settings; settings that already name a group, or none,
 *  are left for the schema to judge. */
export function upgradeLayoutEntity(value: unknown): unknown {
  if (!isFields(value) || !isFields(value.settings)) return value;
  const old = value.settings;
  const keys = Object.keys(old);
  if (keys.length === 0 || keys.some((key) => key in settingsGroups)) return value;
  const { settings: _legacy, ...entity } = value;
  if (entity.belt_to_ground_type === undefined && (old.type === "input" || old.type === "output")) entity.belt_to_ground_type = old.type;
  if (entity.mirror === undefined && typeof old.mirror === "boolean") entity.mirror = old.mirror;
  const typed = legacySettings(old);
  return typed ? { ...entity, settings: typed } : entity;
}
const tileOffset = z.object({ dx: z.number().int(), dy: z.number().int() }).strict();
/** Platform foundation a layout adds (the mod's caps). */
/** The liquids a build_layout site may be near (an offshore pump pumps them). */
export const LIQUIDS = ["water", "lava", "heavy-oil", "ammoniacal-solution"] as const;
export const MAX_LAYOUT_TILE_ENTRIES = 400;
export const MAX_LAYOUT_TILES = 1_000;
/** Relative layout the mod sites, checks, supplies, clears and builds
 *  (build_layout); mode ghosts or a platform places it as ghosts, and a
 *  platform layout may add foundation tiles. */
export const layoutFields = {
  anchor: point.optional(),
  mode: z.enum(["hand", "ghosts"]).optional(),
  platform: platformSelector.optional(),
  tiles: z.array(z.object({ name: itemName, dx: z.number().int(), dy: z.number().int() }).strict()).max(MAX_LAYOUT_TILE_ENTRIES).optional(),
  tile_rects: z.array(z.object({ name: itemName, from: tileOffset, to: tileOffset }).strict()).optional(),
  site: z.object({ near: point, on_resource: z.string().min(1).optional(), near_water: z.boolean().optional(),
    near_liquid: z.enum(LIQUIDS).optional() }).strict().optional(),
  entities: z.array(z.preprocess(upgradeLayoutEntity, z.object({ name: z.string().min(1), dx: z.number(), dy: z.number(),
    direction: direction.optional(), recipe: z.string().min(1).optional(), insert: items.optional(),
    mirror: z.boolean().optional(), belt_to_ground_type: z.enum(["input", "output"]).optional(),
    settings: entitySettings.optional() }).strict())).max(100),
  connections: z.array(z.object({ kind: z.enum(["belt", "pipe", "power"]), prototype: z.string().min(1),
    from: offset, to: offset, underground: z.union([z.string().min(1), z.literal(false)]).optional() }).strict()).max(32).optional(),
};
/** An area {left_top, right_bottom}, or center with radius (at most 64 x 64 tiles). */
export const areaFields = {
  area: z.object({ left_top: point, right_bottom: point }).strict().optional(),
  center: point.optional(),
  radius: z.number().positive().max(32).optional(),
};
export const moveEntityFields = { from: point, to: point, direction: direction.optional(), allow_fluid_loss: z.boolean().optional(), mode: z.enum(["body", "robots"]).optional() };
/** get_items: craft false takes, smelts and gathers only, never hand-crafts (absent: true). */
export const getItemsFields = { item: z.string().min(1), count: z.number().int().min(1).max(5000), craft: z.boolean().optional() };
export const exploreFields = { resource: z.string().min(1).optional(), direction: direction.optional(),
  max_distance: z.number().int().min(32).max(3000) };
/** With platform (ghosts only) position is relative to the platform's hub. */
export const blueprintPlaceFields = { name: blueprintName, position: point,
  direction: z.number().int().min(0).max(12).multipleOf(4).optional(), flip: z.enum(["horizontal", "vertical"]).optional(),
  mode: z.enum(["hand", "ghosts"]).optional(), platform: platformSelector.optional() };
/** With platform (robots or cancel only) the area is on that platform. */
export const deconstructFields = { ...areaFields, mode: z.enum(["hand", "robots", "cancel"]).optional(),
  filter: z.array(z.string().min(1)).min(1).max(32).optional(), platform: platformSelector.optional() };
export const upgradeFields = { ...areaFields, from: z.string().min(1), to: z.string().min(1), mode: z.enum(["hand", "robots"]).optional() };
export const copySettingsFields = { from: point, to: z.array(point).min(1).max(32) };
/** insert_items: one position with items, or several targets that each get
 *  the same items (per_target or items). */
export const insertFields = {
  x: z.number().optional(), y: z.number().optional(),
  targets: z.union([z.array(point).min(1).max(32),
    z.object({ name: z.string().min(1), near: point, radius: z.number().positive().max(32).optional() }).strict()]).optional(),
  items: items.optional(), per_target: items.optional(), inventory: inventoryRole.optional(),
};
/** Positions one inspection reads; the mod reports the rest as omitted. */
export const INSPECT_LIMIT = 64;
const autoSupply = { auto_supply: z.boolean().optional() };
export const configureFields = { ...position, platform: platformSelector.optional(), ...settingsGroups };
/** place_tiles: exactly one of area or positions, at most 1,024 tiles. */
export const tilesFields = { item: itemName, area: z.object({ left_top: point, right_bottom: point }).strict().optional(),
  positions: z.array(point).min(1).max(1024).optional(), ...autoSupply };
/** A chest or landing pad at {x, y}, or a platform's hub ({platform}). */
/** A chest or landing pad at {x, y}, a platform's hub, or the body's own
 *  personal requests ("character"). */
export const requestsTarget = z.union([point, z.object({ platform: platformSelector }).strict(), z.literal("character")]);
export const requestsFields = { target: requestsTarget, section: z.union([z.number().int().min(1), z.string().min(1)]).optional(),
  mode: z.enum(["merge", "set"]).optional(),
  requests: z.array(z.object({ item: itemName, min: z.number().int().min(0), max: z.number().int().min(0).optional(),
    quality: z.literal("normal").optional(), import_from: itemName.optional(),
    minimum_delivery_count: z.number().int().min(1).optional() }).strict()).max(60).optional(),
  remove: z.array(itemName).min(1).max(60).optional(), request_from_buffers: z.boolean().optional(),
  /** The body's own requests only: items robots take away, and auto-trash. */
  trash: z.array(itemName).min(1).max(60).optional(), trash_unrequested: z.boolean().optional() };
/** planet: over that unlocked planet instead of the body's. */
export const createPlatformFields = { name: z.string().min(1).max(60), quality: z.literal("normal").optional(),
  planet: itemName.optional() };
/** cargo: items and counts, or "requests" (what the platform hub's requests still lack). */
export const launchRocketFields = { silo: point, platform: platformSelector,
  cargo: z.union([z.literal("requests"), z.record(itemName, z.number().int().positive())
    .refine((cargo) => Object.keys(cargo).length >= 1 && Object.keys(cargo).length <= 20, "cargo names 1-20 items")]).optional(),
  partial: z.boolean().optional() };
/** The game's WaitConditionType literals (2.0.77). */
export const WAIT_CONDITION_TYPES = ["time", "full", "empty", "not_empty", "item_count", "circuit", "inactivity", "robots_inactive",
  "fluid_count", "passenger_present", "passenger_not_present", "fuel_item_count_all", "fuel_item_count_any", "fuel_full",
  "destination_full_or_no_path", "request_satisfied", "request_not_satisfied", "all_requests_satisfied",
  "any_request_not_satisfied", "any_request_zero", "any_planet_import_zero", "specific_destination_full",
  "specific_destination_not_full", "at_station", "not_at_station", "damage_taken"] as const;
/** A wait condition as the game's own WaitCondition literal; the mod checks
 *  what the game keeps by reading the schedule back. */
const waitCondition = z.object({ type: z.enum(WAIT_CONDITION_TYPES), compare_type: z.enum(["and", "or"]).optional(),
  ticks: z.number().int().min(0).optional(), condition: z.record(z.string(), z.unknown()).optional(),
  planet: itemName.optional(), station: itemName.optional(), damage: z.number().int().min(0).optional() }).strict();
/** A platform's route: its stops (replacing the old ones), the stop to head
 *  for (1-based) and whether it holds still. */
export const platformRouteFields = { platform: platformSelector,
  stops: z.array(z.object({ location: itemName, wait: z.array(waitCondition).max(10).optional(),
    unloading: z.boolean().optional() }).strict()).min(1).max(10).optional(),
  go_to: z.number().int().min(1).optional(), paused: z.boolean().optional() };
/** The body goes to another surface: up by rocket to a platform, or down to a planet. */
export const travelFields = { to: surfaceRef, via_silo: point.optional(), max_wait_minutes: z.number().int().min(1).max(240).optional() };
export const equipFields = { armor: z.union([itemName, z.literal(false)]).optional(),
  put: z.array(z.object({ name: itemName, x: z.number().int().min(0).optional(), y: z.number().int().min(0).optional() }).strict()).min(1).max(20).optional(),
  take: z.array(z.union([z.object({ name: itemName }).strict(), z.object({ x: z.number().int().min(0), y: z.number().int().min(0) }).strict()])).min(1).max(20).optional(),
  ...autoSupply };
const planSteps = [
  z.object({ action: z.literal("walk_to"), ...position,
    arrival_mode: z.enum(["exact", "vicinity"]).default("exact"),
    arrival_radius: z.number().min(0.5, "arrival_radius is 0.5–6 tiles").max(6, "arrival_radius is 0.5–6 tiles; for a farther goal walk to the target and use vicinity arrival").default(1) }).strict(),
  z.object({ action: z.literal("mine"), ...position, count: z.number().int().min(1).max(200).default(1), target_kind: z.enum(["natural", "owned"]).optional(), allow_fluid_loss: z.boolean().default(false), expected_name: z.string().min(1).optional(), observed_tick: z.number().int().nonnegative().optional() }).strict(),
  z.object({ action: z.literal("pickup_items"), ...position, item: z.string().min(1), count: z.number().int().min(1).max(10000) }).strict(),
  z.object({ action: z.literal("place_entity"), ...position, name: z.string(), direction: z.number().int().optional(), input_target: point.optional(), output_target: point.optional(), belt_to_ground_type: z.enum(["input", "output"]).optional(), mirror: z.boolean().optional(), insert: items.optional(), ...autoSupply }).strict(),
  z.object({ action: z.literal("craft_items"), recipe: z.string(), crafts: z.number().int().min(1).max(100), wait_for_completion: z.boolean().optional() }).strict(),
  z.object({ action: z.literal("insert_items"), ...insertFields, ...autoSupply }).strict(),
  z.object({ action: z.literal("extract_items"), ...position, items: items.optional(), inventory: inventoryRole.optional() }).strict(),
  z.object({ action: z.literal("set_recipe"), ...position, recipe: z.string(), platform: platformSelector.optional() }).strict(),
  z.object({ action: z.literal("rotate_entity"), ...position, direction: direction.optional() }).strict(),
  z.object({ action: z.literal("inspect_entities"), positions: z.array(point).min(1).max(INSPECT_LIMIT) }).strict(),
  z.object({ action: z.literal("wait_for_item"), ...position, inventory: z.enum(["input", "output", "fuel", "main"]), item: z.string(), count: z.number().int().positive(), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("wait_for_research"), technology: z.string().min(1), timeout_seconds: z.number().min(1).max(300).default(120) }).strict(),
  z.object({ action: z.literal("get_items"), ...getItemsFields }).strict(),
  z.object({ action: z.literal("build_layout"), ...layoutFields }).strict(),
  z.object({ action: z.literal("explore"), ...exploreFields }).strict(),
  z.object({ action: z.literal("move_entity"), ...moveEntityFields }).strict(),
  z.object({ action: z.literal("blueprint_place"), ...blueprintPlaceFields }).strict(),
  z.object({ action: z.literal("build_ghosts"), ...areaFields }).strict(),
  z.object({ action: z.literal("deconstruct_area"), ...deconstructFields }).strict(),
  z.object({ action: z.literal("upgrade_area"), ...upgradeFields }).strict(),
  z.object({ action: z.literal("copy_settings"), ...copySettingsFields }).strict(),
  z.object({ action: z.literal("configure_entity"), ...configureFields }).strict(),
  z.object({ action: z.literal("flush_fluid"), ...position, fluid: itemName.optional() }).strict(),
  z.object({ action: z.literal("place_tiles"), ...tilesFields }).strict(),
  z.object({ action: z.literal("set_requests"), ...requestsFields }).strict(),
  z.object({ action: z.literal("equip"), ...equipFields }).strict(),
  z.object({ action: z.literal("create_platform"), ...createPlatformFields }).strict(),
  z.object({ action: z.literal("launch_rocket"), ...launchRocketFields }).strict(),
  z.object({ action: z.literal("set_platform_route"), ...platformRouteFields }).strict(),
  z.object({ action: z.literal("travel"), ...travelFields }).strict(),
] as const;
export const planStepSchema = z.discriminatedUnion("action", [...planSteps]);
/** A build package may also start with blueprint captures, which the bridge
 *  makes before it queues the package's other steps. */
export const captureFields = { name: blueprintName, ...areaFields };
export const packageStepSchema = z.discriminatedUnion("action", [...planSteps,
  z.object({ action: z.literal("blueprint_capture"), ...captureFields }).strict()]);
export type PlanStep = z.infer<typeof planStepSchema>;
export type PackageStep = z.infer<typeof packageStepSchema>;

/** Cross-field rules one step's object schema cannot express; a message or null. */
export function areaIssue(value: { area?: unknown; center?: unknown; radius?: unknown }): string | null {
  const centred = value.center !== undefined || value.radius !== undefined;
  if ((value.area === undefined) === !centred) return "give either area {left_top, right_bottom} or center with radius";
  if (centred && (value.center === undefined || value.radius === undefined)) return "center and radius go together";
  return null;
}
export function insertIssue(value: { x?: number; y?: number; targets?: unknown; items?: unknown; per_target?: unknown }): string | null {
  if ((value.items === undefined) === (value.per_target === undefined)) return "give items or per_target, not both";
  if (value.targets === undefined) {
    if (value.x === undefined || value.y === undefined) return "give x and y, or targets";
    if (value.per_target !== undefined) return "per_target goes with targets; use items for one position";
  } else if (value.x !== undefined || value.y !== undefined) return "give x and y, or targets, not both";
  return null;
}
export function tilesIssue(value: { area?: unknown; positions?: unknown }): string | null {
  return (value.area === undefined) === (value.positions === undefined)
    ? "give exactly one of area {left_top, right_bottom} or positions" : null;
}
/** A layout gives exactly one of anchor or site; it has entities, or only
 *  connections (or, on a platform, foundation tiles) from an anchor. A
 *  platform layout is ghosts from an anchor relative to the hub; tiles are
 *  platform foundation only. The mod checks the same rules. */
export function layoutIssue(value: { anchor?: unknown; site?: unknown; mode?: string; platform?: unknown; entities: Array<{ insert?: unknown }>;
  connections?: unknown[]; tiles?: unknown[]; tile_rects?: Array<{ from: { dx: number; dy: number }; to: { dx: number; dy: number } }> }): string | null {
  if ((value.anchor === undefined) === (value.site === undefined)) return "give exactly one of anchor or site";
  const tiles = (value.tiles?.length ?? 0) + (value.tile_rects ?? []).reduce((total, rect) =>
    total + (Math.abs(rect.to.dx - rect.from.dx) + 1) * (Math.abs(rect.to.dy - rect.from.dy) + 1), 0);
  if (value.platform === undefined) {
    if (value.tiles !== undefined || value.tile_rects !== undefined) return "tiles and tile_rects are platform foundation (with platform); on a planet use place_tiles";
  } else {
    if (value.mode === "hand") return "a platform is built from ghosts (mode ghosts): the body is not there";
    if (value.site !== undefined) return "a platform layout takes an anchor relative to the hub, not a site";
    if (tiles > MAX_LAYOUT_TILES) return `tiles and tile_rects name more than ${MAX_LAYOUT_TILES} tiles`;
  }
  if (value.entities.length === 0 && !(value.anchor !== undefined && ((value.connections?.length ?? 0) > 0 || tiles > 0)))
    return "a layout needs entities, or connections (or platform tiles) from an anchor";
  if ((value.mode === "ghosts" || value.platform !== undefined) && value.entities.some((entity) => entity.insert !== undefined))
    return "insert is for hand builds: ghosts take no starting items";
  return null;
}
export function blueprintPlaceIssue(value: { mode?: string; platform?: unknown }): string | null {
  return value.platform !== undefined && value.mode === "hand" ? "a platform is built from ghosts (mode ghosts): the body is not there" : null;
}
export function deconstructIssue(value: { area?: unknown; center?: unknown; radius?: unknown; mode?: string; platform?: unknown }): string | null {
  if (value.platform !== undefined && value.mode === "hand") return "on a platform the hub deconstructs (mode robots or cancel): the body is not there";
  return areaIssue(value);
}
export function requestsIssue(value: { target: { platform?: unknown } | { x: number; y: number } | "character"; mode?: string;
  requests?: Array<{ item: string; min: number; max?: number; import_from?: string; minimum_delivery_count?: number }>; remove?: unknown;
  request_from_buffers?: unknown; trash?: string[]; trash_unrequested?: boolean }): string | null {
  const requests = value.requests ?? [];
  if (requests.length === 0 && value.remove === undefined && value.request_from_buffers === undefined && value.mode !== "set"
    && value.trash === undefined && value.trash_unrequested === undefined)
    return "give requests, remove, request_from_buffers, trash, trash_unrequested or mode set";
  const character = value.target === "character";
  const hub = !character && typeof value.target === "object" && "platform" in value.target;
  if (!hub && requests.some((request) => request.import_from !== undefined || request.minimum_delivery_count !== undefined))
    return "import_from and minimum_delivery_count are for a platform hub ({platform})";
  if ((hub || character) && value.request_from_buffers !== undefined) return "request_from_buffers is for a requester chest";
  if (!character && (value.trash !== undefined || value.trash_unrequested !== undefined))
    return "trash and trash_unrequested are for target \"character\"";
  const bad = requests.find((request) => request.max !== undefined && request.max < request.min);
  if (bad) return `${bad.item}: max must be at least min`;
  if (requests.length + (value.trash?.length ?? 0) > 60) return "requests and trash name at most 60 items together";
  const names = [...requests.map((request) => request.item), ...(value.trash ?? [])];
  const repeated = names.find((name, index) => names.indexOf(name) !== index);
  return repeated ? `${repeated} is requested or trashed twice` : null;
}
export function equipIssue(value: { armor?: unknown; put?: Array<{ x?: number; y?: number }>; take?: unknown }): string | null {
  if (value.armor === undefined && value.put === undefined && value.take === undefined) return "give armor, put or take";
  return value.put?.some((entry) => (entry.x === undefined) !== (entry.y === undefined)) ? "a put entry gives x and y together, or neither" : null;
}
export function routeIssue(value: { stops?: unknown[]; go_to?: number; paused?: boolean }): string | null {
  if (value.stops === undefined && value.go_to === undefined && value.paused === undefined) return "give stops, go_to or paused";
  return value.stops !== undefined && value.go_to !== undefined && value.go_to > value.stops.length
    ? "go_to is the number of one of the stops" : null;
}
export function stepIssue(step: PackageStep): string | null {
  switch (step.action) {
    case "walk_to": return step.arrival_mode === "exact" && step.arrival_radius !== 1
      ? "exact arrival uses the fixed 1-tile tolerance; use vicinity for a wider radius" : null;
    case "build_layout": return layoutIssue(step);
    case "insert_items": return insertIssue(step);
    case "build_ghosts": case "upgrade_area": case "blueprint_capture": return areaIssue(step);
    case "deconstruct_area": return deconstructIssue(step);
    case "blueprint_place": return blueprintPlaceIssue(step);
    case "configure_entity": return settingsIssue(step);
    case "place_tiles": return tilesIssue(step);
    case "set_requests": return requestsIssue(step);
    case "equip": return equipIssue(step);
    case "set_platform_route": return routeIssue(step);
    default: return null;
  }
}
export const MAX_PLAN_STEPS = 200;
export const queuePlanSchema = z.object({
  steps: z.array(planStepSchema).min(1).max(MAX_PLAN_STEPS),
  final_observation_radius: z.number().int().min(5, "final_observation_radius is an integer 5–30 (default 15)").max(30, "final_observation_radius is an integer 5–30 (default 15)").default(15),
  observation_detail: z.enum(["none", "compact"]).default("none"),
  after_plan_id: z.number().int().positive().optional(),
  /** The surface the plan's positions are on; default the destination of a
   *  pending travel, else the body's surface. */
  surface: surfaceRef.optional(),
}).strict().superRefine((plan, context) => {
  plan.steps.forEach((step, index) => {
    const issue = stepIssue(step);
    if (issue) context.addIssue({ code: "custom", path: ["steps", index], message: issue });
  });
});
export const runPlanSchema = queuePlanSchema;
export const planStatusSchema = z.object({
  plan_id: z.number().int().positive(),
  wait_until: z.enum(["current", "progress", "terminal"]).default("current"),
  timeout_seconds: z.number().int().min(1).max(60).default(30),
}).strict();
export type RunPlanInput = z.infer<typeof runPlanSchema>;
export interface PlanOutcome { step: number; action: RunPlanInput["steps"][number]["action"]; status: "completed" | "partial" | "failed" | "cancelled"; result?: unknown; error?: string }
export interface RunPlanResult {
  plan_id?: number; status: "queued" | "running" | "waiting" | "completed" | "partial" | "failed" | "cancelled"; source_tick?: number;
  position?: { x: number; y: number }; current_step?: number; completed_steps?: number;
  total_steps?: number; outcomes: PlanOutcome[]; queue_depth?: number;
  observation?: Record<string, unknown>; observation_error?: string;
  execution?: { mode: "sequential_nontransactional"; rollback: "none"; committed_steps?: number[]; effects_state?: "unknown";
    incomplete_step?: { step: number; status: "failed" | "cancelled"; effects: "unknown" } };
  wait?: { condition: "progress" | "terminal"; timed_out: boolean; waited_ms: number };
  /** Present only when a human hold delayed this plan: delayed, not failed. */
  human_control?: boolean;
  /** The body's FIFO state from the same Lua read; human_control is the current hold. */
  fifo?: { human_control?: boolean };
  summary?: string;
}
const realClock: TaskClock = { now: () => Date.now(), sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) };

const terminalStatuses = new Set(["completed", "partial", "failed", "cancelled"]);
function isTerminal(status: RunPlanResult): boolean { return terminalStatuses.has(status.status); }
function progressMarker(status: RunPlanResult): string {
  return `${status.outcomes?.length ?? 0}:${status.status === "waiting" ? "waiting" : "active"}:${isTerminal(status) ? "terminal" : "open"}`;
}

/** Wait through the existing plan_status RPC. A request abort stops monitoring only;
 * callers that own cancellation must do so explicitly. */
export async function waitForPlanStatus(
  bridge: Bridge,
  planId: number,
  condition: "current" | "progress" | "terminal" = "current",
  timeoutMs = 30_000,
  signal?: AbortSignal,
  clock: TaskClock = realClock,
): Promise<RunPlanResult> {
  const started = clock.now();
  let status = await bridge.call<RunPlanResult>("plan_status", { plan_id: planId });
  if (condition === "current" || isTerminal(status)) return status;
  const initialMarker = progressMarker(status);
  const deadline = started + timeoutMs;
  while (clock.now() < deadline) {
    if (signal?.aborted) throw new TaskCancelledError("plan_status wait was cancelled; physical plan remains active");
    await clock.sleep(Math.min(1_000, deadline - clock.now()));
    if (signal?.aborted) throw new TaskCancelledError("plan_status wait was cancelled; physical plan remains active");
    status = await bridge.call<RunPlanResult>("plan_status", { plan_id: planId });
    if (isTerminal(status) || (condition === "progress" && progressMarker(status) !== initialMarker)) return status;
  }
  return { ...status, wait: { condition, timed_out: true, waited_ms: Math.max(0, clock.now() - started) } };
}

/** tool names the MCP tool for a cancel's origin. */
export async function executeRunPlan(bridge: Bridge, input: RunPlanInput, signal?: AbortSignal, clock: TaskClock = realClock,
  tool = "run_plan"): Promise<RunPlanResult> {
  if (signal?.aborted) return { status: "cancelled", completed_steps: 0, outcomes: [],
    execution: { mode: "sequential_nontransactional", rollback: "none", committed_steps: [] } };
  const { plan_id } = await bridge.call<{ plan_id: number }>("queue_plan", input);
  // Time under a human hold is not charged and never cancels the plan: past
  // the return guard the plan stays queued and the caller waits on plan_status.
  const started = clock.now();
  const budget = holdAwareDeadline(clock, started + DEFAULT_TASK_TIMEOUT_MS);
  try {
    for (;;) {
      if (signal?.aborted) throw new TaskCancelledError("run_plan was cancelled");
      const status = await bridge.call<RunPlanResult>("plan_status", { plan_id });
      budget.sample(status.fifo?.human_control === true);
      if (isTerminal(status)) {
        if (status.observation) status.observation = normalizeObservation(status.observation);
        return status;
      }
      if (budget.remaining() <= 0) {
        // The call returns before the MCP timeout but never cancels: the mod
        // owns the plan's active budget (up to 12 s per step, so a large
        // build_layout may run well past 570 s). Report the
        // latest read, not the plan's sticky hold marker.
        const { human_control: _sticky, ...latest } = status;
        return { ...latest, ...(budget.holding ? { human_control: true } : {}),
          wait: { condition: "terminal", timed_out: true, waited_ms: Math.max(0, clock.now() - started) },
          summary: budget.holding
            ? `plan ${plan_id} is still ${status.status}: a human holds the body, so nothing was cancelled; it runs in order once they are idle, so wait with next_event`
            : budget.parked()
              ? `plan ${plan_id} is still ${status.status} at the call time limit after an earlier human hold delayed it; nothing was cancelled, so wait with next_event`
              : `plan ${plan_id} is still ${status.status} at the 570 s call limit; nothing was cancelled and the mod enforces the plan's own budget, so wait with next_event` };
      }
      await clock.sleep(Math.min(1_000, budget.remaining()));
    }
  } catch (error) {
    await bridge.call("cancel", { plan_id, origin: `${tool}/run_plan-abort` }).catch(() => {});
    try {
      const cancelled = await bridge.call<RunPlanResult>("plan_status", { plan_id });
      if (isTerminal(cancelled)) {
        if (cancelled.observation) cancelled.observation = normalizeObservation(cancelled.observation);
        return cancelled;
      }
    } catch (readbackError) {
      if (error instanceof TaskCancelledError || signal?.aborted) {
        return { plan_id, status: "cancelled", outcomes: [],
          observation_error: `${error instanceof Error ? error.message : String(error)}; terminal readback unavailable: ${readbackError instanceof Error ? readbackError.message : String(readbackError)}`,
          execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown",
            incomplete_step: { step: 1, status: "cancelled", effects: "unknown" } } };
      }
    }
    if (error instanceof TaskCancelledError || signal?.aborted) {
      return { plan_id, status: "cancelled", outcomes: [],
        observation_error: `${error instanceof Error ? error.message : String(error)}; cancellation did not yield terminal readback`,
        execution: { mode: "sequential_nontransactional", rollback: "none", effects_state: "unknown",
          incomplete_step: { step: 1, status: "cancelled", effects: "unknown" } } };
    }
    // The plan was queued and its status could not be read: it may still run.
    if (error instanceof RconError) throw outcomeUnknown(`${tool} (plan ${plan_id})`, error);
    throw error;
  }
}
