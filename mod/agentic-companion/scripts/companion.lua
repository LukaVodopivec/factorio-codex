-- The sole persistent physical body is Factorio's real connected LuaPlayer
-- named Codex. The mod never creates, replaces or teleports that character.
--
-- Body model (0.22.3): M.body() says where the Codex player's body is, in
-- every controller state and on every surface, and never errors:
--   absent | disconnected   no connected Codex player
--   dead                    waiting to respawn
--   in_transit              riding a cargo pod (or the launch cutscene of a
--                           travel step)
--   aboard_platform         sitting in a space platform hub
--   on_surface              standing in its character on a surface
--   other                   any other controller (editor, god, ...)
-- The order is load-bearing: aboard, controller_type reads remote while the
-- character may still look valid. Physical runners get the character
-- (M.get) only on_surface; reads anchor on M.anchor() in every state but
-- absent.
local human_inputs = require("scripts.human_inputs")
local plain_error = require("scripts.errors").plain

local M = {}

local CODEX_LABEL = "Codex"
local COLOR = { r = 0.30, g = 0.79, b = 0.69, a = 1 }

local LABEL_OFFSET = { 0, -2.9 }
local MAP_TAG_MOVE_SQ = 9
-- A travel step's launch or landing that never reaches a pod or a hub stops
-- counting as transit after this long.
local TRAVEL_CUTSCENE_TICKS = 36000

local function get_player(index)
  if not index then return nil end
  return game.get_player(index)
end

local function read(fn)
  local ok, value = pcall(fn)
  if ok then return value end
end

local function controller(name)
  return defines.controllers and defines.controllers[name]
end

local function valid(entity)
  return entity ~= nil and read(function() return entity.valid end) == true
end

-- The canonical reference of a surface: its planet's name, or
-- "platform:<index>" for a space platform's surface (else its name).
function M.surface_ref(surface)
  if not surface then return nil end
  local platform = read(function() return surface.platform end)
  if platform then
    local index = read(function() return platform.index end)
    if index then return "platform:" .. index end
  end
  return read(function() return surface.name end)
end

local function travel_cutscene(player)
  local travel = storage.travel and storage.travel.active
  return travel ~= nil and player.controller_type == controller("cutscene")
    and game.tick - (travel.since_tick or game.tick) < TRAVEL_CUTSCENE_TICKS
end

-- The state of a connected Codex player's body (rec: storage.companion).
local function classify(player, rec)
  if rec and rec.dead or read(function() return player.ticks_to_respawn end) ~= nil then return "dead" end
  if read(function() return player.cargo_pod end) ~= nil or travel_cutscene(player) then return "in_transit" end
  if read(function() return player.hub end) ~= nil then return "aboard_platform" end
  local physical = read(function() return player.physical_controller_type end) or player.controller_type
  if valid(player.character) and physical == controller("character") then return "on_surface" end
  return "other"
end

-- The connected Codex player (any body state), or nil.
local function codex_player()
  local rec = storage.companion
  local player = rec and get_player(rec.player_index)
  if player and player.valid ~= false and player.connected and player.name == CODEX_LABEL then return player end
  return nil
end

-- Where the body is, for reads: {surface, position, entity?}. Its physical
-- surface and position, the hub aboard, the pod in transit.
local function locate(player, state)
  if state == "in_transit" then
    local pod = read(function() return player.cargo_pod end)
    if valid(pod) then return pod.surface, pod.position, pod end
  elseif state == "aboard_platform" then
    local hub = read(function() return player.hub end)
    if valid(hub) then return hub.surface, hub.position, hub end
  end
  local surface = read(function() return player.physical_surface end) or read(function() return player.surface end)
  local position = read(function() return player.physical_position end) or read(function() return player.position end)
  local character = read(function() return player.character end)
  return surface, position, valid(character) and character or nil
end

-- {state, player, character?, surface, surface_ref, position, force,
-- platform?} for the Codex player; {state = "absent"} without one. Never
-- errors.
function M.body()
  local ok, body = pcall(function()
    local rec = storage.companion
    local player = rec and get_player(rec.player_index)
    if not (player and player.valid ~= false and player.name == CODEX_LABEL) then return { state = "absent" } end
    if not player.connected then return { state = "disconnected", player = player } end
    local state = classify(player, rec)
    local surface, position, entity = locate(player, state)
    local character = read(function() return player.character end)
    return { state = state, player = player, character = valid(character) and character or nil,
      surface = surface, surface_ref = M.surface_ref(surface), entity = entity,
      position = position and { x = position.x, y = position.y } or nil,
      force = read(function() return player.force end),
      platform = state == "aboard_platform" and read(function() return surface.platform end) or nil }
  end)
  if ok then return body end
  return { state = "absent" }
end

-- {surface, position, force} for reads, or nil when there is no connected
-- Codex player (or it has no surface).
function M.anchor()
  local body = M.body()
  if body.state == "absent" or body.state == "disconnected" or not body.surface then return nil end
  return { surface = body.surface, position = body.position, force = body.force, state = body.state,
    surface_ref = body.surface_ref }
end

-- What ping, fifo_state and connect_status show: {state, surface_ref,
-- platform_name?, rebind_refused?}. rebind_refused ({tick, characters}):
-- the player had two live characters after a trip or respawn, so none was
-- bound and physical actions fail REBIND_REFUSED.
function M.body_summary()
  local body = M.body()
  local rec = storage.companion
  return { state = body.state, surface_ref = body.surface_ref,
    platform_name = body.platform and read(function() return body.platform.name end) or nil,
    rebind_refused = rec and rec.rebind_refused or nil }
end

-- Whether the Codex player is dead and waits to respawn (a cheap read for
-- the dispatcher, which pauses meanwhile).
function M.is_dead()
  local rec = storage.companion
  if not rec then return false end
  if rec.dead then return true end
  local player = codex_player()
  return player ~= nil and read(function() return player.ticks_to_respawn end) ~= nil
end

-- In map or remote view the client's input drives the view, not the body,
-- and the character stays script-controllable (native 2.0.77): its physical
-- controller is still the character.
local function on_surface(player, rec)
  return player ~= nil and player.valid ~= false and player.connected ~= false and player.name == CODEX_LABEL
    and classify(player, rec) == "on_surface"
end
local function enforce_normal_speed(ent)
  if not (ent and ent.valid) then return end
  if ent.character_running_speed_modifier ~= 0 then ent.character_running_speed_modifier = 0 end
end

function M.enforce_normal_speed()
  enforce_normal_speed(M.get())
end

-- Spectators have no character to move. Keep their cameras on Codex, on its
-- physical surface (the hub aboard, the pod in transit), while leaving the
-- native Codex player's physical movement untouched.
function M.follow_spectators()
  local spectator = defines.controllers.spectator
  local anchor
  for _, player in pairs(game.connected_players) do
    if player.controller_type == spectator then
      anchor = anchor or M.anchor() or false
      if not (anchor and anchor.position) then return end
      pcall(function() player.teleport(anchor.position, anchor.surface) end)
    end
  end
end

-- The character, only while the body stands in it on a surface.
function M.get()
  local rec = storage.companion
  local ent = rec and rec.entity
  if not ent then return nil end
  local player = get_player(rec.player_index)
  if on_surface(player, rec) and player.character == ent then
    enforce_normal_speed(ent)
    return ent
  end
  return nil
end

function M.record()
  return storage.companion
end

-- Human takeover. Real control input on the Codex client holds the body until
-- 300 ticks after the last of it; storage.tasks.human_activity_tick is that
-- last input and human_activity_cause what it was (the linked control's name,
-- gui, cursor, walking or mining). Input is a linked custom input
-- (scripts/human_inputs.lua), an open GUI, an item in the cursor, or walking
-- the mod did not command; during a hold, any walking or mining. Mouse hover, camera movement and afk_time are
-- not input: afk_time also resets when the bot's own walking scrolls the view
-- under a resting cursor (native 2.0.77). Everything counts only for the
-- connected Codex player in its character: map or remote view moves the view,
-- so the bot keeps working while the player looks around. Aboard a platform the
-- client is in the remote view, yet a GUI, a held item or any control but
-- the movement keys (which only pan the camera there) is still their input on
-- the Codex client.
local HUMAN_RELEASE_IDLE_TICKS = 300
local NEVER_ACTIVE_IDLE_TICKS = 2147483647

local function in_character(player)
  return player.controller_type == defines.controllers.character and on_surface(player, storage.companion)
end
-- In the character, or aboard a platform: where the client's own input is
-- the player's (map and remote view on a surface move only the view).
local function takes_input(player)
  return in_character(player) or classify(player, storage.companion) == "aboard_platform"
end
local function note_activity(cause)
  if storage.tasks then storage.tasks.human_activity_tick, storage.tasks.human_activity_cause = game.tick, cause end
end
local INPUT_PREFIX = human_inputs.input_name("")

-- The linked movement inputs: aboard they pan the camera.
local CAMERA_INPUTS = {}
for _, control in ipairs({ "move-up", "move-down", "move-left", "move-right" }) do
  CAMERA_INPUTS[human_inputs.input_name(control)] = true
end

-- A linked custom input or on_gui_opened (the mod never opens a GUI).
function M.on_human_input(event)
  local rec = storage.companion
  if not (rec and rec.player_index and event.player_index == rec.player_index) then return end
  local player = codex_player()
  if not (player and takes_input(player)) then return end
  if not in_character(player) and CAMERA_INPUTS[event.input_name] then return end
  local input = event.input_name
  note_activity(input and (input:sub(1, #INPUT_PREFIX) == INPUT_PREFIX and input:sub(#INPUT_PREFIX + 1) or input) or "gui")
end

-- Called once per tick before the dispatcher decides the hold and before the
-- mod writes any body state. A press event marks only the moment of a press;
-- this keeps the hold alive while a key is held down or a GUI stays open.
function M.poll_human_activity(holding)
  local player = codex_player()
  if not (player and takes_input(player)) then return end
  local cursor = player.cursor_stack
  local active = player.opened_gui_type ~= defines.gui_type.none and "gui"
    or (cursor and cursor.valid_for_read) and "cursor" or nil
  if not in_character(player) then
    if active then note_activity(active) end
    return
  end
  local body = player.character
  local walking = body.walking_state
  if walking and walking.walking then
    -- The mod is the only script writer of walking_state and records each
    -- write (human_inputs.set_walking): walking it did not command, or in
    -- another direction, is the client's movement keys.
    local commanded = storage.tasks and storage.tasks.commanded_walk
    if holding or not (commanded and commanded.walking) or commanded.direction ~= walking.direction then
      active = active or "walking"
    end
  end
  if holding and body.mining_state and body.mining_state.mining then active = active or "mining" end
  if active then note_activity(active) end
end

-- Returns held, idle ticks and, when held, the cause: the noted input's
-- (human_activity_cause), or controller. On a surface, map or remote view
-- never holds; any controller other than the character holds (a missing
-- character too), so queued work stays parked instead of failing for want of
-- a body. In
-- transit or aboard the body is busy with a trip, which holds nothing by
-- itself; only noted input does. A dead body, unreadable state and a
-- disconnected player never hold.
function M.human_control()
  local ok, held, idle, cause = pcall(function()
    local player = codex_player()
    if not player then return false end
    local last = storage.tasks and storage.tasks.human_activity_tick
    local idle = last and math.max(0, game.tick - last) or NEVER_ACTIVE_IDLE_TICKS
    local state = classify(player, storage.companion)
    if state == "dead" then return false, idle end
    if state == "on_surface" then
      if player.controller_type == defines.controllers.remote then return false, idle end
      if player.controller_type ~= defines.controllers.character then return true, idle, "controller" end
    elseif state == "other" then
      return true, idle, "controller"
    end
    if idle < HUMAN_RELEASE_IDLE_TICKS then return true, idle, storage.tasks.human_activity_cause or "input" end
    return false, idle
  end)
  if not ok then return false end
  return held, idle, cause
end

-- The connected Codex player's body in any state but absent: {state, force,
-- surface, ...} (M.body). Remote actions and reads use it; they need no
-- character.
function M.require_present()
  local body = M.body()
  if body.state == "absent" or body.state == "disconnected" or not body.force then
    error("BODY_UNAVAILABLE: companion 'Codex' does not exist (no connected Codex player) — call connect_status first", 0)
  end
  return body
end

-- The character for a physical action, or an error naming where the body is.
function M.require_companion()
  local ent = M.get()
  if ent then return ent end
  local body = M.body()
  if body.state == "in_transit" then
    error("BODY_IN_TRANSIT: the body is riding a cargo pod; physical actions wait until it lands", 0)
  elseif body.state == "aboard_platform" then
    local name = body.platform and read(function() return body.platform.name end)
    error(string.format("BODY_ABOARD: the body is aboard platform %s (%s); physical actions need it on a planet,"
      .. " remote tools still work", tostring(name), tostring(body.surface_ref)), 0)
  elseif body.state == "dead" then
    error("BODY_DEAD: the body is dead and waits to respawn", 0)
  elseif body.state == "absent" or body.state == "disconnected" then
    error("BODY_UNAVAILABLE: companion 'Codex' does not exist (no connected Codex player) — call connect_status first", 0)
  end
  local refused = storage.companion and storage.companion.rebind_refused
  if refused and body.state == "on_surface" then
    error(string.format("REBIND_REFUSED: the Codex player has %d live characters, so none is bound as the body;"
      .. " one body only: remove the extra character", refused.characters or 2), 0)
  end
  error("BODY_UNAVAILABLE: the Codex player is not in its character (controller " .. tostring(read(function()
    return body.player.controller_type end)) .. ")", 0)
end

-- Floating name tag that follows the body: the character, the hub aboard,
-- the pod in transit; self-healed periodically.
local function attach_label(rec, ent)
  pcall(function()
    if rec.label and rec.label.valid then rec.label.destroy() end
  end)
  rec.label, rec.label_target = nil, ent
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

local function bind(rec, player, character)
  storage.companion = rec
  rec.player_index = player.index
  rec.entity = character
  rec.dead = nil
  rec.disconnected = nil
  rec.removed = nil
  rec.entity.color = COLOR
  enforce_normal_speed(rec.entity)
  attach_label(rec, rec.entity)
  M.update_map_tag()
end

local function bind_native_player(player)
  if not (player and player.valid ~= false and player.connected ~= false and player.name == CODEX_LABEL) then return false end
  local character = read(function() return player.character end)
  if not valid(character) then return false end

  local rec = storage.companion or {}
  local previous = rec.entity
  if previous and previous.valid and previous ~= character then
    if rec.player_index then
      error("refusing a second Codex body")
    end
    -- One-time old-save migration: remove the prior standalone body rather
    -- than retaining a second character beside the native player.
    previous.destroy()
  end
  bind(rec, player, character)
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

-- After the Codex player changed surface, landed from a cargo pod or
-- respawned: bind its character again when the stored one is gone or is
-- that same character. A different stored character that is still valid is
-- replaced too, unless the player has two valid characters associated (then
-- nothing is bound and the refusal is kept for ping).
function M.rebind(event)
  local rec = storage.companion
  if not (rec and rec.player_index and event.player_index == rec.player_index) then return end
  local player = codex_player()
  local character = player and read(function() return player.character end)
  if not valid(character) then return end
  local previous = rec.entity
  if valid(previous) and previous ~= character then
    local live = 0
    for _, other in ipairs(read(function() return player.get_associated_characters() end) or {}) do
      if valid(other) then live = live + 1 end
    end
    if live >= 2 then
      rec.rebind_refused = { tick = game.tick, characters = live }
      return
    end
  end
  rec.rebind_refused = nil
  bind(rec, player, character)
end

function M.on_player_left(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.entity = nil
  rec.disconnected = true
  M.update_map_tag()
end

function M.on_player_removed(event)
  local rec = storage.companion
  if not rec or rec.player_index ~= event.player_index then return end
  rec.entity = nil
  rec.player_index = nil
  rec.disconnected = nil
  rec.removed = true
  M.update_map_tag()
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
  local rec = storage.companion
  if rec and rec.player_index == event.player_index then rec.dead = nil end
  M.rebind(event)
end

-- The body's surface against the one last seen (storage.companion
-- .surface_ref) and the one it last stood on (.stood_ref): {from, to,
-- state, surface_index, tick, changed, arrived} when its surface changed
-- (changed) or it now stands on a surface it did not stand on last
-- (arrived: also after a pod brought it down while the surface change was
-- already seen in transit), else nil. The first sighting is recorded
-- without either. Only the physical surface counts: switching the remote
-- view to another surface raises on_player_changed_surface without moving
-- the body.
function M.note_body_surface()
  local rec = storage.companion
  if not rec then return nil end
  local body = M.body()
  if not body.surface_ref or body.state == "absent" or body.state == "disconnected" then return nil end
  local travel = storage.travel and storage.travel.active
  if travel and travel.cancelled and (body.state == "on_surface" or body.state == "aboard_platform") then
    storage.travel.active = nil
  end
  local from, stood = rec.surface_ref, rec.stood_ref
  rec.surface_ref = body.surface_ref
  local standing = body.state == "on_surface"
  if standing then rec.stood_ref = body.surface_ref
  elseif body.state == "in_transit" or body.state == "aboard_platform" then rec.stood_ref = nil end
  if from == nil then return nil end
  local changed = from ~= body.surface_ref
  local arrived = standing and stood ~= body.surface_ref
  if not (changed or arrived) then return nil end
  return { from = from, to = body.surface_ref, state = body.state, tick = game.tick, changed = changed,
    arrived = arrived, surface_index = read(function() return body.surface.index end) }
end

-- The map/minimap marker can't move, so re-pin it after the body drifts.
-- Runs on_nth_tick (wired in control.lua) and must never raise.
function M.update_map_tag()
  local rec = storage.companion
  if rec then
    local anchor = rec.entity and rec.entity.valid and M.body() or nil
    local ent = anchor and anchor.entity
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
      if not label_valid or rec.label_target ~= ent then attach_label(rec, ent) end

      local keep = false
      if tag_valid then
        local p = tag.position
        local dx, dy = p.x - ent.position.x, p.y - ent.position.y
        keep = dx * dx + dy * dy < MAP_TAG_MOVE_SQ and read(function() return tag.surface == ent.surface end) ~= false
        if not keep then pcall(function() tag.destroy() end) end
      end
      if not keep then
        rec.map_tag = nil
        pcall(function()
          rec.map_tag = anchor.force.add_chart_tag(ent.surface, {
            position = ent.position,
            text = CODEX_LABEL,
            icon = { type = "virtual", name = "signal-A" },
          })
        end)
      end
    end
  end
end

-- connect_status: the body's position and state. Aboard or in transit the
-- player is connected with the body away (the anchor's position).
function M.connect()
  local existing = M.get()
  if existing then
    return { position = { x = existing.position.x, y = existing.position.y }, body = M.body_summary() }
  end
  for _, player in pairs(game.connected_players) do
    if bind_native_player(player) and M.get() then
      local ent = player.character
      return { position = { x = ent.position.x, y = ent.position.y }, body = M.body_summary() }
    end
  end
  local body = M.body()
  if (body.state == "aboard_platform" or body.state == "in_transit") and body.position then
    return { position = body.position, body = M.body_summary() }
  end
  error("native player 'Codex' is not connected with a living character")
end

-- Kept for old control.lua/save rollback compatibility. Despite the legacy
-- name it only binds the native player and can never create a character.
M.spawn = M.connect

-- World policy: planets stay peaceful and generate no Nauvis enemy bases.
-- Init and configuration change visit every surface; on_surface_created
-- (event.surface_index) only the new one. A space platform's surface (or any
-- surface without a planet) gets no write at all (asteroids are its only resource), and Gleba's own enemy
-- bases (gleba_enemy_base) stay: their eggs are needed for agricultural
-- science. Vulcanus generates no demolishers (owner decision 7, V1): its
-- surface is written no-enemies when it is created, before any chunk
-- generates. Every write is its own pcall, never an error in the event that
-- created the surface; failures are kept in storage.world_policy.errors (the
-- last few), which ping shows.
local MAX_POLICY_ERRORS = 8
local function policy_error(surface, what, err)
  storage.world_policy = storage.world_policy or { errors = {} }
  local errors = storage.world_policy.errors
  local ok, name = pcall(function() return surface.name end)
  errors[#errors + 1] = { tick = game.tick, surface = ok and name or nil, write = what,
    error = plain_error(err) }
  while #errors > MAX_POLICY_ERRORS do table.remove(errors, 1) end
end

local function policy_write(surface, what, fn)
  local ok, err = pcall(fn)
  if not ok then policy_error(surface, what, err) end
end

-- Planets whose native enemies the run never needs: none generate there.
local NO_ENEMY_PLANETS = { vulcanus = true }

-- Only a planet's surface is written: not a platform's (whose platform may
-- not be attached yet when on_surface_created fires), nor any other.
local function surface_policy(surface)
  local ok, planet = pcall(function() return surface.platform == nil and surface.planet and surface.planet.name end)
  if not (ok and planet) then return end
  local no_enemies = NO_ENEMY_PLANETS[planet] == true
  policy_write(surface, "peaceful_mode", function() surface.peaceful_mode = true end)
  policy_write(surface, "map_gen_settings", function()
    local settings = surface.map_gen_settings
    settings.autoplace_controls = settings.autoplace_controls or {}
    settings.autoplace_controls["enemy-base"] = { frequency = 0, size = 0, richness = 0 }
    if no_enemies then settings.no_enemies_mode = true end
    surface.map_gen_settings = settings
  end)
  if no_enemies then policy_write(surface, "no_enemies_mode", function() surface.no_enemies_mode = true end) end
end

function M.enforce_peaceful_world(event)
  pcall(function() game.map_settings.enemy_expansion.enabled = false end)
  if type(event) == "table" and event.surface_index then
    local surface = game.surfaces[event.surface_index]
    if surface then surface_policy(surface) end
    return
  end
  for _, surface in pairs(game.surfaces) do surface_policy(surface) end
end

-- The last world-policy write failures, for ping (nil when there are none).
function M.world_policy_errors()
  local errors = storage.world_policy and storage.world_policy.errors
  return errors and #errors > 0 and errors or nil
end

return M
