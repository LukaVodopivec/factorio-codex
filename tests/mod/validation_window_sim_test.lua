-- The parked component validator over the real graph, driven by a small
-- tick simulation of Factorio 2.0 burner mechanics: a burner mining drill
-- (150 kW, one ore per 240 ticks), a stone furnace (90 kW, iron plate in 192
-- ticks, no current recipe while idle), coal at 4 MJ, inserters that swing in
-- 76 ticks and top a burner's fuel up only below five items, and belts as
-- delay lines. Offline stub evidence only; no fixture is live autonomy proof.
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path
local failures = 0
local function check(ok, name) print((ok and "ok   " or "FAIL ") .. name); if not ok then failures = failures + 1 end end

local RAW = { working = 1, no_fuel = 2, no_ingredients = 3, waiting_for_source_items = 4,
  waiting_for_space_in_destination = 5, full_output = 6, normal = 7, no_power = 8 }
local COAL = 4000000
local DRILL_POWER, FURNACE_POWER = 2500, 1500
local MINE_TICKS, SMELT_TICKS, HALF_SWING, TOP_UP = 240, 192, 38, 5
_G.defines = { entity_status = RAW, inventory = { chest = 1, furnace_source = 2 }, flow_precision_index = { one_minute = 1 } }
local PLATE = { name = "iron-plate", energy = 3.2, ingredients = { { name = "iron-ore", type = "item", amount = 1 } },
  products = { { name = "iron-plate", type = "item", amount = 1 } } }
_G.prototypes = { item = { coal = { name = "coal", fuel_value = COAL, fuel_category = "chemical" } }, recipe = { ["iron-plate"] = PLATE } }
-- Every LuaObject is userdata in 2.0: a RecipeID read back from
-- previous_recipe.name is a LuaRecipePrototype, not a string or table.
local PLATE_PROTOTYPE = debug.setmetatable(io.tmpfile(), { __index = { name = "iron-plate", object_name = "LuaRecipePrototype" } })
_G.game = { tick = 1000 }
_G.storage = {}

local entities, frozen = {}, false
local force = {
  is_chunk_charted = function() return true end, is_chunk_visible = function() return true end,
  get_item_production_statistics = function() return { get_flow_count = function() return 0 end } end,
  get_fluid_production_statistics = function() return { get_flow_count = function() return 0 end } end,
}
local surface = {
  get_chunks = function() local done = false; return function() if not done then done = true; return { x = 0, y = 0 } end end end,
  find_entities_filtered = function(filter) return filter.type == "resource" and {} or entities end,
}
local body = { valid = true, name = "character", type = "character", position = { x = -20, y = -20 }, force = force, surface = surface }
package.loaded["scripts.companion"] = { get = function() return body end, require_companion = function() return body end }
for _, action in ipairs({ "walk", "mine", "pickup", "craft", "build_plan" }) do package.loaded["scripts.actions." .. action] = {} end
package.loaded["scripts.actions.build"] = { place = {}, rotate = {}, set_recipe = {} }
package.loaded["scripts.actions.transfer"] = { insert = {}, extract = {} }
local map = require("scripts.map_summary")
local tasks = require("scripts.tasks")

local function add(entity)
  entity.valid, entity.force = true, force
  entities[#entities + 1] = entity
  return entity
end
local function burner(entity, power, fuel, remaining)
  entity._power, entity._fuel = power, fuel
  entity.burner = { remaining_burning_fuel = remaining, currently_burning = { name = prototypes.item.coal, quality = { name = "normal" } } }
  entity.prototype = { burner_prototype = { fuel_categories = { chemical = true } } }
  entity.get_fuel_inventory = function() return {
    get_contents = function() return entity._fuel > 0 and { { name = "coal", quality = "normal", count = entity._fuel } } or {} end,
    get_item_count = function() return entity._fuel end,
    can_insert = function() return entity._fuel < 50 end,
  } end
end
-- A burner takes the next fuel item only when its burning remainder is spent.
local function burn(entity)
  local state = entity.burner
  if state.remaining_burning_fuel <= 0 and entity._fuel > 0 then
    entity._fuel, state.remaining_burning_fuel = entity._fuel - 1, state.remaining_burning_fuel + COAL
  end
  if state.remaining_burning_fuel <= 0 then return false end
  state.remaining_burning_fuel = math.max(0, state.remaining_burning_fuel - entity._power)
  return true
end
local function stock_total(chest)
  local total = 0
  for _, count in pairs(chest._stock) do total = total + count end
  return total
end
local function accepts(target, item)
  if target._line then return #target._line.items < target._line.capacity end
  if target.type == "container" then return stock_total(target) < target._capacity end
  if item == "coal" and target.burner then return target._fuel < TOP_UP end
  return target.type == "furnace" and item == "iron-ore" and target._source < 5
end
local function deliver(target, item)
  if target._line then target._line.items[#target._line.items + 1] = { name = item, arrival = game.tick + target._line.delay }
  elseif target.type == "container" then target._stock[item] = (target._stock[item] or 0) + 1
  elseif item == "coal" then target._fuel = target._fuel + 1
  else target._source = target._source + 1 end
end
local function can_ever(target, item)
  if target._line or target.type == "container" then return true end
  return item == "coal" and target.burner ~= nil or target.type == "furnace" and item == "iron-ore"
end
local function take(source, wanted)
  if source._line then
    local first = source._line.items[1]
    if first and first.arrival <= game.tick and wanted(first.name) then table.remove(source._line.items, 1); return first.name end
  elseif source.type == "container" then
    local names = {}
    for name, count in pairs(source._stock) do if count > 0 then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
      if wanted(name) then source._stock[name] = source._stock[name] - 1; return name end
    end
  elseif source.type == "furnace" and source._result > 0 and wanted("iron-plate") then
    source._result = source._result - 1
    return "iron-plate"
  end
end

local function chest(x, y, capacity)
  local entity = add({ name = "wooden-chest", type = "container", position = { x = x, y = y }, status = RAW.normal,
    _stock = {}, _capacity = capacity or 1600 })
  entity.get_inventory = function() return {
    get_item_count = function(name) return entity._stock[name] or 0 end,
    can_insert = function() return stock_total(entity) < entity._capacity end,
  } end
  return entity
end
-- A belt run as two tiles sharing one delay line; items enter at the head
-- and can be picked up at the tail once they have travelled.
local function belt_line(x, y, delay, capacity)
  local line = { items = {}, delay = delay, capacity = capacity }
  local head = add({ name = "transport-belt", type = "transport-belt", position = { x = x, y = y }, status = RAW.working, _line = line })
  local tail = add({ name = "transport-belt", type = "transport-belt", position = { x = x + 1, y = y }, status = RAW.working, _line = line })
  head.belt_neighbours, tail.belt_neighbours = { inputs = {}, outputs = { tail } }, { inputs = { head }, outputs = {} }
  return head, tail
end
local function drill(x, y, ore, drop, fuel, remaining)
  local entity = add({ name = "burner-mining-drill", type = "mining-drill", position = { x = x, y = y }, status = RAW.working,
    mining_progress = 0, drop_target = drop, _mined = 0 })
  entity.mining_target = { valid = true, name = ore, type = "resource", position = { x = x + 0.5, y = y + 40 }, amount = 10000,
    prototype = { mineable_properties = { mining_time = 1, products = { { name = ore, type = "item" } } } } }
  burner(entity, DRILL_POWER, fuel, remaining)
  entity.prototype.mining_speed = 60 / MINE_TICKS
  entity._step = function()
    if entity._held then
      if not accepts(entity.drop_target, entity._held) then entity.status = RAW.full_output; return end
      deliver(entity.drop_target, entity._held)
      entity._held = nil
    end
    if not burn(entity) then entity.status = RAW.no_fuel; return end
    entity.status, entity._mined = RAW.working, entity._mined + 1
    if entity._mined == MINE_TICKS then
      entity._mined, entity.mining_target.amount = 0, entity.mining_target.amount - 1
      if accepts(entity.drop_target, ore) then deliver(entity.drop_target, ore) else entity._held = ore end
    end
    entity.mining_progress = entity._mined / MINE_TICKS
  end
  return entity
end
-- previous_recipe reads back in 2.0 as a recipe/quality pair whose name is a
-- LuaRecipePrototype userdata (default), or here also as a pair with a table
-- name ("table") or a bare name ("string"); get_recipe() is nil whenever the
-- furnace is idle.
local function furnace(x, y, fuel, remaining, previous_shape)
  local entity = add({ name = "stone-furnace", type = "furnace", position = { x = x, y = y }, status = RAW.no_ingredients,
    products_finished = 0, crafting_speed = 1, _source = 0, _result = 0 })
  burner(entity, FURNACE_POWER, fuel, remaining)
  entity.get_recipe = function() return (entity._smelt or entity._source > 0) and PLATE or nil end
  entity.get_inventory = function(index)
    assert(index == defines.inventory.furnace_source)
    return { get_item_count = function(name) return name == "iron-ore" and entity._source or 0 end }
  end
  entity._step = function()
    if not entity._smelt and entity._source > 0 and entity._result < 100 then
      entity._source, entity._smelt = entity._source - 1, 0
      entity.previous_recipe = previous_shape == "string" and "iron-plate"
        or { name = previous_shape == "table" and PLATE or PLATE_PROTOTYPE, quality = { name = "normal" } }
    end
    if not entity._smelt then entity.status = RAW.no_ingredients; return end
    if not burn(entity) then entity.status = RAW.no_fuel; return end
    entity.status, entity._smelt = RAW.working, entity._smelt + 1
    if entity._smelt == SMELT_TICKS then
      entity._smelt, entity._result, entity.products_finished = nil, entity._result + 1, entity.products_finished + 1
    end
  end
  return entity
end
-- An inserter carries one item a half swing each way. An eager one waits at
-- the drop holding fuel; a lazy one fetches only once the drop wants it.
-- dead_at stops it as out of its own fuel (or dead_status, such as an
-- unpowered electric inserter) from that window tick on.
local function inserter(x, y, pickup, drop, options)
  options = options or {}
  local entity = add({ name = "burner-inserter", type = "inserter", position = { x = x, y = y },
    status = RAW.waiting_for_source_items, pickup_target = pickup, drop_target = drop, _timer = 0,
    _hand = options.hand, _phase = options.hand and "to_drop" or nil })
  if options.hand then entity._timer = options.delay or HALF_SWING end
  entity.held_stack = { valid_for_read = false }
  entity._step = function(elapsed)
    if options.dead_at and elapsed and elapsed >= options.dead_at then entity.status = options.dead_status or RAW.no_fuel; return end
    if entity._timer > 0 then
      entity._timer, entity.status = entity._timer - 1, RAW.working
    elseif entity._hand then
      if accepts(drop, entity._hand) then
        deliver(drop, entity._hand)
        entity._hand, entity._timer, entity.status = nil, HALF_SWING, RAW.working
      else entity.status = RAW.waiting_for_space_in_destination end
    else
      local item = take(pickup, function(name) return can_ever(drop, name) and (not options.lazy or accepts(drop, name)) end)
      if item then entity._hand, entity._timer, entity.status = item, HALF_SWING, RAW.working
      else entity.status = RAW.waiting_for_source_items end
    end
    entity.held_stack = entity._hand and { valid_for_read = true, name = entity._hand, quality = { name = "normal" }, count = 1 }
      or { valid_for_read = false }
  end
  return entity
end

local function step_world(elapsed)
  if frozen then return end
  for _, entity in ipairs(entities) do if entity._step then entity._step(elapsed) end end
end
local function warm(ticks) for _ = 1, ticks do game.tick = game.tick + 1; step_world() end end
local function reset() entities, frozen, storage = {}, false, {} end
local function validate(position, duration, hook)
  storage = { tasks = { next_id = 1, records = {}, queue = {}, active = nil } }
  map.map_summary({}) -- open complete run-local transfer history
  local start = game.tick
  local queued = tasks.queue_plan({ observation_detail = "none", steps = { { action = "validate_factory_component",
    source_tick = start, positions = { position }, duration_seconds = duration } } })
  local result
  for _ = 1, duration * 60 + 30 do
    game.tick = game.tick + 1
    if hook then hook(game.tick - start) end
    step_world(game.tick - start)
    tasks.on_tick()
    result = tasks.plan_status({ plan_id = queued.plan_id })
    if result.status == "completed" or result.status == "failed" then break end
  end
  return result, result.outcomes and result.outcomes[1].result or {}
end
local function rows_at(outcome, entity, field)
  local found = {}
  for _, row in ipairs(outcome[field or "blockers"] or {}) do
    if row.position and row.position.x == entity.position.x and row.position.y == entity.position.y then found[row.reason] = row end
  end
  return found
end
local function reasons(outcome)
  local names = {}
  for _, row in ipairs(outcome.blockers or {}) do names[#names + 1] = row.reason end
  return table.concat(names, ",")
end
local function component_state()
  return map.map_summary({}).factory.material_flow.components[1].state
end

-- A furnace fed straight by a burner iron drill (one ore per 240 ticks, a
-- 192-tick smelt) sits idle with no current recipe about 20% of the time.
-- Its previous_recipe keeps its output identity, so the window passes.
reset()
local plates = chest(12, 1)
local smelter = furnace(6, 1, 5, COAL)
local iron = drill(2, 1, "iron-ore", smelter, 5, COAL)
inserter(9, 1, smelter, plates)
local fuel_chest = chest(4, 6)
fuel_chest._stock.coal = 20
local coal = drill(1, 6, "coal", fuel_chest, 5, COAL)
inserter(2, 4, fuel_chest, iron); inserter(6, 4, fuel_chest, smelter); inserter(2, 7, fuel_chest, coal)
warm(600)
local idle_samples = 0
local gap_plan, gap = validate(plates.position, 120, function()
  if smelter.get_recipe() == nil then idle_samples = idle_samples + 1 end
end)
check(idle_samples > 600 and gap_plan.status == "completed" and gap.proven
  and not reasons(gap):match("output_identity_unproven") and not reasons(gap):match("topology_changed"),
  "an idle furnace between ore arrivals keeps its previous recipe identity through a 120 s window")
check(type(smelter.previous_recipe.name) == "userdata", "the fixture furnace reports its previous recipe as a userdata prototype")
local string_furnace = furnace(20, 1, 5, COAL, "string")
string_furnace._source = 1; string_furnace._step(); string_furnace._smelt = nil; string_furnace._source = 0
local table_furnace = furnace(22, 1, 5, COAL, "table")
table_furnace._source = 1; table_furnace._step(); table_furnace._smelt = nil; table_furnace._source = 0
local fresh_furnace = furnace(24, 1, 5, COAL)
local recipes = {}
for _, node in ipairs(map.map_summary({}).factory.material_flow.nodes) do
  if node.type == "furnace" then recipes[node.position.x] = node.recipe or "none" end
end
check(string_furnace.get_recipe() == nil and recipes[20] == "iron-plate" and recipes[22] == "iron-plate"
  and recipes[24] == "none" and recipes[6] == "iron-plate",
  "userdata, table and bare-name previous_recipe shapes resolve, and a furnace that never crafted has no identity")

-- A burner coal drill drops into a chest and a burner inserter returns coal
-- from that chest to the drill's fuel slot: the chest is the loop's terminal
-- buffer, so the loop is ready, validates and later shows blocked output.
local function self_fed(fuel, remaining, options)
  reset()
  local box = chest(5, 1)
  local source = drill(1, 1, "coal", box, fuel, remaining)
  local back = inserter(3, 3, box, source, options)
  return box, source, back
end
local box, source = self_fed(5, COAL)
warm(300)
local loop_plan, loop = validate(box.position, 60)
local loop_state = component_state()
check(loop_plan.status == "completed" and loop.proven and loop.downstream_kind == "buffer"
  and loop.source_cycles_observed >= 3 and loop_state.autonomous_end_to_end,
  "a self-fuelling coal drill whose chest also feeds its fuel return is a ready, validated terminal buffer loop")
box._capacity = stock_total(box)
local full_state = component_state()
check(full_state.blocked_output and table.concat(full_state.autonomy_blockers, ","):match("blocked_output"),
  "the self-fuelling loop's full terminal chest is blocked output, not backpressure")

-- Seven starter coal: two draws in 60 s leave five, so no top-up is due yet.
-- With a lazy return holding nothing, that is inconclusive with a longer
-- window named, never a fuel-edge defect; rerunning for that window shows the
-- return working.
box, source = self_fed(7, COAL, { lazy = true })
warm(5)
local starter_plan, starter = validate(box.position, 60)
local pending = rows_at(starter, source).fuel_return_not_yet_exercised
check(starter_plan.status == "failed" and not starter.proven and pending and pending.class == "evidence"
  and pending.related_edge == nil and pending.fuel_items == 5 and pending.suggested_duration_seconds >= 60
  and pending.suggested_duration_seconds <= 300 and not reasons(starter):match("fuel_replenishment_not_observed")
  and not reasons(starter):match("transport_starved"),
  "starter fuel above the top-up stock reports an unexercised fuel return with a suggested duration")
local rerun_plan, rerun = validate(box.position, pending and pending.suggested_duration_seconds or 60)
check(rerun_plan.status == "completed" and rerun.proven,
  "the suggested duration from the current stock observes the top-up and proves the loop")
-- An eager return already holding coal from the loop's chest and waiting at
-- the working drill is the supplied return, loaded: no window must wait for
-- the starter stock to fall below the top-up limit.
local loaded_box, loaded_source, loaded_return = self_fed(7, COAL)
warm(5)
local loaded_plan, loaded = validate(loaded_box.position, 60)
check(loaded_plan.status == "completed" and loaded.proven and loaded_source._fuel == 5 and loaded_return._hand == "coal",
  "a loaded return waiting at a working burner above its top-up stock counts as exercised")

-- A lazy return inserter answers a draw a swing later. A draw 30 ticks before
-- the end is still in flight: never a starved-return defect.
box, source = self_fed(5, DRILL_POWER * 3570, { lazy = true })
local late_plan, late = validate(box.position, 60)
check(late_plan.status == "failed" and not reasons(late):match("fuel_replenishment_not_observed")
  and rows_at(late, source).fuel_return_not_yet_exercised ~= nil and source._fuel == 4,
  "an unrefilled draw younger than the grace at window end is not a missing refill")
box, source = self_fed(5, DRILL_POWER * 1970, { lazy = true })
local again_plan, again = validate(box.position, 60)
check(again_plan.status == "completed" and again.proven and source._fuel == 4,
  "an earlier answered draw proves the return while the last draw is still in flight")

-- Demand-limited fuel source: the coal drill feeds only the iron drill's and
-- its own fuel slots over a short full belt, so it cycles at their burn rate
-- (here two coal in 45 s); one cycle suffices while its consumer cycles.
reset()
local ore_box = chest(10, 1)
local ore_drill = drill(6, 1, "iron-ore", ore_box, 5, COAL)
local coal_head, coal_tail = belt_line(1, 4, 60, 6)
local fuel_drill = drill(1, 1, "coal", coal_head, 5, COAL)
inserter(6, 3, coal_tail, ore_drill); inserter(2, 3, coal_tail, fuel_drill)
warm(3000)
local demand_plan, demand = validate(ore_box.position, 45, function(elapsed)
  if elapsed == 1 then
    fuel_drill.burner.remaining_burning_fuel, ore_drill.burner.remaining_burning_fuel = DRILL_POWER * 100, DRILL_POWER * 1200
  end
end)
check(demand_plan.status == "completed" and demand.proven and demand.source_cycles_observed >= 3
  and demand.fuel_source_cycles_observed >= 1 and demand.fuel_source_cycles_observed < 3
  and component_state().autonomous_end_to_end,
  "a demand-limited fuel-only coal source passes on one cycle while the drill it fuels cycles")

-- Two producers: an iron drill feeds a furnace over a belt; a coal drill
-- fills a fuel chest. The coal drill keeps cycling, so the component-wide
-- stall never fires; each stopped branch must still fail at window end.
local function two_producers(furnace_fuel_dead, feed_dead_at)
  reset()
  local out = chest(14, 1)
  local ore_head, ore_tail = belt_line(3, 1, 30, 8)
  local ore = drill(1, 1, "iron-ore", ore_head, 5, COAL)
  local smelt = furnace(8, 1, 5, COAL)
  inserter(6, 1, ore_tail, smelt, { dead_at = feed_dead_at })
  inserter(11, 1, smelt, out)
  local coal_box = chest(4, 8)
  coal_box._stock.coal = 20
  local coal_drill = drill(1, 8, "coal", coal_box, 5, COAL)
  inserter(2, 4, coal_box, ore); inserter(8, 4, coal_box, smelt, { dead_at = furnace_fuel_dead and 0 or nil })
  inserter(3, 9, coal_box, coal_drill)
  warm(600)
  ore.burner.remaining_burning_fuel, coal_drill.burner.remaining_burning_fuel = DRILL_POWER * 300, DRILL_POWER * 300
  return out, smelt, ore
end
local out, smelt = two_producers(true, nil)
smelt._fuel, smelt.burner.remaining_burning_fuel = 0, FURNACE_POWER * 1250
local dry_plan, dry = validate(out.position, 60)
local dry_rows = rows_at(dry, smelt)
check(dry_plan.status == "failed" and not dry.proven and dry_rows["persistent_nonproductive_status:no_fuel"]
  and dry_rows["persistent_nonproductive_status:no_fuel"].class == "structural" and dry_rows.fuel_replenishment_not_observed
  and rows_at(dry, out).path_stalled_before_end and dry.source_cycles_observed >= 3,
  "a furnace out of fuel after 25 s fails at window end although another drill keeps cycling")
out, smelt = two_producers(false, 1500)
smelt.burner.remaining_burning_fuel = FURNACE_POWER * 100
local starved_plan, starved = validate(out.position, 60)
check(starved_plan.status == "failed" and not starved.proven and rows_at(starved, smelt).path_stalled_before_end
  and rows_at(starved, out).path_stalled_before_end,
  "a furnace starved by its feed inserter stopping after 25 s fails at window end")

-- Surplus takeoff upstream of the fuel takeoff: the return never gets coal.
-- One coal burning and an empty fuel slot mine six ore that reach the chest
-- over a 16 s belt less than the stall interval before the end.
local function surplus_loop(return_options)
  reset()
  local sink = chest(6, 6)
  local head, tail = belt_line(2, 4, 960, 40)
  local miner = drill(1, 1, "coal", head, 0, COAL)
  inserter(4, 5, tail, sink)
  inserter(2, 5, tail, miner, return_options)
  return sink, miner
end
local sink, miner = surplus_loop()
local empty_plan, empty = validate(sink.position, 60)
local empty_refill = rows_at(empty, miner).fuel_replenishment_not_observed
check(empty_plan.status == "failed" and not empty.proven and empty_refill and empty_refill.related_edge.kind == "fuel_input"
  and empty_refill.fuel_items == 0 and empty.downstream_acceptance_samples >= 3 and empty.source_cycles_observed >= 3,
  "a drill burning its last coal with an empty fuel slot is a missing refill although its item count never fell")
sink, miner = surplus_loop({ hand = "coal", delay = 60 })
local once_plan, once = validate(sink.position, 60)
check(once_plan.status == "failed" and not once.proven and rows_at(once, miner).fuel_replenishment_not_observed,
  "one early refill cannot carry a fuel return that then starves")

-- A window shorter than one burn period sees consumption but no draw.
box, source = self_fed(5, COAL, { lazy = true })
local short_plan, short = validate(box.position, 16)
local short_row = rows_at(short, source).fuel_return_not_yet_exercised
check(short_plan.status == "failed" and not short.proven and short.source_cycles_observed >= 3
  and short_row and short_row.suggested_duration_seconds > 16 and not reasons(short):match("transport_starved"),
  "starter fuel alone cannot prove a fuel loop inside a window shorter than one burn period")

-- A stall with every producer sampled working (frozen world) stays recorded
-- although progress resumes before the end.
box, source = self_fed(5, COAL)
warm(300)
local latch_plan, latch = validate(box.position, 60, function(elapsed) frozen = elapsed >= 600 and elapsed < 1900 end)
check(latch_plan.status == "failed" and not latch.proven and reasons(latch):match("progress_stalled"),
  "a stall seen once is latched even when trickle progress resumes before the end")

-- Layout (b): an iron drill drops into a furnace whose output fills a chest; a
-- coal drill fills a belt whose fuel inserters serve the iron drill, the
-- furnace and, last on the belt, the coal drill itself. With little starter
-- fuel the coal drill's own slot fills one coal per mining period while it
-- still burns, so its last draw can be older than the swing grace at the end
-- of the window although every refill so far kept it gaining fuel.
local function shared_fuel_belt(fuel, remaining, return_options, delay, coal_fuel)
  reset()
  local out_box = chest(14, 1)
  local smelt = furnace(8, 1, fuel, remaining)
  local ore = drill(4, 1, "iron-ore", smelt, fuel, remaining)
  inserter(11, 1, smelt, out_box)
  local head, tail = belt_line(1, 6, delay or 60, 8)
  local coal_drill = drill(1, 4, "coal", head, coal_fuel or fuel, remaining)
  inserter(4, 5, tail, ore); inserter(8, 5, tail, smelt); inserter(2, 5, tail, coal_drill, return_options)
  return out_box, coal_drill
end
local supplied_box, supplied_coal = shared_fuel_belt(2, COAL / 10)
warm(600)
local supplied_plan, supplied = validate(supplied_box.position, 60)
check(supplied_plan.status == "completed" and supplied.proven and supplied_coal._fuel < TOP_UP,
  "a supply-limited return refilling a still-demanding burner once per mining period is not starved")
-- The same return stopping after it has shown its supply interval is starved.
supplied_box, supplied_coal = shared_fuel_belt(2, COAL / 10, { dead_at = 1200 })
warm(600)
supplied_plan, supplied = validate(supplied_box.position, 60)
local cut = rows_at(supplied, supplied_coal).fuel_replenishment_not_observed
check(supplied_plan.status == "failed" and not supplied.proven and cut and cut.related_edge.kind == "fuel_input",
  "a supply-limited return that stops for longer than its observed supply interval is starved")

-- Layout (f): a fuel-only coal drill feeds the iron drill and itself over a
-- short belt. One starter coal and a tenth of a coal burning: the iron drill
-- demands fuel all window and the supply-limited return keeps answering.
local function fuel_only_belt(fuel, remaining, return_options)
  reset()
  local box_out = chest(10, 1)
  local ore = drill(6, 1, "iron-ore", box_out, fuel, remaining or COAL)
  local head, tail = belt_line(1, 4, 60, 6)
  local coal_drill = drill(1, 1, "coal", head, fuel, remaining or COAL)
  inserter(6, 3, tail, ore, return_options); inserter(2, 3, tail, coal_drill, return_options)
  return box_out, coal_drill
end
local thin_box = fuel_only_belt(1, COAL / 10)
local thin_plan, thin = validate(thin_box.position, 60)
check(thin_plan.status == "completed" and thin.proven,
  "a cold-started fuel-only belt whose refills arrive once per mining period is not starved")

-- Surplus starter fuel: the iron drill's draws are met from the full belt (or
-- it never falls below the top-up stock), so the output-blocked coal drill
-- mines nothing in a 60 s window. That is unexercised demand, not a defect.
for _, fuel in ipairs({ 8, 10 }) do
  local idle_box, idle_coal = fuel_only_belt(fuel)
  warm(3000)
  local idle_plan, idle = validate(idle_box.position, 60)
  local unasked = rows_at(idle, idle_coal).fuel_demand_not_yet_exercised
  check(idle_plan.status == "failed" and not idle.proven and unasked and unasked.class == "evidence"
    and unasked.suggested_duration_seconds >= 60 and unasked.suggested_duration_seconds <= 300
    and not reasons(idle):match("several_source_cycles_not_observed"),
    "a fuel-only source with " .. fuel .. " starter coal and no unmet demand reports evidence, not a throughput defect")
end
-- A demand-limited coal drill burning slowly from surplus starter fuel stays
-- above its top-up stock for many windows; its loaded return proves the loop.
local slow_box, slow_coal = fuel_only_belt(10)
warm(3000)
local slow_plan, slow = validate(slow_box.position, 300)
check(slow_plan.status == "completed" and slow.proven and slow_coal._fuel >= TOP_UP,
  "a demand-limited source above its top-up stock with a loaded waiting return proves in one window")

-- FP1: a coal drill's genuine return loop through terminal chest T, and an
-- intermediate fuel chest C holding starter coal for an iron drill and the
-- furnace it feeds, whose feed inserter never delivers: out of fuel, or
-- downstream of T's takeoff, which takes every coal first.
local function intermediate_fuel(feed_dead_at, feed_first)
  reset()
  local product_box = chest(14, 1)
  local smelt = furnace(8, 1, 3, COAL)
  local ore = drill(4, 1, "iron-ore", smelt, 3, COAL)
  inserter(11, 1, smelt, product_box)
  local head, tail = belt_line(1, 8, 60, 8)
  local coal_drill = drill(1, 10, "coal", head, 3, COAL)
  local terminal, fuel_box = chest(3, 10), chest(6, 6)
  fuel_box._stock.coal = 20
  local feed = feed_first and inserter(5, 7, tail, fuel_box, { dead_at = feed_dead_at }) or nil
  inserter(3, 9, tail, terminal); inserter(2, 11, terminal, coal_drill)
  feed = feed or inserter(5, 7, tail, fuel_box, { dead_at = feed_dead_at })
  inserter(4, 3, fuel_box, ore); inserter(8, 3, fuel_box, smelt)
  return product_box, fuel_box, feed
end
for _, feed_dead in ipairs({ true, false }) do
  local fp_box, fp_fuel = intermediate_fuel(feed_dead and 0 or nil)
  warm(600)
  local fp_plan, fp = validate(fp_box.position, 60)
  local draining = rows_at(fp, fp_fuel).intermediate_buffer_draining
  check(fp_plan.status == "failed" and not fp.proven and draining and draining.class == "throughput"
    and fp.products_finished_delta >= 3 and fp_fuel._stock.coal < 20,
    "an intermediate fuel chest draining starter coal with " .. (feed_dead and "a dead feed" or "a starved takeoff")
      .. " is not autonomous although output rose")
end

-- FP2: furnace ore from an intermediate chest O holding starter ore. A dead
-- feed from the ore belt (a terminal takeoff keeps the drill cycling) drains
-- O; a live feed slower than the furnace also lowers O, but with inflow.
local function intermediate_ore(feed_dead)
  reset()
  local product_box = chest(14, 1)
  local smelt = furnace(8, 1, 3, COAL)
  inserter(11, 1, smelt, product_box)
  local ore_head, ore_tail = belt_line(1, 14, 30, 8)
  local ore = drill(1, 12, "iron-ore", ore_head, 3, COAL)
  if feed_dead then inserter(3, 15, ore_tail, chest(3, 16)) end
  local ore_box = chest(8, 12)
  ore_box._stock["iron-ore"] = 40
  inserter(5, 15, ore_tail, ore_box, { dead_at = feed_dead and 0 or nil })
  inserter(8, 3, ore_box, smelt)
  local head, tail = belt_line(1, 8, 60, 8)
  local coal_drill = drill(1, 10, "coal", head, 3, COAL)
  inserter(2, 9, tail, ore); inserter(8, 9, tail, smelt); inserter(3, 9, tail, coal_drill)
  return product_box, ore_box
end
local ore_out, ore_buffer = intermediate_ore(true)
warm(600)
local fp2_plan, fp2 = validate(ore_out.position, 60)
check(fp2_plan.status == "failed" and not fp2.proven and rows_at(fp2, ore_buffer).intermediate_buffer_draining
  and fp2.products_finished_delta >= 3,
  "an intermediate ore chest draining starter ore behind a dead feed is not autonomous although output rose")
ore_out, ore_buffer = intermediate_ore(false)
warm(600)
fp2_plan, fp2 = validate(ore_out.position, 60)
check(fp2_plan.status == "completed" and fp2.proven and ore_buffer._stock["iron-ore"] < 40,
  "an intermediate chest that falls while its live feed keeps adding is a fed stage")

-- Layout (b) with lazy returns that fetch only below the top-up stock, and
-- optionally (b2) an overflow chest taking the coal belt's surplus after the
-- fuel takeoffs. One coal drill (one coal per 240 ticks) hands coal out in
-- belt order, so a draw can wait for every other burner on that drill first.
local function lazy_fuel_belt(fuel, remaining, overflow, lazy)
  reset()
  local out_box = chest(14, 1)
  local smelt = furnace(8, 1, fuel, remaining)
  local ore = drill(4, 1, "iron-ore", smelt, fuel, remaining)
  inserter(11, 1, smelt, out_box)
  local head, tail = belt_line(1, 6, 60, 8)
  local coal_drill = drill(1, 4, "coal", head, fuel, remaining)
  local options = lazy ~= false and { lazy = true } or nil
  inserter(4, 5, tail, ore, options); inserter(8, 5, tail, smelt, options); inserter(2, 5, tail, coal_drill, options)
  local spill = overflow and chest(6, 8) or nil
  if spill then inserter(6, 7, tail, spill) end
  return out_box, coal_drill, smelt, spill
end
local shared_box, shared_coal = lazy_fuel_belt(5, COAL, true)
warm(317)
local shared_plan, shared = validate(shared_box.position, 60)
check(shared_plan.status == "completed" and shared.proven and not reasons(shared):match("fuel_replenishment_not_observed"),
  "a draw waiting behind two other burners on one supply-limited coal drill is not a starved return")
-- Surplus starter coal elsewhere; the furnace's first draw below the top-up
-- stock comes about 250 ticks before the end, longer than a swing but less
-- than one supply period per burner sharing the coal drill.
local late_box, late_coal, late_smelt = lazy_fuel_belt(10, COAL, true)
warm(317)
local first_plan, first = validate(late_box.position, 60, function(elapsed)
  if elapsed == 1 then late_smelt.burner.remaining_burning_fuel, late_smelt._fuel = FURNACE_POWER * 2700, 5 end
end)
local in_flight = rows_at(first, late_smelt).fuel_return_not_yet_exercised
check(first_plan.status == "failed" and late_smelt._fuel == 4 and in_flight and in_flight.class == "evidence"
  and not reasons(first):match("fuel_replenishment_not_observed") and not reasons(first):match("transport_starved"),
  "a first draw younger than one shared supply period is in flight evidence, not a starved return")

-- (b2) with eager returns and one to three starter coal: the returns spend
-- the window filling the burners, so the overflow chest gets no coal yet.
local spill_box, spill_coal, spill_smelt, spill = lazy_fuel_belt(2, COAL, true, false)
warm(317)
local spill_plan, spill_result = validate(spill_box.position, 60)
local converging = rows_at(spill_result, spill).surplus_fuel_endpoint_not_yet_reached
check(spill_plan.status == "failed" and converging and converging.class == "evidence"
  and converging.suggested_duration_seconds > 60 and converging.suggested_duration_seconds <= 300
  and not reasons(spill_result):match("bounded_downstream_acceptance_not_observed")
  and not reasons(spill_result):match("transport_starved"),
  "a surplus fuel endpoint behind burners still filling up is evidence with a longer window, not a throughput defect")
local long_plan, long = validate(spill_box.position, converging and converging.suggested_duration_seconds or 300)
check(long_plan.status == "completed" and long.proven,
  "the suggested window sees the surplus reach the overflow chest")

-- A starter ore packet in the furnace hides a feed inserter on an unpowered
-- pole island: the drill keeps filling its belt and the furnace keeps
-- crafting from the packet.
local function packet_furnace(feed_options)
  reset()
  local product_box = chest(14, 1)
  local smelt = furnace(8, 1, 5, COAL)
  smelt._source = 30
  inserter(11, 1, smelt, product_box)
  local ore_head, ore_tail = belt_line(2, 3, 30, 60)
  local ore = drill(1, 1, "iron-ore", ore_head, 5, COAL)
  local feed = inserter(6, 2, ore_tail, smelt, feed_options)
  local head, tail = belt_line(1, 8, 60, 8)
  local coal_drill = drill(1, 10, "coal", head, 5, COAL)
  inserter(2, 6, tail, ore); inserter(8, 6, tail, smelt); inserter(3, 9, tail, coal_drill)
  local spill_chest = chest(5, 10)
  inserter(5, 9, tail, spill_chest)
  return product_box, smelt, feed
end
local packet_box, packet_smelt, packet_feed = packet_furnace({ dead_at = 0, dead_status = RAW.no_power })
local packet_plan, packet = validate(packet_box.position, 60)
check(packet_plan.status == "failed" and not packet.proven and rows_at(packet, packet_smelt).processor_input_draining
  and rows_at(packet, packet_feed)["persistent_nonproductive_status:no_power"] and packet.products_finished_delta >= 3,
  "a starter ore packet in the furnace cannot carry a window past an unpowered feed inserter")

-- S7: two drills feed one furnace; drill A's feed inserter loses power at
-- 10 s, so A fills its short belt and stops while B keeps the furnace busy.
-- S3: A drops into an intermediate chest whose takeoff is dead all window.
local function two_feeds(dead_at, via_chest, a_capacity)
  reset()
  local product_box = chest(14, 1)
  local smelt = furnace(8, 1, 5, COAL)
  inserter(11, 1, smelt, product_box)
  local a_head, a_tail = belt_line(2, -2, 30, a_capacity or 8)
  local a = drill(1, -4, "iron-ore", a_head, 5, COAL)
  local stage = via_chest and chest(4, -2) or nil
  if stage then a.drop_target = stage end
  local a_feed = inserter(6, -1, stage or a_tail, smelt, { dead_at = dead_at, dead_status = RAW.no_power })
  local b_head, b_tail = belt_line(2, 3, 30, 8)
  local b = drill(1, 1, "iron-ore", b_head, 5, COAL)
  inserter(6, 2, b_tail, smelt)
  local coal_box = chest(4, 8)
  coal_box._stock.coal = 20
  local coal_drill = drill(1, 8, "coal", coal_box, 5, COAL)
  inserter(2, -6, coal_box, a); inserter(2, 0, coal_box, b); inserter(8, 4, coal_box, smelt); inserter(3, 9, coal_box, coal_drill)
  return product_box, a, a_feed, stage
end
local s7_box, s7_a, s7_feed = two_feeds(600)
warm(600)
local s7_plan, s7 = validate(s7_box.position, 60)
check(s7_plan.status == "failed" and not s7.proven and s7.source_cycles_observed >= 3 and rows_at(s7, s7_a).path_stalled_before_end
  and rows_at(s7, s7_feed)["persistent_nonproductive_status:no_power"],
  "a drill whose dead feed inserter left it idle for the last 18 s fails at that drill and at the dead feed")
local s3_box, s3_a, s3_feed, s3_stage = two_feeds(0, true)
warm(600)
local s3_plan, s3 = validate(s3_box.position, 60)
check(s3_plan.status == "failed" and not s3.proven and rows_at(s3, s3_feed)["persistent_nonproductive_status:no_power"]
  and rows_at(s3, s3_stage).intermediate_buffer_outflow_not_observed,
  "an intermediate chest that only fills behind a dead takeoff is not a fed stage")

-- A feed inserter stopping at 40 s of a 60 s window leaves the furnace and
-- chest idle for the last 17 s, under the stall interval but over four of
-- their own periods.
out, smelt = two_producers(false, 2400)
local tail_plan, tail_result = validate(out.position, 60)
check(tail_plan.status == "failed" and not tail_result.proven and rows_at(tail_result, smelt).path_stalled_before_end
  and rows_at(tail_result, out).path_stalled_before_end,
  "a path idle for four of its own periods at the end fails although under the stall interval")

-- One coal drill (about 1.0 MW of coal) fuels n burner iron drills and
-- itself over one belt, its own return last. Every burner starts with nine
-- coal and every return holds one, so no draw is due inside the window.
local function coal_ring(n)
  reset()
  local head, tail = belt_line(1, 0, 60, 20)
  local coal_drill = drill(1, -3, "coal", head, 9, COAL)
  for index = 1, n do
    local x = 4 * index
    local ore = drill(x, 4, "iron-ore", chest(x, 8), 9, COAL)
    inserter(x, 2, tail, ore, { hand = "coal" })
  end
  inserter(2, -1, tail, coal_drill, { hand = "coal" })
  return coal_drill
end
for _, case in ipairs({ { n = 7, deficit = true }, { n = 5, deficit = false } }) do
  local ring_coal = coal_ring(case.n)
  warm(5)
  local ring_plan, ring = validate({ x = 4, y = 8 }, 60)
  local deficit = rows_at(ring, ring_coal).fuel_supply_deficit
  if case.deficit then
    check(ring_plan.status == "failed" and not ring.proven and deficit and deficit.class == "throughput"
      and deficit.fuel_demand_watts > deficit.fuel_supply_watts,
      "seven iron drills and the coal drill burn more than one coal drill mines: a fuel supply deficit")
  else
    check(ring_plan.status == "completed" and ring.proven and not deficit,
      "five iron drills and the coal drill stay within one coal drill's output")
  end
end

-- Dead streak at window end: a feed, takeoff or output inserter dying at
-- 7 s (or for the last 14 s) hides behind starter stock in a chest, a long
-- belt or a preloaded output belt, and one early inflow or outflow sample.
-- FP3: the fuel chest's feed runs out of fuel at 7 s, after one inflow.
do
  local fp3_box, _, fp3_feed = intermediate_fuel(420, true)
  warm(600)
  local fp3_plan, fp3 = validate(fp3_box.position, 60)
  local fp3_dead = rows_at(fp3, fp3_feed)["persistent_nonproductive_status:no_fuel"]
  check(fp3_plan.status == "failed" and not fp3.proven and fp3_dead and fp3_dead.class == "structural",
    "a fuel chest feed out of fuel from 7 s fails at the feed although one early inflow and starter coal carried the burners")
  -- FP1b: branch A's feed loses power at 7 s; A keeps mining onto a long belt.
  local fp1b_box, _, fp1b_feed = two_feeds(420, false, 40)
  warm(600)
  local fp1b_plan, fp1b = validate(fp1b_box.position, 60)
  check(fp1b_plan.status == "failed" and not fp1b.proven and rows_at(fp1b, fp1b_feed)["persistent_nonproductive_status:no_power"],
    "a branch feed unpowered from 7 s fails although its drill keeps mining onto a long belt")
  -- FP1d: the stage chest starts with ore, so one outflow is sampled before
  -- its takeoff loses power; afterwards it only fills.
  local fp1d_box, _, fp1d_feed, fp1d_stage = two_feeds(420, true)
  fp1d_stage._stock["iron-ore"] = 10
  warm(600)
  local fp1d_plan, fp1d = validate(fp1d_box.position, 60)
  check(fp1d_plan.status == "failed" and not fp1d.proven and rows_at(fp1d, fp1d_feed)["persistent_nonproductive_status:no_power"]
    and rows_at(fp1d, fp1d_stage).intermediate_buffer_outflow_not_observed,
    "a stage chest whose last outflow is older than the recency limit has a dead outlet despite one early outflow")
  -- A furnace drops plates through I2 onto an output belt preloaded with 70
  -- plates and I3 empties it into a chest. FP2b: I2 loses power at 7 s.
  -- FP4: the same layout's I3 loses power for the last 14 s.
  local function plate_belt(i2_dead_at, i3_dead_at)
    reset()
    local product_box = chest(16, 1)
    local ore_head, ore_tail = belt_line(1, 4, 30, 8)
    local ore = drill(1, 1, "iron-ore", ore_head, 5, COAL)
    local smelt = furnace(8, 1, 5, COAL)
    inserter(5, 4, ore_tail, smelt)
    local out_head, out_tail = belt_line(10, 1, 30, 80)
    for _ = 1, 70 do out_head._line.items[#out_head._line.items + 1] = { name = "iron-plate", arrival = 0 } end
    local i2 = inserter(9, 1, smelt, out_head, { dead_at = i2_dead_at, dead_status = RAW.no_power })
    local i3 = inserter(13, 1, out_tail, product_box, { dead_at = i3_dead_at, dead_status = RAW.no_power })
    local coal_box = chest(4, 8)
    coal_box._stock.coal = 20
    local coal_drill = drill(1, 8, "coal", coal_box, 5, COAL)
    inserter(1, 3, coal_box, ore); inserter(2, 3, coal_box, smelt); inserter(3, 9, coal_box, coal_drill)
    warm(600)
    return product_box, i2, i3
  end
  local fp2b_box, fp2b_i2 = plate_belt(420)
  local fp2b_plan, fp2b = validate(fp2b_box.position, 60)
  check(fp2b_plan.status == "failed" and not fp2b.proven and rows_at(fp2b, fp2b_i2)["persistent_nonproductive_status:no_power"],
    "a furnace output inserter unpowered from 7 s fails although a preloaded output belt keeps the chest filling")
  local fp4_box, _, fp4_i3 = plate_belt(nil, 2760)
  local fp4_plan, fp4 = validate(fp4_box.position, 60)
  check(fp4_plan.status == "failed" and not fp4.proven and rows_at(fp4, fp4_i3)["persistent_nonproductive_status:no_power"],
    "an inserter unpowered for the last 14 s of the window fails it")
  -- A burner out of fuel for the last 5 s, within one supply period plus the
  -- swing grace of its owed refill, is waiting for that refill: not dead.
  local wait_box, wait_source = self_fed(5, COAL, { lazy = true })
  warm(300)
  local _, waiting = validate(wait_box.position, 60, function(elapsed)
    if elapsed == 3300 then wait_source._fuel, wait_source.burner.remaining_burning_fuel, wait_box._stock.coal = 0, 0, 0 end
  end)
  local wait_rows = rows_at(waiting, wait_source)
  check(wait_source.status == RAW.no_fuel and not wait_rows["persistent_nonproductive_status:no_fuel"]
    and not wait_rows.fuel_replenishment_not_observed,
    "a burner out of fuel no longer than its refill bound at window end is waiting for a refill, not dead")
  local live_box = plate_belt()
  local live_plan, live = validate(live_box.position, 60)
  check(live_plan.status == "completed" and live.proven, "the same preloaded output belt with every inserter powered proves")
end

-- A furnace that has not smelted yet has no recipe. With ore arriving from
-- its drill, validation started at once is refused as not ready, never a
-- structural identity defect; a furnace with no material feed keeps it.
do
  reset()
  local fresh_box = chest(12, 1)
  local fresh_smelt = furnace(6, 1, 5, COAL)
  local fresh_iron = drill(2, 1, "iron-ore", fresh_smelt, 5, COAL)
  inserter(9, 1, fresh_smelt, fresh_box)
  local fresh_fuel = chest(4, 6)
  fresh_fuel._stock.coal = 20
  local fresh_coal = drill(1, 6, "coal", fresh_fuel, 5, COAL)
  inserter(2, 4, fresh_fuel, fresh_iron); inserter(6, 4, fresh_fuel, fresh_smelt); inserter(2, 7, fresh_fuel, fresh_coal)
  local fresh_plan, fresh = validate(fresh_box.position, 60)
  local not_yet = rows_at(fresh, fresh_smelt).furnace_recipe_not_yet_established
  check(fresh_plan.status == "failed" and fresh.code == "FACTORY_COMPONENT_NOT_READY" and fresh.stage == "readiness"
    and fresh.refused and not_yet and not_yet.class == "evidence" and fresh.blockers[1].reason == "furnace_recipe_not_yet_established"
    and not reasons(fresh):match("output_identity_unproven"),
    "a furnace fed by a drill but not yet smelted is refused as not ready, not an identity defect")
  reset()
  local bare_box = chest(12, 1)
  local bare_smelt = furnace(6, 1, 5, COAL)
  inserter(9, 1, bare_smelt, bare_box)
  local bare_fuel = chest(4, 6)
  bare_fuel._stock.coal = 20
  local bare_coal = drill(1, 6, "coal", bare_fuel, 5, COAL)
  inserter(6, 4, bare_fuel, bare_smelt); inserter(2, 7, bare_fuel, bare_coal)
  local bare_plan, bare = validate(bare_box.position, 60)
  local bare_row = rows_at(bare, bare_smelt).output_identity_unproven
  check(bare_plan.status == "failed" and bare_row and bare_row.class == "structural"
    and not reasons(bare):match("furnace_recipe_not_yet_established"),
    "a furnace with only a fuel feed keeps the structural identity row")
end

-- Layout (b) on a 640-tick coal belt with eager returns served in belt order
-- (iron drill, furnace, coal drill last): one starter coal in the iron drill
-- and furnace, five in the coal drill. The upstream burners take every coal
-- while they fill, so the coal drill's draw waits longer than one supply
-- period per burner although it never runs out: a converging loop.
do
  local conv_box, conv_coal = shared_fuel_belt(1, COAL, nil, 640, 5)
  warm(300)
  local conv_plan, conv = validate(conv_box.position, 60)
  local conv_row = rows_at(conv, conv_coal).fuel_return_not_yet_exercised
  check(conv_plan.status == "failed" and not conv.proven and conv_row and conv_row.class == "evidence"
    and conv_row.suggested_duration_seconds > 60 and conv_row.suggested_duration_seconds <= 300
    and not reasons(conv):match("fuel_replenishment_not_observed") and not reasons(conv):match("transport_starved"),
    "a burner waiting behind other burners still filling on its source is converging evidence, not a starved return")
  local conv_rerun_plan, conv_rerun = validate(conv_box.position, conv_row and conv_row.suggested_duration_seconds or 300)
  check(conv_rerun_plan.status == "completed" and conv_rerun.proven, "the suggested window sees the converging loop refill it")

  -- Layout (f) with lazy returns and ten starter coal: the output-blocked coal
  -- drill burns so slowly that no 300 s window reaches its first draw below the
  -- top-up stock. That is a distinct evidence reason with the projection.
  local lazy_box, lazy_coal = fuel_only_belt(10, COAL, { lazy = true })
  warm(1200)
  local lazy_plan, lazy = validate(lazy_box.position, 60)
  local beyond = rows_at(lazy, lazy_coal).fuel_return_beyond_window
  check(lazy_plan.status == "failed" and not lazy.proven and beyond and beyond.class == "evidence"
    and beyond.projected_seconds > 300 and beyond.suggested_duration_seconds == nil
    and not rows_at(lazy, lazy_coal).fuel_return_not_yet_exercised and not reasons(lazy):match("transport_starved"),
    "a lazy return whose burner stays above the top-up stock beyond the longest window reports its projection")
end

-- Surplus before fuel: the coal belt's first takeoff is an eager overflow
-- chest (which also returns coal to its drill) that takes every coal, so the
-- later takeoff filling the hand-stocked fuel chest never moves. The iron
-- drill and furnace burn starter stock while plates keep arriving; the
-- starved fuel feeder must keep the window from proving the loop.
local function surplus_first(iron_fuel, furnace_fuel)
  reset()
  local head, tail = belt_line(1, 20, 60, 8)
  local coal_drill = drill(0, 18, "coal", head, 5, COAL)
  local overflow = chest(4, 22, 800)
  inserter(3, 21, tail, overflow)
  inserter(1, 21, overflow, coal_drill)
  local fuel_box = chest(6, 24)
  fuel_box._stock.coal = 20
  local feeder = inserter(5, 21, tail, fuel_box)
  local out = chest(14, 26)
  local smelter = furnace(10, 26, furnace_fuel, COAL)
  local ore_drill = drill(7, 26, "iron-ore", smelter, iron_fuel, COAL)
  inserter(7, 25, fuel_box, ore_drill); inserter(10, 25, fuel_box, smelter)
  inserter(12, 26, smelter, out)
  return out, feeder
end
-- A coal left past the overflow takeoff gives the feeder one early swing; its
-- later starvation must still count.
for _, case in ipairs({ { 17, 10, 300 }, { 8, 10, 60 }, { 17, 10, 300, true }, { 8, 10, 60, true } }) do
  local out, feeder = surplus_first(case[1], case[2])
  warm(600)
  local plan, outcome = validate(out.position, case[3], case[4] and function(elapsed)
    if elapsed == 100 then feeder._hand, feeder._timer, feeder._phase = "coal", 38, "to_drop" end
  end or nil)
  local starved = rows_at(outcome, feeder).transport_starved_before_end
  check(plan.status == "failed" and not outcome.proven and starved and starved.class == "throughput"
    and (outcome.products_finished_delta or 0) > 0,
    "a fuel chest stocked by hand behind a surplus takeoff that takes every coal is not proven in " .. case[3] .. " s" .. (case[4] and " after one early swing" or ""))
end

-- Recorder admission keeps legacy source proof and refuses incomplete native
-- aggregates; no native activity sample is disguised as a mining cycle.
do
  local activity = require("scripts.factory_activity")
  local valid = { proven = true, component_signature = "native-record", duration_ticks = 60,
    start_tick = game.tick - 60, end_tick = game.tick, products_finished_delta = 0,
    character_transfer_actions = 0, downstream_acceptance_samples = 3,
    source_cycles_observed = 0, native_source_activity_samples = 3, fluid_activity_samples = 3,
    mining_sources_present = false, native_power_required = true, power_delivery_samples = 3 }
  local function records(candidate)
    storage.factory_activity = { epoch_tick = game.tick - 60, events = {}, validations = {} }
    activity.record_validation(candidate, "exact-native-identity")
    return #activity.snapshot(game.tick - 60).validations
  end
  check(records(valid) == 1, "recorder admits genuine non-mining source activity with complete native aggregates")
  for _, field in ipairs({ "native_source_activity_samples", "fluid_activity_samples", "mining_sources_present",
    "native_power_required", "power_delivery_samples" }) do
    local incomplete = {}; for key, value in pairs(valid) do incomplete[key] = value end
    incomplete[field] = nil
    check(records(incomplete) == 0, "recorder rejects incomplete native evidence missing " .. field)
  end
  local legacy = { proven = true, component_signature = "legacy", duration_ticks = 60,
    products_finished_delta = 0, downstream_acceptance_samples = 3, source_cycles_observed = 2,
    character_transfer_actions = 0, start_tick = game.tick - 60, end_tick = game.tick }
  check(records(legacy) == 0, "native admission never weakens legacy mining-source requirements")
  legacy.source_cycles_observed = 3
  check(records(legacy) == 1, "legacy source-only validation remains admissible")
end

os.exit(failures == 0 and 0 or 1)
