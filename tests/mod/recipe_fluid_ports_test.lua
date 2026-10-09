-- Offline tests for fluid_connections.recipe_boxes and recipe_ports: which
-- fluid a crafting machine's recipe puts in each fluid box. The expected
-- rows are what Factorio 2.0.77 reports (LuaFluidBox.get_filter and
-- get_prototype on machines built with each recipe set).
local here = (arg and arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../../mod/agentic-companion/?.lua;" .. package.path

local failures = 0
local function check(cond, what)
  if cond then print("ok   " .. what) else failures = failures + 1; print("FAIL " .. what) end
end

-- Boxes as 2.0.77 lists them: "i" input, "o" output, one north-facing
-- connection each (only box order and production type matter here).
local function machine(name, roles)
  local boxes = {}
  for k = 1, #roles do
    boxes[k] = { index = k, production_type = roles:sub(k, k) == "i" and "input" or "output",
      pipe_connections = { { connection_type = "normal", direction = roles:sub(k, k) == "i" and 8 or 0,
        positions = { { x = k - 3, y = roles:sub(k, k) == "i" and 1 or -1 }, { x = 1, y = k - 3 },
          { x = 3 - k, y = 1 }, { x = -1, y = 3 - k } } } } }
  end
  return { name = name, type = "assembling-machine", fluidbox_prototypes = boxes }
end
local function fluids(list)
  local rows = {}
  for _, f in ipairs(list) do rows[#rows + 1] = { type = "fluid", name = f[1], amount = 10, fluidbox_index = f[2] } end
  rows[#rows + 1] = { type = "item", name = "stone", amount = 1 }
  return rows
end
local function recipe(ins, outs) return { ingredients = fluids(ins), products = fluids(outs) } end
_G.prototypes = { recipe = {
  ["plastic-bar"] = recipe({ { "petroleum-gas" } }, {}),
  ["sulfuric-acid"] = recipe({ { "water" } }, { { "sulfuric-acid" } }),
  ["heavy-oil-cracking"] = recipe({ { "water" }, { "heavy-oil" } }, { { "light-oil" } }),
  ["fluoroketone"] = recipe({ { "fluorine" }, { "ammonia" } }, { { "fluoroketone-hot" } }),
  ["molten-iron"] = recipe({}, { { "molten-iron" } }),
  ["iron-gear-wheel"] = recipe({}, {}),
  ["electric-engine-unit"] = recipe({ { "lubricant" } }, {}),
  ["advanced-oil-processing"] = recipe({ { "water" }, { "crude-oil" } }, { { "heavy-oil" }, { "light-oil" }, { "petroleum-gas" } }),
  ["basic-oil-processing"] = recipe({ { "crude-oil", 2 } }, { { "petroleum-gas", 3 } }),
  ["simple-coal-liquefaction"] = recipe({ { "sulfuric-acid" } }, { { "heavy-oil" } }),
  ["half-indexed"] = recipe({ { "water", 2 }, { "steam" } }, {}),
  ["two-of-four"] = recipe({ { "water" }, { "steam" } }, {}),
} }

local fc = require("scripts.fluid_connections")
local chem = machine("chemical-plant", "iioo")
local cryo = machine("cryogenic-plant", "iiiooo")
local foundry = machine("foundry", "iioo")
local assembler = machine("assembling-machine-2", "io")
local refinery = machine("oil-refinery", "iiooo")
local wide = machine("wide-mod-machine", "iiii")

-- Each box's fluid by index ("-" a removed box, "?" unknown).
local function layout(proto, recipe_name, count)
  local uses, out = fc.recipe_boxes(proto, recipe_name), {}
  for k = 1, count do
    local use = uses[k]
    out[k] = use == nil and "?" or use.fluid == false and "-" or use.fluid
  end
  return table.concat(out, " ")
end
local cases = {
  { chem, "plastic-bar", 4, "petroleum-gas petroleum-gas - -", "one fluid ingredient takes both merged inputs; no fluid product removes the outputs" },
  { chem, "sulfuric-acid", 4, "water water sulfuric-acid sulfuric-acid", "one fluid each way takes both boxes of each role" },
  { chem, "heavy-oil-cracking", 4, "water heavy-oil light-oil light-oil", "two ingredients in two inputs, one each in order" },
  { cryo, "fluoroketone", 6, "fluorine fluorine ammonia fluoroketone-hot fluoroketone-hot fluoroketone-hot",
    "two fluids in three boxes: the first takes boxes 1+2, the second box 3" },
  { foundry, "molten-iron", 4, "- - molten-iron molten-iron", "a recipe with no fluid ingredient removes the input boxes" },
  { assembler, "iron-gear-wheel", 2, "- -", "a recipe with no fluid removes every box" },
  { assembler, "electric-engine-unit", 2, "lubricant -", "an assembler's lubricant goes to its input box" },
  { refinery, "advanced-oil-processing", 5, "water crude-oil heavy-oil light-oil petroleum-gas", "advanced oil processing fills all five boxes in order" },
  { refinery, "basic-oil-processing", 5, "- crude-oil - - petroleum-gas",
    "fluidbox_index picks the role's box (crude oil input 2, gas output 3 = box 5); the rest are removed" },
  { refinery, "simple-coal-liquefaction", 5, "sulfuric-acid sulfuric-acid heavy-oil heavy-oil heavy-oil", "one product takes all three outputs" },
  { refinery, "half-indexed", 5, "? ? - - -", "an index only some fluids name leaves that role unknown" },
  { wide, "two-of-four", 4, "? ? ? ?", "fewer fluids than boxes beyond three boxes of a role is unknown" },
}
for _, c in ipairs(cases) do
  local got = layout(c[1], c[2], c[3])
  check(got == c[4], c[1].name .. " " .. c[2] .. ": " .. c[5] .. " (" .. got .. ")")
end

-- recipe_ports: each port carries its box's role and fluid.
local area = { left_top = { x = -2.5, y = -2.5 }, right_bottom = { x = 2.5, y = 2.5 } }
local ports = fc.recipe_ports(refinery, "basic-oil-processing", 0, area)
local by_box = {}
for _, port in ipairs(ports) do by_box[port.box] = port end
check(#ports == 5 and by_box[2].role == "input" and by_box[2].fluid == "crude-oil" and by_box[1].fluid == false
  and by_box[5].role == "output" and by_box[5].fluid == "petroleum-gas",
  "recipe_ports gives every port its role and fluid, false for a removed box")
local unknown = fc.recipe_ports(refinery, "half-indexed", 0, area)
check(unknown[1].role == nil and unknown[1].fluid == nil, "a port whose box use is unknown has no role or fluid")

-- Mirrored ports. A chemical plant as 2.0 defines it (inputs north at
-- x -1 and 1, outputs south), positions turned clockwise per direction.
-- Assumed game rule: mirroring reflects the north-frame connection across
-- the vertical axis (x to -x, east and west swapped) before the turn, which
-- is what the game's horizontal blueprint flip implies (direction 16 - d
-- with mirroring toggled mirrors the world-space ports).
do
  local function box(index, role, x, y, d)
    local positions = {}
    for q = 0, 3 do
      positions[q + 1] = { x = x, y = y }
      x, y = -y, x
    end
    return { index = index, production_type = role,
      pipe_connections = { { connection_type = "normal", direction = d, positions = positions } } }
  end
  local plant = { name = "chemical-plant", type = "assembling-machine", fluidbox_prototypes = {
    box(1, "input", -1, -1, 0), box(2, "input", 1, -1, 0), box(3, "output", -1, 1, 8), box(4, "output", 1, 1, 8) } }
  local square = { left_top = { x = -1.5, y = -1.5 }, right_bottom = { x = 1.5, y = 1.5 } }
  local function at_box(list)
    local out = {}
    for _, port in ipairs(list) do out[port.box] = port end
    return out
  end
  local north = at_box(fc.recipe_ports(plant, "heavy-oil-cracking", 0, square, true))
  check(north[1].fluid == "water" and north[1].at.x == 1 and north[1].at.y == -1 and north[1].target.x == 1
    and north[1].target.y == -2 and north[2].fluid == "heavy-oil" and north[2].at.x == -1,
    "a mirrored chemical plant facing north takes its first input (water) at x 1 and its second at x -1")
  local east = at_box(fc.ports(plant, 4, square, true))
  check(east[1].at.x == 1 and east[1].at.y == 1 and east[1].target.x == 2 and east[1].target.y == 1
    and east[3].at.x == -1 and east[3].at.y == 1 and east[3].target.x == -2 and east[3].target.y == 1,
    "a mirrored plant facing east reflects, then turns: its first input sits south-east and leads east")
  local same = true
  for d = 0, 12, 4 do
    local plain, flipped = at_box(fc.ports(plant, d, square)), at_box(fc.ports(plant, (16 - d) % 16, square, true))
    for b = 1, 4 do
      if not (flipped[b].at.x == -plain[b].at.x and flipped[b].at.y == plain[b].at.y
        and flipped[b].target.x == -plain[b].target.x and flipped[b].target.y == plain[b].target.y) then same = false end
    end
  end
  check(same, "assumed game rule: mirrored at direction 16 - d is the plain plant at d flipped left to right (every port)")
end

print(failures == 0 and "\nALL RECIPE FLUID PORT TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
