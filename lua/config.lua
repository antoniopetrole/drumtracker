-- config.lua: settings defaults, validation and a human-readable file format.
-- Files are plain Lua table literals, loaded text-only in an empty environment
-- and then validated field by field, so a bad value falls back, not crashes.

local Patterns = require("patterns")

local C = {}

C.WINDOW_MODES = { "hits16", "hits32", "hits64", "bars4", "bars8", "bars16" }
C.WINDOW_LABELS = { "Last 16 hits", "Last 32 hits", "Last 64 hits", "Last 4 bars", "Last 8 bars", "Last 16 bars" }

local DEFAULT_NAMES = { "Kick", "Snare", "Hi-hat", "Lane 4", "Lane 5", "Lane 6", "Lane 7", "Lane 8" }
local DEFAULT_COLORS = {
  0xD9663CFF, 0x3A97D4FF, 0xB08C1CFF, 0x7BD17BFF, 0xC58AE8FF, 0x4AD6C2FF, 0xE88AB5FF, 0xB0B0B0FF,
}

function C.defaults()
  local cfg = {
    version = 1,
    window_mode = "hits32",
    match_window_ms = 80,
    tolerance_ms = 20,
    on_time_ms = 5,
    origin_bar = 1,
    scoring_enabled = true,
    lanes = {},
  }
  for i = 1, 8 do
    local steps = {}
    if i == 1 then steps = Patterns.to_steps(Patterns.default_kick())
    elseif i == 2 then steps = Patterns.to_steps(Patterns.default_snare())
    elseif i == 3 then steps = Patterns.to_steps(Patterns.default_hat()) end
    cfg.lanes[i] = {
      name = DEFAULT_NAMES[i],
      steps = steps,
      scoring = i <= 3,
      calibration_ms = 0,
      calibrated = false, -- set once the user applies a calibration on purpose
      color = DEFAULT_COLORS[i],
    }
  end
  return cfg
end

local function num(v, lo, hi, default)
  if type(v) ~= "number" or v ~= v then return default end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function C.sanitize(raw)
  local d = C.defaults()
  if type(raw) ~= "table" then return d end

  for _, m in ipairs(C.WINDOW_MODES) do
    if raw.window_mode == m then d.window_mode = m end
  end
  d.match_window_ms = num(raw.match_window_ms, 5, 200, d.match_window_ms)
  d.tolerance_ms = num(raw.tolerance_ms, 1, 100, d.tolerance_ms)
  d.on_time_ms = num(raw.on_time_ms, 0, 50, d.on_time_ms)
  d.origin_bar = math.floor(num(raw.origin_bar, 1, 100000, d.origin_bar))
  if type(raw.scoring_enabled) == "boolean" then d.scoring_enabled = raw.scoring_enabled end

  if type(raw.lanes) == "table" then
    for i = 1, 8 do
      local src, dst = raw.lanes[i], d.lanes[i]
      if type(src) == "table" then
        if type(src.name) == "string" and #src.name > 0 then dst.name = src.name:sub(1, 32) end
        if type(src.scoring) == "boolean" then dst.scoring = src.scoring end
        if type(src.calibrated) == "boolean" then dst.calibrated = src.calibrated end
        dst.calibration_ms = num(src.calibration_ms, -500, 500, 0)
        dst.color = math.floor(num(src.color, 0, 0xFFFFFFFF, dst.color))
        if type(src.steps) == "table" then
          local p = Patterns.empty()
          for _, s in ipairs(src.steps) do
            if type(s) == "number" and s >= 0 and s < Patterns.STEPS and s == math.floor(s) then
              p[math.floor(s)] = true
            end
          end
          dst.steps = Patterns.to_steps(p)
        end
      end
    end
  end
  return d
end

local function serialize(value, indent)
  local t = type(value)
  if t == "string" then return string.format("%q", value) end
  if t == "number" then
    if value == math.floor(value) and math.abs(value) < 2^53 then
      return string.format("%d", value)
    end
    return string.format("%.17g", value)
  end
  if t == "boolean" then return tostring(value) end
  if t ~= "table" then error("cannot serialize " .. t) end

  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  if #keys == 0 then return "{}" end

  local pad = indent .. "  "
  local parts = {}
  local flat = type(value[1]) == "number"
  for _, k in ipairs(keys) do
    local v = serialize(value[k], pad)
    if type(k) == "number" then parts[#parts + 1] = flat and v or (pad .. v)
    else parts[#parts + 1] = pad .. k .. " = " .. v end
  end
  if flat then return "{ " .. table.concat(parts, ", ") .. " }" end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

function C.encode(cfg)
  return "-- Live Drum Groove Monitor settings. Safe to edit by hand.\nreturn "
    .. serialize(cfg, "") .. "\n"
end

function C.decode(text)
  if type(text) ~= "string" or text:sub(1, 1) == "\27" then
    return nil, "not a settings file"
  end
  local chunk, err = load(text, "settings", "t", {})
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok then return nil, value end
  return C.sanitize(value)
end

function C.save_file(path, cfg)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(C.encode(cfg))
  f:close()
  return true
end

function C.load_file(path)
  local f = io.open(path, "r")
  if not f then return nil, "not found" end
  local text = f:read("a")
  f:close()
  return C.decode(text)
end

return C
