-- The body-model reads (companion.anchor, require_present, surface_ref,
-- body_summary) for a test's companion stub whose body is a character
-- standing on its surface: body() returns that character or nil. A missing
-- or invalid character is no connected body (BODY_UNAVAILABLE).
return function(stub, body)
  -- As companion.surface_ref: "platform:<index>" for a platform's surface,
  -- else the surface's name.
  local function ref(surface)
    if surface == nil then return nil end
    local ok_platform, index = pcall(function() return surface.platform.index end)
    if ok_platform and index then return "platform:" .. index end
    local ok, name = pcall(function() return surface.name end)
    return ok and name or "nauvis"
  end
  local function present()
    local c = body()
    if not (c and c.valid ~= false) then return nil end
    return { state = "on_surface", force = c.force, surface = c.surface, surface_ref = ref(c.surface) or "nauvis",
      position = c.position and { x = c.position.x, y = c.position.y } or nil, character = c }
  end
  stub.surface_ref = stub.surface_ref or ref
  stub.anchor = function()
    local b = present()
    return b and { surface = b.surface, position = b.position, force = b.force, state = b.state,
      surface_ref = b.surface_ref } or nil
  end
  stub.require_present = function()
    local b = present()
    if not b then error("BODY_UNAVAILABLE: companion 'Codex' does not exist (no connected Codex player)", 0) end
    return b
  end
  stub.body_summary = stub.body_summary or function()
    local b = present()
    return { state = b and b.state or "absent", surface_ref = b and b.surface_ref }
  end
  stub.get = stub.get or body
  return stub
end
