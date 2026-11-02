-- bridge.lua: everything that asks REAPER about the project. Read-only, except
-- for the explicit, user-confirmed helpers at the bottom.

local Timing = require("timing")

local B = {}

B.FX_MATCH = "Live Drum Onset Detector"
B.FX_ADD_NAME = "JS:LiveDrumGrooveMonitor/Live Drum Onset Detector.jsfx"

-- JSFX slider order == TrackFX parameter index
B.PARAM_LANE = 0
B.PARAM_THRESHOLD = 2
B.PARAM_RETRIG = 4
B.PARAM_ST_MODE = 11
B.PARAM_ST_OFFSET = 12

local METRONOME_TOGGLE = 40364

-- Finds every detector instance. Returns by_lane[1..8] = list of instances.
function B.scan_detectors()
  local by_lane = {}
  for i = 1, 8 do by_lane[i] = {} end
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    local _, track_name = reaper.GetTrackName(track)
    for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
      local _, fx_name = reaper.TrackFX_GetFXName(track, fx)
      if fx_name:find(B.FX_MATCH, 1, true) then
        local lane = math.floor(reaper.TrackFX_GetParam(track, fx, B.PARAM_LANE) + 0.5)
        if by_lane[lane] then
          table.insert(by_lane[lane], {
            track = track,
            fx = fx,
            track_name = track_name,
            track_number = ti + 1,
            enabled = reaper.TrackFX_GetEnabled(track, fx),
            armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1,
            monitor = reaper.GetMediaTrackInfo_Value(track, "I_RECMON"),
            input = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT"),
            threshold_db = reaper.TrackFX_GetParam(track, fx, B.PARAM_THRESHOLD),
            retrig_ms = reaper.TrackFX_GetParam(track, fx, B.PARAM_RETRIG),
            st_mode = reaper.TrackFX_GetParam(track, fx, B.PARAM_ST_MODE),
            st_offset = reaper.TrackFX_GetParam(track, fx, B.PARAM_ST_OFFSET),
          })
        end
      end
    end
  end
  return by_lane
end

function B.set_param(inst, param, value)
  if inst and reaper.ValidatePtr2(0, inst.track, "MediaTrack*") then
    reaper.TrackFX_SetParam(inst.track, inst.fx, param, value)
  end
end

-- Human name for I_RECINPUT, 1-based like REAPER's own menu.
function B.input_label(input)
  if input < 0 then return "No input" end
  if input & 4096 ~= 0 then return "MIDI (no audio!)" end
  local ch = (input & 1023) + 1
  if input & 2048 ~= 0 then return string.format("Multichannel from %d", ch) end
  if input & 1024 ~= 0 then return string.format("Stereo %d/%d", ch, ch + 1) end
  return string.format("Mono %d", ch)
end

-- Can this version score the active project? Returns ok, reason, bpm.
function B.check_project()
  local num, denom, bpm = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  local markers = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
    local _, _, _, _, m_bpm, ts_num, ts_denom, linear = reaper.GetTempoTimeSigMarker(0, i)
    markers[#markers + 1] = { bpm = m_bpm, ts_num = ts_num, ts_denom = ts_denom, linear = linear }
  end
  local ok, reason = Timing.check_project_map(bpm, num, denom, markers)
  if ok then
    local rate = reaper.Master_GetPlayRate(0)
    if math.abs(rate - 1) > 1e-6 then
      ok, reason = false, string.format("Project playrate is %.2fx; set it to 1.0", rate)
    end
  end
  return ok, reason, bpm
end

function B.transport()
  local state = reaper.GetPlayState()
  local label = "Stopped"
  if state & 4 ~= 0 then label = "Recording"
  elseif state & 2 ~= 0 then label = "Paused"
  elseif state & 1 ~= 0 then label = "Playing" end
  local pos = (state & 1 ~= 0) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local _, measures, _, fullbeats = reaper.TimeMap2_timeToBeats(0, pos)
  local beat_in_bar = fullbeats - math.floor(fullbeats / 4) * 4
  return {
    label = label,
    playing = state & 1 ~= 0,
    bar = (measures or 0) + 1,
    beat = beat_in_bar + 1,
    metronome = reaper.GetToggleCommandState(METRONOME_TOGGLE) == 1,
  }
end

-- REAPER-reported round trip, in ms. A hit played dead on the click the player
-- hears reaches the detector this much after the transport position of that
-- click. A starting point for calibration, not a measurement.
function B.reported_latency_ms()
  local input, output = reaper.GetInputOutputLatency()
  local srate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  local _, device_rate = reaper.GetAudioDeviceInfo("SRATE")
  device_rate = tonumber(device_rate)
  if device_rate and device_rate > 0 then srate = device_rate end
  if not srate or srate <= 0 then return nil end
  return (input + output) * 1000 / srate, input, output
end

function B.toggle_metronome()
  reaper.Main_OnCommand(METRONOME_TOGGLE, 0)
end

-- Opt-in, undoable, additive: appends new tracks and touches nothing else.
-- Monitoring-only record mode means the tracks can never record a take.
function B.create_lane_tracks(lane_names)
  local created = 0
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for lane, name in ipairs(lane_names) do
    local index = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(index, true)
    local track = reaper.GetTrack(0, index)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
    local fx = reaper.TrackFX_AddByName(track, B.FX_ADD_NAME, false, -1)
    if fx < 0 then
      reaper.DeleteTrack(track)
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Live Drum Groove Monitor: create lane tracks (failed)", -1)
      return false, "Could not load the detector. Is it installed in Effects/LiveDrumGrooveMonitor/?"
    end
    reaper.TrackFX_SetParam(track, fx, B.PARAM_LANE, lane)
    reaper.SetMediaTrackInfo_Value(track, "I_RECINPUT", lane - 1) -- mono hardware input
    reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", 2)         -- monitoring only
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
    created = created + 1
  end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Live Drum Groove Monitor: create lane tracks", -1)
  return true, created
end

return B
