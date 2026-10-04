-- Game controls that drive the Codex body from its own client. data.lua links
-- one keyless custom input to each (names verified against the 2.0.77
-- LinkedGameControl type) and control.lua listens to them all; a linked input
-- fires on the real key or button press only, never on mouse hover. Kept free
-- of runtime dependencies: the data stage requires it too.
local M = {}

M.controls = {
  "move-up", "move-down", "move-left", "move-right",
  "mine", "build", "build-ghost", "super-forced-build", "build-with-obstacle-avoidance",
  "open-gui", "open-character-gui", "pick-items", "drop-cursor", "clear-cursor", "pipette",
  "rotate", "reverse-rotate", "flip-horizontal", "flip-vertical",
  "toggle-driving", "shoot-enemy", "shoot-selected", "use-item", "alternative-use-item",
  "copy-entity-settings", "paste-entity-settings", "remove-pole-cables",
  "craft", "craft-5", "craft-all", "cancel-craft", "cancel-craft-5", "cancel-craft-all",
  "pick-item", "stack-transfer", "inventory-transfer", "fast-entity-transfer",
  "cursor-split", "stack-split", "inventory-split", "fast-entity-split",
}

function M.input_name(control)
  return "agentic-companion-" .. control
end

-- The mod's only write path to the body's walking_state. It records what it
-- commanded, so walking the mod did not command is recognisable as the
-- client's movement keys. A write is readable from the body only on the next
-- tick (native 2.0.77), hence the record instead of a read-back.
function M.set_walking(body, walking_state)
  body.walking_state = walking_state
  if storage.tasks then storage.tasks.commanded_walk = walking_state end
end

return M
