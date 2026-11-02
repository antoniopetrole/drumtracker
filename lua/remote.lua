-- remote.lua: publishes a snapshot of the scores for web/drums.html, which reads
-- it through REAPER's web interface. No REAPER dependency: tests call build().

local Metrics = require("metrics")
local Timing = require("timing")

local R = {}

R.SECTION = "LiveDrumGrooveMonitor"
R.KEY_SNAPSHOT = "snapshot"
R.KEY_COMMAND = "command"
R.MAX_POINTS = 32
R.PUBLISH_INTERVAL_S = 1 / 15

function R.visible_lanes(session, config)
  local out = {}
  for i = 1, 8 do
    local lane = session.lanes[i]
    if i <= 3 or lane.alive or #config.lanes[i].steps > 0 then out[#out + 1] = lane end
  end
  return out
end

-- Returns state ("none" | "bad" | "idle" | "live") and a message for the user.
function R.lane_state(lane, instances, playing)
  if not lane.alive then
    if #instances > 0 then return "bad", "Detector not running (bypassed, or audio engine stopped?)" end
    return "none", "No detector on this lane"
  end
  if lane.status and lane.status.duplicate > 0 then return "bad", "Two detectors share this lane" end
  if not playing then return "idle", "Transport stopped: press play" end
  return "live", nil
end

local function encode_string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

-- Undefined stays null, so the page can never show silence as a perfect 0 ms.
local function encode(value)
  local t = type(value)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(value) end
  if t == "string" then return encode_string(value) end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    if math.type(value) == "integer" then return tostring(value) end
    local text = string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
    return text == "-0" and "0" or text
  end
  if value.__array then
    local parts = {}
    for i = 1, value.__array do parts[i] = encode(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for k, v in pairs(value) do
    if k ~= "__array" then parts[#parts + 1] = encode_string(k) .. ":" .. encode(v) end
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end
R.encode = encode

local function array(list)
  list.__array = #list
  return list
end

local function meter_fraction(linear)
  if not linear or linear < 1e-7 then return 0 end
  return math.max(0, math.min(1, (20 * math.log(linear, 10) + 70) / 70))
end

local function color_hex(rgba)
  return string.format("#%06X", (rgba >> 8) & 0xFFFFFF)
end

-- app: session, config, status, now. seq proves to the page that we're alive.
function R.build(app, seq)
  local config, status = app.config, app.status
  local transport = status.transport
  local now = app.now()

  local lanes = {}
  local uncalibrated, selftest = {}, {}
  local alive_count = 0
  for _, lane in ipairs(R.visible_lanes(app.session, config)) do
    local lc = config.lanes[lane.index]
    local state, message = R.lane_state(lane, status.detectors[lane.index], transport.playing)
    local stats = app.session:stats(lane)
    local alive_status = lane.alive and lane.status or nil

    if lane.alive then
      alive_count = alive_count + 1
      if not lc.calibrated then uncalibrated[#uncalibrated + 1] = lc.name end
      if alive_status and alive_status.selftest > 0 then selftest[#selftest + 1] = lc.name end
    end

    local points = {}
    for i, e in ipairs(Metrics.latest(lane.history, R.MAX_POINTS)) do points[i] = e.corrected_ms end

    local latest
    if lane.latest then
      latest = {
        ms = lane.latest.corrected_ms,
        word = Timing.classify(lane.latest.corrected_ms, config.on_time_ms),
        text = Timing.format_ms(lane.latest.corrected_ms),
      }
    end

    lanes[#lanes + 1] = {
      index = lane.index,
      name = lc.name,
      color = color_hex(lc.color),
      scoring = lc.scoring,
      state = state,
      message = message,
      level = alive_status and meter_fraction(alive_status.level) or nil,
      threshold = alive_status and meter_fraction(alive_status.threshold) or nil,
      triggers = alive_status and math.floor(alive_status.trigger_total) or nil,
      latest = latest,
      n = stats.n,
      bias = stats.mean,
      spread = stats.sd,
      mae = stats.mae,
      pct10 = stats.pct10,
      pct20 = stats.pct20,
      detected = lane.counts.detected,
      hits = lane.counts.hits,
      misses = lane.counts.misses,
      extras = lane.counts.extras,
      points = array(points),
    }
  end

  local newest
  for _, lane in ipairs(app.session.lanes) do
    if lane.last_event_at and (not newest or lane.last_event_at > newest) then newest = lane.last_event_at end
  end

  return encode({
    version = 1,
    seq = seq,
    transport = transport.label,
    playing = transport.playing,
    bar = transport.bar,
    beat = transport.beat,
    metronome = transport.metronome,
    bpm = status.bpm,
    project_ok = status.project_ok,
    project_reason = status.project_reason,
    scoring_enabled = config.scoring_enabled,
    tolerance = config.tolerance_ms,
    range = math.max(50, config.tolerance_ms * 2.5),
    last_hit_age = newest and (now - newest) or nil,
    detectors = alive_count,
    uncalibrated = array(uncalibrated),
    selftest = array(selftest),
    lanes = array(lanes),
  })
end

return R
