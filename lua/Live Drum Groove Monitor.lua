-- @description Live Drum Groove Monitor
-- @about Live per-drum timing feedback while playing to REAPER's click.
--
-- REAPER action entry point. Needs the ReaImGui extension, and the Live Drum
-- Onset Detector JSFX on each monitored track.

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
package.path = script_dir .. "?.lua;" .. package.path

local REAIMGUI_HELP = [[
Live Drum Groove Monitor needs the ReaImGui extension, version 0.10 or newer.

To install it:
1. Install ReaPack from https://reapack.com (copy its DLL into REAPER's UserPlugins folder, restart REAPER).
2. Extensions > ReaPack > Browse packages.
3. Search "ReaImGui", right-click it, Install, then Apply.
4. Restart REAPER and run this action again.]]

local function load_imgui()
  if not reaper.ImGui_GetBuiltinPath then return nil, "ReaImGui is not installed, or is older than 0.9." end
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local ok, loader = pcall(require, "imgui")
  if not ok then return nil, "ReaImGui's imgui.lua was not found. Install ReaImGui through ReaPack, not by copying the DLL." end
  local ok_version, ImGui = pcall(loader, "0.10")
  if not ok_version then return nil, "Your ReaImGui is too old: " .. tostring(ImGui) end
  return ImGui
end

local ImGui, imgui_problem = load_imgui()
if not ImGui then
  reaper.MB(imgui_problem .. "\n\n" .. REAIMGUI_HELP, "Live Drum Groove Monitor", 0)
  return
end

local Protocol = require("protocol")
local Session = require("session")
local Config = require("config")
local Metrics = require("metrics")
local Bridge = require("bridge")
local Remote = require("remote")
local Library = require("library")
local UI = require("ui")

-- Settings live with the REAPER install, not a project: they describe your kit.
local data_dir = reaper.GetResourcePath() .. "/Data/LiveDrumGrooveMonitor"
local preset_dir = data_dir .. "/presets"
local settings_path = data_dir .. "/settings.lua"
local grooves_path = data_dir .. "/grooves.lua"
reaper.RecursiveCreateDirectory(preset_dir, 0)

local config = Config.load_file(settings_path) or Config.defaults()

reaper.gmem_attach(Protocol.NAMESPACE)

local function now() return reaper.time_precise() end
local function qn_to_time(qn) return reaper.TimeMap2_QNToTime(0, qn) end

local session = Session.new({
  read = reaper.gmem_read,
  qn_to_time = qn_to_time,
  clock = now,
  config = config,
})

local status = {
  detectors = {},
  transport = Bridge.transport(),
  project_ok = true,
  project_reason = nil,
  bpm = nil,
  protocol_mismatch = false,
}
for i = 1, 8 do status.detectors[i] = {} end

local function load_grooves()
  local f = io.open(grooves_path, "r")
  if not f then return {} end
  local text = f:read("a")
  f:close()
  return Library.sanitize_user(Config.parse(text))
end

local user_grooves = load_grooves()

local dirty = false
local dirty_at = 0

local function mark_dirty()
  dirty = true
  dirty_at = now()
end

local app = {
  session = session,
  config = config,
  status = status,
  now = now,
  mark_dirty = mark_dirty,
  library_rev = 1,
}

function app.config_changed()
  session:config_changed()
  mark_dirty()
end

-- Bias measured under the old calibration is stale once it changes.
function app.calibration_applied(lane)
  lane.history = Metrics.new_history()
  lane.latest = nil
  app.config_changed()
end

function app.latest_hits(lane, n)
  return Metrics.latest(lane.history, n)
end

local function clean_preset_name(name)
  return (name:gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function app.save_preset(name)
  name = clean_preset_name(name)
  if name == "" then return "Give the preset a name first." end
  local ok, err = Config.save_file(preset_dir .. "/" .. name .. ".lua", config)
  if not ok then return "Could not save preset: " .. tostring(err) end
  return "Saved preset " .. name
end

function app.load_preset(name)
  local loaded, err = Config.load_file(preset_dir .. "/" .. name .. ".lua")
  if not loaded then return "Could not load preset: " .. tostring(err) end
  -- The session holds this same table; update it in place.
  for k in pairs(config) do config[k] = nil end
  for k, v in pairs(loaded) do config[k] = v end
  session:reset()
  mark_dirty()
  return "Loaded preset " .. name
end

function app.list_presets()
  local out = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(preset_dir, i)
    if not file then break end
    local name = file:match("^(.*)%.lua$")
    if name then out[#out + 1] = name end
    i = i + 1
  end
  table.sort(out)
  return out
end

function app.create_tracks()
  local names = {}
  for i = 1, 3 do names[i] = config.lanes[i].name end
  local answer = reaper.MB(
    "Add three new tracks (" .. table.concat(names, ", ") .. ") to the end of this project?\n\n"
    .. "Each gets the detector, a mono input (1, 2, 3), record-arm and input monitoring, "
    .. "in monitoring-only record mode so nothing is ever recorded.\n\n"
    .. "Existing tracks, routing and tempo are not changed. Ctrl+Z undoes this.",
    "Live Drum Groove Monitor", 4)
  if answer ~= 6 then return "No tracks added." end
  local ok, result = Bridge.create_lane_tracks(names)
  if not ok then return result end
  return string.format("Added %d tracks. Check their inputs match your interface.", result)
end

function app.pattern_groups()
  return Library.groups(user_grooves)
end

function app.has_user_groove(name)
  return Library.find_user(user_grooves, Library.clean_name(name)) ~= nil
end

local function snapshot_pattern()
  local saved = {}
  for i = 1, Library.LANES do
    local lane = config.lanes[i]
    saved[i] = { steps = lane.steps, accents = lane.accents, ghosts = lane.ghosts, scoring = lane.scoring }
  end
  return { lanes = saved, active = config.active_pattern }
end

-- Old stats describe a different pattern, so a change of pattern starts fresh.
local function pattern_loaded()
  session:reset()
  mark_dirty()
end

function app.load_pattern(id)
  local before = snapshot_pattern()
  local ok, err = Library.apply(config, id, user_grooves)
  if not ok then return err end
  app.previous_pattern = before
  pattern_loaded()
  return "Loaded " .. config.active_pattern.name
end

function app.undo_pattern()
  local p = app.previous_pattern
  if not p then return end
  for i = 1, Library.LANES do
    local lane = config.lanes[i]
    lane.steps, lane.accents, lane.ghosts = p.lanes[i].steps, p.lanes[i].accents, p.lanes[i].ghosts
    lane.scoring = p.lanes[i].scoring
  end
  config.active_pattern = p.active
  app.previous_pattern = nil
  pattern_loaded()
  return "Restored " .. config.active_pattern.name
end

function app.set_rudiment_lane(lane)
  config.rudiment_lane = lane
  local active = config.active_pattern
  if active.sticking and not active.modified and active.id then
    Library.apply(config, active.id, user_grooves)
    pattern_loaded()
  else
    mark_dirty()
  end
end

function app.pattern_edited()
  Library.mark_modified(config)
  app.config_changed()
end

local function save_grooves()
  local ok, err = Config.save_file(grooves_path, user_grooves)
  app.library_rev = app.library_rev + 1
  if not ok then return "Could not save grooves: " .. tostring(err) end
end

function app.save_groove(name)
  local saved, err = Library.save_user(config, user_grooves, name)
  if not saved then return err end
  mark_dirty()
  return save_grooves() or ("Saved groove " .. saved)
end

function app.delete_groove(name)
  if not Library.delete_user(config, user_grooves, name) then return "No such groove" end
  mark_dirty()
  return save_grooves() or ("Deleted groove " .. name)
end

local ui = UI.new(ImGui, app)

local next_slow_check = 0
local last_bpm

local function slow_checks()
  status.detectors = Bridge.scan_detectors()
  status.protocol_mismatch = Protocol.version_mismatch(reaper.gmem_read)

  local ok, reason, bpm = Bridge.check_project()
  status.project_ok, status.project_reason, status.bpm = ok, reason, bpm
  local tempo_changed = last_bpm and math.abs(bpm - last_bpm) > 1e-9
  last_bpm = bpm
  if ok ~= session.scoring_allowed or tempo_changed then
    session.scoring_allowed = ok
    session:config_changed() -- targets were computed from the old tempo
  end
end

local function save_now()
  if dirty then
    Config.save_file(settings_path, config)
    dirty = false
  end
end

local publish_seq = 0
local next_publish = 0
local published_library_rev

-- Feeds web/drums.html. Non-persistent ExtState: gone when REAPER closes.
local function publish_remote(t)
  if t < next_publish then return end
  next_publish = t + Remote.PUBLISH_INTERVAL_S
  local command = reaper.GetExtState(Remote.SECTION, Remote.KEY_COMMAND)
  if command ~= "" then
    reaper.DeleteExtState(Remote.SECTION, Remote.KEY_COMMAND, false)
    if command == "reset" then
      session:reset()
    else
      local id = command:match("^load:(.+)$")
      if id then ui.message = app.load_pattern(id) end
    end
  end
  if published_library_rev ~= app.library_rev then
    published_library_rev = app.library_rev
    reaper.SetExtState(Remote.SECTION, Remote.KEY_LIBRARY,
      Remote.build_library(app.pattern_groups(), app.library_rev), false)
  end
  publish_seq = publish_seq + 1
  reaper.SetExtState(Remote.SECTION, Remote.KEY_SNAPSHOT, Remote.build(app, publish_seq), false)
end

local function loop()
  local t = now()
  if t >= next_slow_check then
    slow_checks()
    next_slow_check = t + 0.5
  end
  status.transport = Bridge.transport()

  reaper.gmem_write(Protocol.G_UI_HEARTBEAT, t)
  session:tick()
  publish_remote(t)

  if dirty and t - dirty_at > 1 then save_now() end

  if ui:frame() then reaper.defer(loop) end
end

reaper.atexit(function()
  save_now()
  reaper.DeleteExtState(Remote.SECTION, Remote.KEY_SNAPSHOT, false)
  reaper.DeleteExtState(Remote.SECTION, Remote.KEY_LIBRARY, false)
end)
-- A reset tapped while the dashboard was closed must not fire on the next open.
reaper.DeleteExtState(Remote.SECTION, Remote.KEY_COMMAND, false)
slow_checks()
reaper.defer(loop)
