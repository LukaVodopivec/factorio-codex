-- The sole persistent physical body. The retained record survives death so
-- connect_status can distinguish never-created from dead without respawning.
local M = {}

local CODEX_LABEL = "Codex"
local MOVEMENT_SPEED_SETTING = "agentic-companion-movement-speed"
local DEFAULT_MOVEMENT_SPEED = 1.6
local COLOR = { r = 0.30, g = 0.79, b = 0.69, a = 1 }

local LABEL_OFFSET = { 0, -2.9 }
local MAP_TAG_MOVE_SQ = 9

-- Keep the speed bonus scoped to companion bodies. A force-level modifier
-- would also accelerate human players, while LuaControl's modifier is local
-- to this character and composes with tiles, equipment and research.
function M.movement_speed_multiplier()
  local setting = settings and settings.global and settings.global[MOVEMENT_SPEED_SETTING]
  return (setting and tonumber(setting.value)) or DEFAULT_MOVEMENT_SPEED
end

local function apply_speed_to(ent)
  if not (ent and ent.valid) then return end
  ent.character_running_speed_modifier = M.movement_speed_multiplier() - 1
end

function M.apply_movement_speed()
  local rec = storage.companion
  apply_speed_to(rec and rec.entity)
end

function M.on_runtime_setting_changed(event)
  if event.setting == MOVEMENT_SPEED_SETTING then
    M.apply_movement_speed()
  end
end

function M.get()
  local rec = storage.companion
  local ent = rec and rec.entity
  if ent and ent.valid then return ent end
  return nil
end

function M.record()
  return storage.companion
end

function M.require_companion()
  local ent = M.get()
  if not ent then
    error("companion 'Codex' does not exist — call connect_status first")
  end
  return ent
end

-- Floating name tag that follows the character; self-healed periodically.
local function attach_label(rec, ent)
  pcall(function()
    if rec.label and rec.label.valid then rec.label.destroy() end
  end)
  rec.label = nil
  local args = {
    text = CODEX_LABEL,
    surface = ent.surface,
    color = COLOR,
    scale = 1.4,
    alignment = "center",
    scale_with_zoom = true,
  }
  local ok, obj = pcall(function()
    args.target = { entity = ent, offset = LABEL_OFFSET }
    return rendering.draw_text(args)
  end)
  if not ok or not obj then
    ok, obj = pcall(function()
      args.target = ent
      args.target_offset = LABEL_OFFSET
      return rendering.draw_text(args)
    end)
  end
  if ok and obj then rec.label = obj end
end

-- The map/minimap marker can't move, so re-pin it after the body drifts.
-- Runs on_nth_tick (wired in control.lua) and must never raise.
function M.update_map_tag()
  local rec = storage.companion
  if rec then
    local ent = rec.entity
    local alive = ent and ent.valid
    local tag = rec.map_tag
    local tag_valid = false
    pcall(function() tag_valid = tag and tag.valid end)

    if not alive then
      if tag_valid then pcall(function() tag.destroy() end) end
      rec.map_tag = nil
    else
      local label_valid = false
      pcall(function() label_valid = rec.label and rec.label.valid end)
      if not label_valid then attach_label(rec, ent) end

      local keep = false
      if tag_valid then
        local p = tag.position
        local dx, dy = p.x - ent.position.x, p.y - ent.position.y
        keep = dx * dx + dy * dy < MAP_TAG_MOVE_SQ
        if not keep then pcall(function() tag.destroy() end) end
      end
      if not keep then
        rec.map_tag = nil
        pcall(function()
          rec.map_tag = ent.force.add_chart_tag(ent.surface, {
            position = ent.position,
            text = CODEX_LABEL,
            icon = { type = "virtual", name = "signal-A" },
          })
        end)
      end
    end
  end
end


function M.spawn()
  local existing = M.get()
  if existing then
    apply_speed_to(existing)
    return {
      position = { x = existing.position.x, y = existing.position.y },
    }
  end
  if storage.companion and not M.get() then error("Codex died; this interface never respawns") end

  local surface, anchor, force
  local player = game.connected_players[1]
  if player then
    surface, anchor, force = player.surface, player.position, player.force
  else
    -- No one online (headless/CI): spawn at the force spawn point.
    force = game.forces.player
    surface = game.surfaces[1]
    anchor = force.get_spawn_position(surface)
  end

  local pos = surface.find_non_colliding_position("character", anchor, 16, 0.5)
  if not pos then error("no free spot to spawn the companion") end

  local ent = surface.create_entity({
    name = "character",
    position = pos,
    force = force,
    raise_built = true,
  })
  if not ent then error("failed to create companion character") end

  local rec = {}
  storage.companion = rec
  rec.entity = ent
  ent.color = COLOR
  apply_speed_to(ent)
  attach_label(rec, ent)
  M.update_map_tag()

  return {
    position = { x = pos.x, y = pos.y },
  }
end

return M
