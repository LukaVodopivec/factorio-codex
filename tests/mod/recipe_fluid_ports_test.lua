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

print(failures == 0 and "\nALL RECIPE FLUID PORT TESTS PASSED" or ("\n" .. failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
