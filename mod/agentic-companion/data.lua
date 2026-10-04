-- Keyless custom inputs linked to the game controls that drive the body, so
-- control.lua sees the Codex client's real control input (human takeover).
local human_inputs = require("scripts.human_inputs")

local inputs = {}
for _, control in ipairs(human_inputs.controls) do
  inputs[#inputs + 1] = { type = "custom-input", name = human_inputs.input_name(control),
    key_sequence = "", linked_game_control = control, consuming = "none" }
end
data:extend(inputs)
