-- craft: hand-crafting via the character crafting queue. Like a player, the
-- body queues the crafts and moves on while they finish (the default);
-- wait_for_completion = true waits for them. A craft whose direct
-- ingredients are still in the crafting queue waits for them first, so
-- begin_crafting never makes them a second time from raw materials, and a
-- step that consumes an item waits while its output is still queued
-- (M.awaits). begin_crafting returns how many it actually started; the queue
-- is polled via crafting_queue_size.
local companion = require("scripts.companion")
local placement_geometry = require("scripts.placement_geometry")

local M = {}

local POLL_TICKS = 30
local MAX_COUNT = 100

-- Items of `item` one craft of `recipe` yields; an uncertain amount counts 1.
local function per_craft(recipe, item)
  local total = 0
  for _, product in ipairs(recipe and recipe.products or {}) do
    if product.type == "item" and product.name == item then
      local amount = product.amount
      if amount == nil and product.amount_min == product.amount_max then amount = product.amount_min end
      if (product.probability ~= nil and product.probability ~= 1) or type(amount) ~= "number" or amount <= 0 then
        amount = 1
      end
      total = total + amount
    end
  end
  return total
end

-- How many of `item` the body's crafting queue will still hand over.
-- Prerequisite entries are intermediates the next entry consumes.
function M.queued(c, item)
  local ok, queue = pcall(function() return c.crafting_queue end)
  if not ok or type(queue) ~= "table" then return 0 end
  local total = 0
  for _, entry in ipairs(queue) do
    if not entry.prerequisite and type(entry.recipe) == "string" then
      local recipe = c.force.recipes[entry.recipe]
      total = total + per_craft(recipe, item) * (tonumber(entry.count) or 0)
    end
  end
  return total
end

-- A step that waits on the crafting queue marks the tick it did
-- (storage.craft_wait_tick, made when first needed): the step watchdog counts
-- hand-crafting as progress only for such a step, so background crafts never
-- keep a step that waits on something else from stalling.
local function mark_wait() storage.craft_wait_tick = game.tick end
-- A step that waits on the crafting queue tells the watchdog (tasks.lua).
M.mark_wait = mark_wait

-- A step about to consume `count` of `name` waits while it carries fewer
-- and the crafting queue still makes some.
function M.awaits(c, name, count)
  if c.get_item_count(name) < count and M.queued(c, name) > 0 then mark_wait(); return true end
  return false
end

-- What's short for `count` crafts, e.g. "2x iron-plate, 1x iron-gear-wheel".
-- Must run BEFORE begin_crafting consumes the ingredients.
local function missing_ingredients(c, recipe, count)
  local parts = {}
  for _, ing in ipairs(recipe.ingredients or {}) do
    if ing.type == "item" then
      local have = c.get_item_count(ing.name)
      local need = ing.amount * count
      if have < need then
        parts[#parts + 1] = string.format("%dx %s", need - have, ing.name)
      end
    end
  end
  return table.concat(parts, ", ")
end

local function awaits_ingredients(c, recipe, count)
  for _, ing in ipairs(recipe.ingredients or {}) do
    if ing.type == "item" and M.awaits(c, ing.name, ing.amount * count) then return true end
  end
  return false
end

function M.start(task)
  local c = companion.require_companion()
  if type(task.recipe) ~= "string" then
    error("craft requires recipe = <recipe name>")
  end
  local count = tonumber(task.count)
  if not count or count % 1 ~= 0 or count < 1 or count > MAX_COUNT then
    error("craft crafts must be an integer from 1 to 100")
  end
  task.count = count

  local r = c.force.recipes[task.recipe]
  if not r then
    error("unknown recipe: '" .. task.recipe .. "'")
  end
  if not r.enabled then
    error("recipe " .. task.recipe .. " isn't unlocked yet — research it first")
  end
  -- Hand-crafting keeps the recipe's surface conditions too.
  local refused = placement_geometry.condition_refusal(c.surface, "recipe", task.recipe)
  if refused then error(refused.reason, 0) end
  task._craft = nil
end

-- Queues the crafts. Returns a failed result when none could start.
local function begin(task, c)
  local r = c.force.recipes[task.recipe]
  local count = task.count
  local product_names, before, products_per_craft = {}, {}, {}
  for _, p in ipairs(r.products or {}) do
    if p.type == "item" then
      product_names[#product_names + 1] = p.name
      before[p.name] = c.get_item_count(p.name)
      local amount = tonumber(p.amount)
      if amount == nil and p.amount_min == p.amount_max then amount = tonumber(p.amount_min) end
      if amount ~= nil and (p.probability == nil or p.probability == 1) then
        products_per_craft[p.name] = (products_per_craft[p.name] or 0) + amount
      end
    end
  end

  local missing = missing_ingredients(c, r, count)
  local started = c.begin_crafting({ count = count, recipe = task.recipe })
  if started == 0 then
    if missing ~= "" then
      return { status = "failed", detail = "can't craft " .. task.recipe .. " — missing ingredients: " .. missing }
    end
    return { status = "failed", detail = "can't craft " .. task.recipe .. " — this recipe can't be crafted by hand" }
  end

  local note = ""
  if started < count then
    note = string.format(" (only started %d of %d — missing ingredients: %s)",
      started, count, missing ~= "" and missing or "not enough materials")
  end
  task._craft = {
    started = started,
    note = note,
    product_names = product_names,
    products_before = before,
    products_per_craft = products_per_craft,
    next_poll = game.tick + POLL_TICKS,
  }
end

function M.tick(task)
  local c = companion.get()
  if not c then
    return { status = "failed", detail = "the companion character is gone" }
  end
  if not task._craft then
    local r = c.force.recipes[task.recipe]
    if awaits_ingredients(c, r, task.count) then return nil end
    local failed = begin(task, c)
    if failed then return failed end
  end
  local s = task._craft
  if task.wait_for_completion ~= true then
    local expected = {}
    for name, amount in pairs(s.products_per_craft) do
      expected[#expected + 1] = string.format("%g %s", amount * s.started, name)
    end
    for _, name in ipairs(s.product_names) do
      if s.products_per_craft[name] == nil then expected[#expected + 1] = "variable " .. name end
    end
    table.sort(expected)
    return {
      status = "done",
      detail = string.format("accepted %d recipe crafts of %s into Factorio's hand-crafting queue; expected outputs: %s%s",
        s.started, task.recipe, table.concat(expected, ", "), s.note),
    }
  end
  if game.tick < s.next_poll then return nil end
  s.next_poll = game.tick + POLL_TICKS
  if c.crafting_queue_size > 0 then mark_wait(); return nil end

  -- An empty queue is not completion: the queue can be cancelled, or the
  -- products taken, while the player holds the body. Count the crafts whose
  -- fixed-amount products are actually carried.
  local parts, produced = {}, nil
  for _, name in ipairs(s.product_names) do
    local gained = c.get_item_count(name) - s.products_before[name]
    if gained > 0 then
      parts[#parts + 1] = string.format("+%d %s", gained, name)
    end
    local per = s.products_per_craft[name]
    if per and per > 0 then
      local crafts = math.max(0, math.floor(gained / per))
      if not produced or crafts < produced then produced = crafts end
    end
  end
  local gains = #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
  if produced and produced < s.started then
    return {
      status = produced > 0 and "partial" or "failed",
      detail = string.format("hand-crafting queue emptied with the products of %d of %d recipe crafts of %s carried%s"
        .. " - the queue was cancelled or the products were removed%s",
        produced, s.started, task.recipe, gains, s.note),
      outcome = { code = "CRAFT_PRODUCTS_MISSING", recipe = task.recipe, crafts_started = s.started, crafts_evidenced = produced },
    }
  end
  return {
    status = "done",
    detail = string.format("completed %d recipe crafts of %s%s%s", s.started, task.recipe, gains, s.note),
  }
end

return M
