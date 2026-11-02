-- Integration test that runs INSIDE REAPER, against the real JSFX and audio
-- engine, with no audio interface input. It deletes every track in the open
-- project, so only ever run it through tools/run_rig.py, which gives it a
-- throwaway resource directory and the Dummy Audio device.
--
-- Set LDGM_RESULTS to the results path, or it writes next to this script.
-- Set LDGM_SCREENSHOT=1 to leave the dashboard open at the end.

local dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])")
local base = dir .. "LiveDrumGrooveMonitor/"
package.path = base .. "?.lua;" .. package.path

local Protocol = require("protocol")
local Session = require("session")
local Config = require("config")
local Metrics = require("metrics")
local Bridge = require("bridge")

local results_path = os.getenv("LDGM_RESULTS") or (dir .. "ldgm_results.txt")
assert(io.open(results_path, "w")):close()
local failures = 0

local function log(s)
  local out = assert(io.open(results_path, "a"))
  out:write(s, "\n")
  out:close()
end

local function check(name, ok, detail)
  if not ok then failures = failures + 1 end
  log(string.format("%s  %s%s", ok and "PASS" or "FAIL", name, detail and ("  [" .. tostring(detail) .. "]") or ""))
end

local function near(name, actual, expected, tol)
  local ok = actual ~= nil and math.abs(actual - expected) <= tol
  check(name, ok, string.format("expected %.3f +/- %.3f, got %s", expected, tol, tostring(actual)))
end

-- Scenario helpers -----------------------------------------------------------

reaper.gmem_attach(Protocol.NAMESPACE)

local function wipe_project()
  reaper.Main_OnCommand(1016, 0) -- stop
  for i = reaper.CountTracks(0) - 1, 0, -1 do
    reaper.DeleteTrack(reaper.GetTrack(0, i))
  end
  reaper.GetSetRepeat(0)
  reaper.SetEditCurPos(0, true, false)
end

local function add_detector(name, lane, threshold_db)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  local fx = reaper.TrackFX_AddByName(track, Bridge.FX_ADD_NAME, false, -1)
  assert(fx >= 0, "JSFX failed to load")
  reaper.TrackFX_SetParam(track, fx, Bridge.PARAM_LANE, lane)
  if threshold_db then reaper.TrackFX_SetParam(track, fx, Bridge.PARAM_THRESHOLD, threshold_db) end
  return track, fx
end

local function self_test(track, fx, mode, offset)
  reaper.TrackFX_SetParam(track, fx, Bridge.PARAM_ST_MODE, mode)
  reaper.TrackFX_SetParam(track, fx, Bridge.PARAM_ST_OFFSET, offset)
end

local function write_impulse_wav(path, srate, seconds, times)
  local n = math.floor(srate * seconds)
  local data = {}
  for i = 1, n do data[i] = 0 end
  for _, t in ipairs(times) do
    local start = math.floor(t * srate + 0.5)
    for k = 0, math.floor(0.02 * srate) do
      -- decaying sine: a drum-ish attack, not a one-sample click
      local a = 0.8 * math.exp(-k / (0.004 * srate)) * math.sin(2 * math.pi * 800 * k / srate + 1.2)
      if start + k + 1 <= n then data[start + k + 1] = a end
    end
  end
  local f = assert(io.open(path, "wb"))
  f:write("RIFF", string.pack("<I4", 36 + n * 4), "WAVE")
  f:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, 1, srate, srate * 4, 4, 32))
  f:write("data", string.pack("<I4", n * 4))
  for i = 1, n do f:write(string.pack("<f", data[i])) end
  f:close()
end

local function new_session(mutate)
  local cfg = Config.defaults()
  if mutate then mutate(cfg) end
  local s = Session.new({
    read = reaper.gmem_read,
    qn_to_time = function(q) return reaper.TimeMap2_QNToTime(0, q) end,
    clock = reaper.time_precise,
    config = cfg,
  })
  return s, cfg
end

local function all_hits(lane)
  return Metrics.latest(lane.history, Metrics.CAPACITY)
end

-- Sequencer: steps run in order; each returns a wait in seconds or nil -----------

local aborted = false
local steps = {}
local function step(wait, fn) steps[#steps + 1] = { wait = wait, fn = fn } end

local session, cfg, tick_session

local function start_transport()
  reaper.SetEditCurPos(0, true, false)
  reaper.Main_OnCommand(1007, 0)
end

-- 1: basic environment and gmem precision ------------------------------------
local snare_track, snare_fx, kick_track, kick_fx, hat_track, hat_fx

step(0.2, function()
  log("RESOURCE_PATH=" .. reaper.GetResourcePath())
  log("REAPER " .. reaper.GetAppVersion())
  log("ImGui_GetBuiltinPath: " .. tostring(reaper.ImGui_GetBuiltinPath))
  log("ImGui_CreateContext: " .. tostring(reaper.ImGui_CreateContext))
  if reaper.ImGui_GetBuiltinPath then
    local path = reaper.ImGui_GetBuiltinPath()
    log("builtin path: " .. tostring(path))
    local probe = package.path
    package.path = path .. "/?.lua;" .. package.path
    local ok, loader = pcall(require, "imgui")
    log("require imgui: " .. tostring(ok) .. " " .. tostring(loader))
    if ok then log("loader 0.10: " .. tostring(select(2, pcall(loader, "0.10")))) end
    package.path = probe
  end
  local _, mode = reaper.GetAudioDeviceInfo("MODE")
  log("audio device mode: " .. tostring(mode))
  -- Test impulses must never reach real speakers.
  reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "B_MUTE", 1)
  if tostring(mode):upper():find("ASIO") then
    log("ABORT: refusing to run on an ASIO device")
    local f = io.open(results_path .. ".done", "w")
    if f then f:close() end
    aborted = true
    reaper.Main_OnCommand(40004, 0) -- quit
    return
  end
  local _, _, bpm = Bridge.check_project()
  log("project bpm before test: " .. tostring(bpm))
  wipe_project()
  reaper.SetCurrentBPM(0, 120, false)
  local ok, reason = Bridge.check_project()
  check("empty project passes the 4/4 constant-tempo check", ok, reason)
  near("TimeMap2_QNToTime(2) at 120 BPM", reaper.TimeMap2_QNToTime(0, 2), 1.0, 1e-9)
  kick_track, kick_fx = add_detector("Kick", 1)
  snare_track, snare_fx = add_detector("Snare", 2)
  hat_track, hat_fx = add_detector("Hi-hat", 3)
  self_test(kick_track, kick_fx, 1, 0)
  self_test(snare_track, snare_fx, 2, 15)
  self_test(hat_track, hat_fx, 3, -20)
end)

step(2.0, function()
  check("JSFX wrote the protocol header", Protocol.is_initialised(reaper.gmem_read))
  local found = Bridge.scan_detectors()
  check("scan finds lane 1", #found[1] == 1)
  check("scan finds lane 2", #found[2] == 1)
  check("scan finds lane 3", #found[3] == 1)
  session, cfg = new_session()
end)

-- 2: self-test pulses through the whole path --------------------------------
step(0.1, function()
  start_transport()
end)

step(8.5, function()
  for i = 0, 2 do
    local st = Protocol.read_lane_status(reaper.gmem_read, i)
    check("lane " .. (i + 1) .. " owner heartbeat running", st and st.heartbeat > 0, st and st.heartbeat)
  end
  reaper.Main_OnCommand(1016, 0)
end)

step(0.3, function()
  local sr = reaper.gmem_read(Protocol.lane_base(1) + Protocol.H_SRATE)
  local block = reaper.gmem_read(Protocol.lane_base(1) + Protocol.H_SAMPLESBLOCK)
  log(string.format("srate %d, block %d", sr, block))
  local sample_ms = 1000 / sr

  local snare = session.lanes[2]
  local s = Metrics.compute(all_hits(snare))
  log(string.format("snare: n=%d mean=%.4f sd=%s miss=%d extra=%d", s.n, s.mean or 0, tostring(s.sd), snare.counts.misses, snare.counts.extras))
  check("snare self-test +15 ms produced hits", s.n >= 6, s.n)
  near("snare +15 ms measures +15", s.mean, 15, sample_ms * 1.5)
  check("snare spread under a sample or two", s.sd and s.sd < sample_ms * 2, s.sd)
  check("snare no extras", snare.counts.extras == 0, snare.counts.extras)
  check("snare no misses", snare.counts.misses == 0, snare.counts.misses)

  local hat = session.lanes[3]
  s = Metrics.compute(all_hits(hat))
  log(string.format("hat: n=%d mean=%.4f sd=%s miss=%d extra=%d", s.n, s.mean or 0, tostring(s.sd), hat.counts.misses, hat.counts.extras))
  check("hat -20 ms produced hits", s.n >= 24, s.n)
  near("hat -20 ms measures -20, not +20", s.mean, -20, sample_ms * 1.5)
  check("hat no extras", hat.counts.extras == 0, hat.counts.extras)
  -- Exactly one miss: a pulse 20 ms before beat 1 can't exist when the transport
  -- starts on beat 1, so the very first note truly has no hit.
  check("hat misses only the unplayable first note", hat.counts.misses == 1, hat.counts.misses)

  local kick = session.lanes[1]
  s = Metrics.compute(all_hits(kick))
  log(string.format("kick: n=%d mean=%.4f sd=%s miss=%d extra=%d", s.n, s.mean or 0, tostring(s.sd), kick.counts.misses, kick.counts.extras))
  near("kick 0 ms measures 0", s.mean, 0, sample_ms * 1.5)
  check("kick no misses", kick.counts.misses == 0, kick.counts.misses)

  -- Not quantised to blocks: hits land across block offsets, and spread stays
  -- sample-sized rather than block-sized.
  check("spread is far below block size", (Metrics.compute(all_hits(snare)).sd or 1e9) < (block / sr * 1000) / 4)
  local offsets = session.offset_log or {}
  local distinct, seen = 0, {}
  for _, o in ipairs(offsets) do
    if not seen[o] then seen[o] = true; distinct = distinct + 1 end
  end
  log(string.format("hat sample offsets seen: %d events, %d distinct values (block %d)", #offsets, distinct, block))
  check("hit offsets vary inside blocks: not block-quantised", distinct >= 4, distinct)
end)

-- 3: a loop wrap ---------------------------------------------------------------
local loop_counts
step(0.1, function()
  session:reset()
  session.offset_log = {}
  reaper.GetSet_LoopTimeRange(true, true, 0, 2, false)
  reaper.GetSetRepeat(1)
  start_transport()
end)

step(9.0, function()
  reaper.Main_OnCommand(1016, 0)
  reaper.GetSetRepeat(0)
end)

step(0.3, function()
  local snare, hat, kick = session.lanes[2], session.lanes[3], session.lanes[1]
  local s = Metrics.compute(all_hits(snare))
  local sr = reaper.gmem_read(Protocol.lane_base(1) + Protocol.H_SRATE)
  log(string.format("loop snare: n=%d mean=%.4f sd=%s miss=%d extra=%d det=%d", s.n, s.mean or 0, tostring(s.sd), snare.counts.misses, snare.counts.extras, snare.counts.detected))
  check("loop: each detected snare scored once", snare.counts.hits == snare.counts.detected, snare.counts.hits .. "/" .. snare.counts.detected)
  check("loop: several passes happened", snare.counts.hits >= 6, snare.counts.hits)
  near("loop: snare still +15", s.mean, 15, 1500 / sr)
  check("loop: no snare extras", snare.counts.extras == 0, snare.counts.extras)
  check("loop: no snare misses", snare.counts.misses == 0, snare.counts.misses)
  local h = Metrics.compute(all_hits(hat))
  log(string.format("loop hat: n=%d mean=%.4f sd=%s miss=%d extra=%d det=%d", h.n, h.mean or 0, tostring(h.sd), hat.counts.misses, hat.counts.extras, hat.counts.detected))
  near("loop: hat still -20", h.mean, -20, 1500 / sr)
  check("loop: hat extras none (early hit carried over the seam)", hat.counts.extras == 0, hat.counts.extras)
  check("loop: hat misses only the first note, none at the seams", hat.counts.misses == 1, hat.counts.misses)
  local k = Metrics.compute(all_hits(kick))
  log(string.format("loop kick: n=%d mean=%.4f sd=%s miss=%d extra=%d", k.n, k.mean or 0, tostring(k.sd), kick.counts.misses, kick.counts.extras))
  check("loop: segments advanced", (snare.segment or snare.newest_segment or 0) >= 3, snare.newest_segment)
  loop_counts = snare.counts.hits
end)

-- 4: duplicate lane -----------------------------------------------------------
local dup_track, dup_fx
step(0.1, function()
  session:reset()
  dup_track, dup_fx = add_detector("Snare duplicate", 2)
end)
step(0.5, function()
  local st = Protocol.read_lane_status(reaper.gmem_read, 1)
  check("duplicate lane is flagged to the UI", st and st.duplicate > 0, st and st.duplicate)
  self_test(dup_track, dup_fx, 2, 40) -- would corrupt lane 2 if it could write
  start_transport()
end)
step(4.5, function()
  reaper.Main_OnCommand(1016, 0)
end)
step(0.3, function()
  local snare = session.lanes[2]
  local s = Metrics.compute(all_hits(snare))
  log(string.format("dup snare: n=%d mean=%.4f sd=%s extra=%d", s.n, s.mean or 0, tostring(s.sd), snare.counts.extras))
  near("duplicate cannot corrupt: lane still reads +15, not +40", s.mean, 15, 0.1)
  check("duplicate: spread still tiny", s.sd and s.sd < 0.1, s.sd)
  reaper.DeleteTrack(dup_track)
end)
step(0.8, function()
  local st = Protocol.read_lane_status(reaper.gmem_read, 1)
  check("removing the duplicate clears the flag", st and st.duplicate == 0, st and st.duplicate)
end)

-- 5: reader restart doesn't replay --------------------------------------------
step(0.1, function()
  local fresh = new_session()
  fresh:tick()
  check("new session replays nothing", fresh.lanes[2].counts.detected == 0, fresh.lanes[2].counts.detected)
end)

-- 6: detector removed: no stale liveness ---------------------------------------
step(0.1, function()
  self_test(kick_track, kick_fx, 0, 0)
  self_test(snare_track, snare_fx, 0, 0)
  self_test(hat_track, hat_fx, 0, 0)
end)

-- 7: real audio through the detector ------------------------------------------
local wav_track, wav_fx, wav_expected
step(0.2, function()
  session:reset()
  local srate = 48000
  local _, device_srate = reaper.GetAudioDeviceInfo("SRATE")
  srate = tonumber(device_srate) or srate
  local path = dir .. "ldgm_impulses.wav"
  wav_expected = 7
  local times = {}
  for bar = 0, 3 do
    times[#times + 1] = bar * 2 + 0.5 + wav_expected / 1000
    times[#times + 1] = bar * 2 + 1.5 + wav_expected / 1000
  end
  write_impulse_wav(path, srate, 9, times)
  wav_track, wav_fx = add_detector("Impulses", 4, -24)
  local item = reaper.AddMediaItemToTrack(wav_track)
  local take = reaper.AddTakeToMediaItem(item)
  local source = reaper.PCM_Source_CreateFromFile(path)
  reaper.SetMediaItemTake_Source(take, source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 9)
  reaper.UpdateItemInProject(item)
  session.config.lanes[4].steps = { 4, 12 }
  session.config.lanes[4].scoring = true
  session:config_changed()
  start_transport()
end)
step(8.3, function()
  reaper.Main_OnCommand(1016, 0)
end)
step(0.3, function()
  local lane = session.lanes[4]
  local s = Metrics.compute(all_hits(lane))
  log(string.format("audio impulses: n=%d mean=%.4f sd=%s miss=%d extra=%d det=%d", s.n, s.mean or 0, tostring(s.sd), lane.counts.misses, lane.counts.extras, lane.counts.detected))
  check("audio: one event per impulse", lane.counts.detected == 8, lane.counts.detected)
  check("audio: all on pattern", lane.counts.hits == 8, lane.counts.hits)
  near("audio: +7 ms impulses measure +7 ms", s.mean, wav_expected, 0.5)
  check("audio: spread under 0.5 ms", s.sd and s.sd < 0.5, s.sd)
end)

-- 7b: drum-like sounds, not just clean clicks --------------------------------
local drum_reader, drum_track
local DRUM_EVENTS = {
  { t = 1.0, f = 200, tau = 0.120, amp = 0.8, name = "long-ringing snare" },
  { t = 2.0, f = 60,  tau = 0.060, amp = 0.8, name = "60 Hz kick" },
  { t = 3.0, f = 800, tau = 0.030, amp = 0.8, name = "fast stroke 1" },
  { t = 3.1, f = 800, tau = 0.030, amp = 0.8, name = "fast stroke 2, 100 ms later" },
  { t = 4.0, f = 800, tau = 0.010, amp = 0.06, name = "soft stroke, -24 dB" },
}
step(0.2, function()
  reaper.DeleteTrack(wav_track)
  local _, device_srate = reaper.GetAudioDeviceInfo("SRATE")
  local srate = tonumber(device_srate) or 44100
  local n = srate * 7
  local data = {}
  for i = 1, n do data[i] = 0 end
  local function add(ev)
    local start = math.floor(ev.t * srate + 0.5)
    for k = 0, math.floor(ev.tau * 8 * srate) do
      local a = ev.amp * math.exp(-k / (ev.tau * srate)) * math.sin(2 * math.pi * ev.f * k / srate)
      if start + k + 1 <= n then data[start + k + 1] = data[start + k + 1] + a end
    end
  end
  for _, ev in ipairs(DRUM_EVENTS) do add(ev) end
  add({ t = 5.0, f = 800, tau = 0.010, amp = 0.01 }) -- -40 dB: below threshold, must not trigger
  local path = dir .. "ldgm_drums.wav"
  local f = assert(io.open(path, "wb"))
  f:write("RIFF", string.pack("<I4", 36 + n * 4), "WAVE")
  f:write("fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, 1, srate, srate * 4, 4, 32))
  f:write("data", string.pack("<I4", n * 4))
  for i = 1, n do f:write(string.pack("<f", data[i])) end
  f:close()
  drum_track = add_detector("Drums", 5, -30)
  local item = reaper.AddMediaItemToTrack(drum_track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 7)
  reaper.UpdateItemInProject(item)
  drum_reader = Protocol.new_reader(reaper.gmem_read, 4)
  start_transport()
end)
step(6.0, function()
  reaper.Main_OnCommand(1016, 0)
end)
step(0.3, function()
  local hits = {}
  for _, rec in ipairs((drum_reader:poll())) do
    if rec.kind == Protocol.KIND_HIT then hits[#hits + 1] = rec end
  end
  for _, h in ipairs(hits) do log(string.format("  drum onset at %.4f s, peak %.3f, backdated %d", h.a, h.c, h.e)) end
  check("drums: one onset per real attack, none for the sub-threshold hit", #hits == #DRUM_EVENTS, #hits)
  for i, ev in ipairs(DRUM_EVENTS) do
    if hits[i] then near("drums: " .. ev.name .. " onset time (ms)", (hits[i].a - ev.t) * 1000, 0, 3) end
  end
end)

-- 8: the real setup shape: opt-in tracks, armed, monitoring only ----------------
local created_before
step(0.2, function()
  wipe_project()
  reaper.Undo_OnStateChange("test: wiped project") -- undo below must land here
  created_before = reaper.CountTracks(0)
  local ok, n = Bridge.create_lane_tracks({ "Kick", "Snare", "Hi-hat" })
  check("opt-in helper adds three tracks", ok and n == 3 and reaper.CountTracks(0) == created_before + 3, n)
  reaper.Undo_DoUndo2(0)
  check("undo removes the added tracks", reaper.CountTracks(0) == created_before, reaper.CountTracks(0))
  ok, n = Bridge.create_lane_tracks({ "Kick", "Snare", "Hi-hat" })
  local found = Bridge.scan_detectors()
  for lane = 1, 3 do
    local inst = found[lane][1]
    check("lane " .. lane .. " track is armed and monitoring", inst and inst.armed and inst.monitor == 1)
    check("lane " .. lane .. " is on mono input " .. lane, inst and inst.input == lane - 1, inst and inst.input)
    check("lane " .. lane .. " detector is first in its chain", inst and inst.fx == 0)
  end
  local snare = found[2][1]
  check("track is monitoring-only", reaper.GetMediaTrackInfo_Value(snare.track, "I_RECMODE") == 2)
  self_test(snare.track, snare.fx, 2, 15)
  session:reset()
  session.config.lanes[4].steps = {}
  session:config_changed()
  start_transport()
end)
step(4.5, function()
  reaper.Main_OnCommand(1016, 0)
end)
step(0.3, function()
  local snare = session.lanes[2]
  local s = Metrics.compute(all_hits(snare))
  log(string.format("armed snare: n=%d mean=%.4f sd=%s", s.n, s.mean or 0, tostring(s.sd)))
  check("armed monitoring-only track scores while playing", s.n >= 4, s.n)
  near("armed track still measures +15", s.mean, 15, 0.1)
  session:reset()
  reaper.SetEditCurPos(0, true, false)
  reaper.Main_OnCommand(1013, 0) -- record
end)
step(4.5, function()
  check("transport reports recording", reaper.GetPlayState() & 4 ~= 0, reaper.GetPlayState())
  reaper.Main_OnCommand(1016, 0)
end)
step(0.5, function()
  local snare = session.lanes[2]
  local s = Metrics.compute(all_hits(snare))
  log(string.format("recording snare: n=%d mean=%.4f", s.n, s.mean or 0))
  check("record mode scores too", s.n >= 4, s.n)
  near("record mode still measures +15", s.mean, 15, 0.1)
  check("monitoring-only tracks recorded no items", reaper.CountMediaItems(0) == 0, reaper.CountMediaItems(0))
end)

-- Done ----------------------------------------------------------------------

step(0.1, function()
  log(string.format("\n%d failures", failures))
  local f = io.open(results_path .. ".done", "w")
  if f then f:close() end
  if os.getenv("LDGM_SCREENSHOT") == "1" then
    -- Hand over to the real dashboard with a groove running.
    wipe_project()
    kick_track, kick_fx = add_detector("Kick", 1)
    snare_track, snare_fx = add_detector("Snare", 2)
    hat_track, hat_fx = add_detector("Hi-hat", 3)
    self_test(kick_track, kick_fx, 1, 3)
    self_test(snare_track, snare_fx, 2, 15)
    self_test(hat_track, hat_fx, 3, -8)
    session = nil
    start_transport()
    dofile(base .. "Live Drum Groove Monitor.lua")
  end
end)

-- Runner --------------------------------------------------------------------

local index, resume_at = 1, 0

local function pump()
  if session then
    session:tick()
    -- Record block offsets from the raw event stream via the session's last event.
    local e = session.lanes[3].last_event
    if e and e.seq ~= session.last_offset_seq then
      session.last_offset_seq = e.seq
      session.offset_log = session.offset_log or {}
      table.insert(session.offset_log, e.sample_offset)
    end
  end
  local t = reaper.time_precise()
  if t >= resume_at then
    local s = steps[index]
    if not s or aborted then return end
    local ok, err = xpcall(s.fn, debug.traceback)
    if not ok then
      log("ERROR " .. tostring(err))
      failures = failures + 1
    end
    if aborted then return end
    index = index + 1
    local following = steps[index]
    resume_at = t + (following and following.wait or 0)
  end
  reaper.defer(pump)
end

resume_at = reaper.time_precise() + 1
reaper.defer(pump)
