-- A test stand-in for helpers.table_to_json: sequences are arrays, other
-- tables objects with sorted keys, so two encodings of equal data compare
-- as equal strings.
local function encode(value)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(c)
      return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" })[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if kind == "number" then return value % 1 == 0 and string.format("%d", value) or string.format("%.17g", value) end
  if kind == "boolean" then return tostring(value) end
  assert(kind == "table", "cannot encode a " .. kind)
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  local parts = {}
  if count > 0 and count == #value then
    for i = 1, #value do parts[i] = encode(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for i, key in ipairs(keys) do parts[i] = encode(tostring(key)) .. ":" .. encode(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
return encode
