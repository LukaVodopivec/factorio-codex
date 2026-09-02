-- The sole persistent physical body is Factorio's real connected LuaPlayer
-- named Codex. The mod never creates, replaces or teleports that character.
local M = {}

local CODEX_LABEL = "Codex"
local COLOR = { r = 0.30, g = 0.79, b = 0.69, a = 1 }

local LABEL_OFFSET = { 0, -2.9 }
local MAP_TAG_MOVE_SQ = 9

local function get_player(index)
  if not index then return nil end
  if game.get_player then return game.get_player(index) end
  return game.players and game.players[index] or nil
end

local function is_native_codex(player)
  return player and player.valid ~= false and player.connected ~= false
    and player.name == CODEX_LABEL
    and player.controller_type == defines.controllers.character
    and player.character and player.character.valid
end

local function enforce_normal_speed(ent)
  if not (ent and ent.valid) then return end
  if ent.character_running_speed_modifier ~= 0 then ent.character_running_speed_modifier = 0 end
end

function M.enforce_normal_speed()
  enforce_normal_speed(M.get())
end

-- Spectators have no character to move. Keep their cameras on Codex while
-- leaving the native Codex player's physical movement untouched.
function M.follow_spectators()
  local ent = M.get()
  if not ent then return end
  for _, player in pairs(game.connected_players) do
    if player.controller_type == defines.controllers.spectator then
      pcall(function() player.teleport(ent.position, ent.surface) end)
    end
  end
end

function M.get()
  local rec = storage.companion
  if not rec then return nil end

  local player = get_player(rec.player_index)
  -- Compatible migration for an old save whose record already points at a
  -- real player's character. A standalone legacy character is never adopted.
  if not player and rec.entity and rec.entity.valid then
    for _, candidate in pairs(game.players or game.connected_players or {}) do
      if candidate.character == rec.entity then
        player = candidate
        rec.player_index = candidate.index
        break
      end
    end
  end

  local ent = rec.entity
  if is_native_codex(player) and player.character == ent then
    enforce_normal_speed(ent)
    return ent
  end
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

local function bind_native_player(player)
  if not is_native_codex(player) then return false end

  local rec = storage.companion or {}
  local previous = rec.entity
  if previous and previous.valid and previous ~= player.character then
    if rec.player_index then
      error("refusing a second Codex body")
    end
    -- One-time old-save migration: remove the prior standalone body rather
    -- than retaining a second character beside the native player.
    previous.destroy()
  end
  storage.companion = rec
  rec.player_index = player.index
  rec.entity = player.character
  rec.dead = nil
  rec.disconnected = nil
  rec.entity.color = COLOR
  enforce_normal_speed(rec.entity)
  attach_label(rec, rec.entity)
  M.update_map_tag()
  return true
end

-- All non-Codex clients are viewers. Factorio owns the controller change;
-- destroying the detached join character prevents a second physical body or
-- a second inventory from surviving the transition.
local function make_viewer(player)
  if not player or player.valid == false or player.name == CODEX_LABEL then return end
  local detached = player.character
  if player.controller_type ~= defines.controllers.spectator then
    player.set_controller({ type = defines.controllers.spectator })
  end
  if detached and detached.valid then detached.destroy() end
end

function M.on_player_available(event)
  local player = get_player(event.player_index)
  if not player then return end
  if player.name == CODEX_LABEL then
    bind_native_player(player)
  else
    make_viewer(player)
  end
end

function M.on_player_left(event)
  local rec = storage.companion
  if rec and rec.player_index == event.player_index then rec.disconnected = true end
end

function M.on_player_died(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.dead = true
  rec.entity = nil
  rec.disconnected = nil
  M.update_map_tag()
end

-- A respawn is accepted only after Factorio has created the native player's
-- character and raised its lifecycle event. This mod has no respawn path.
function M.on_player_respawned(event)
  M.on_player_available(event)
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


function M.connect()
  local existing = M.get()
  if existing then
    return {
      position = { x = existing.position.x, y = existing.position.y },
    }
  end
  for _, player in pairs(game.connected_players) do
    if is_native_codex(player) then
      bind_native_player(player)
      local ent = player.character
      return { position = { x = ent.position.x, y = ent.position.y } }
    end
  end
  error("native player 'Codex' is not connected with a living character")
end

-- Kept for old control.lua/save rollback compatibility. Despite the legacy
-- name it only binds the native player and can never create a character.
M.spawn = M.connect

-- Fresh and existing surfaces remain peaceful and generate no enemy bases.
-- Shared wiring calls this on init/configuration and surface creation.
function M.enforce_peaceful_world()
  game.map_settings.enemy_expansion.enabled = false
  for _, surface in pairs(game.surfaces) do
    surface.peaceful_mode = true
    local settings = surface.map_gen_settings
    settings.autoplace_controls = settings.autoplace_controls or {}
    settings.autoplace_controls["enemy-base"] = {
      frequency = 0,
      size = 0,
      richness = 0,
    }
    surface.map_gen_settings = settings
  end
end

return M
