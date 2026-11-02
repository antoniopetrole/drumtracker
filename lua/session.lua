-- session.lua: turns the gmem event stream into per-lane scores. No REAPER or
-- UI dependency: gmem access, QN->time conversion and the wall clock are
-- injected, so whole sessions can be simulated in tests.

local Protocol = require("protocol")
local Patterns = require("patterns")
local Matcher = require("matcher")
local Metrics = require("metrics")
local Timing = require("timing")

local S = {}
S.__index = S

S.BLEED_WINDOW_S = 0.008  -- extra this close to another lane's onset is a bleed suspect
S.DOUBLE_WINDOW_S = 0.040 -- extra this close to this lane's own onset is a double suspect
S.ALIVE_TIMEOUT_S = 1.0
S.RECENT_ONSETS = 16

local function new_counts()
  return {
    detected = 0, hits = 0, misses = 0, extras = 0,
    suspect_bleed = 0, suspect_double = 0, unscored = 0,
  }
end

-- opts: read, qn_to_time, clock, config, can_score (optional fn -> ok, reason)
function S.new(opts)
  local self = setmetatable({}, S)
  self.read = opts.read
  self.qn_to_time = opts.qn_to_time
  self.clock = opts.clock
  self.config = opts.config
  self.scoring_allowed = true
  self.lanes = {}
  for i = 1, Protocol.MAX_LANES do
    self.lanes[i] = {
      index = i,
      reader = Protocol.new_reader(self.read, i - 1),
      matcher = nil,
      segment = nil,       -- segment id the matcher is working in
      newest_segment = nil, -- highest segment id seen, even if since ended
      last_pos = nil,      -- last audio position fed to this segment
      play_base = 0,       -- played seconds accumulated before this segment
      seg_start_s = nil,
      played_s = 0,
      history = Metrics.new_history(),
      counts = new_counts(),
      latest = nil,
      last_event_at = nil,
      last_event = nil,
      recent_onsets = {},
      status = nil,
      last_heartbeat = nil,
      heartbeat_at = nil,
      alive = false,
      lost_events = 0,
    }
  end
  return self
end

local function bar_seconds(self)
  return self.qn_to_time(Patterns.QN_PER_BAR) - self.qn_to_time(0)
end

local function note_onset_time(lane, t)
  local r = lane.recent_onsets
  r[#r + 1] = t
  if #r > S.RECENT_ONSETS then table.remove(r, 1) end
end

-- Diagnostic only: extras stay extras, and simultaneous onsets on other lanes
-- are never discarded because a snare and a hat often truly land together.
local function classify_extra(self, lane, result)
  local c = lane.counts
  for _, other in ipairs(self.lanes) do
    if other ~= lane then
      for _, t in ipairs(other.recent_onsets) do
        if math.abs(t - result.hit_s) <= S.BLEED_WINDOW_S then
          c.suspect_bleed = c.suspect_bleed + 1
          return "bleed"
        end
      end
    end
  end
  for _, t in ipairs(lane.recent_onsets) do
    local d = result.hit_s - t
    if d > 0 and d <= S.DOUBLE_WINDOW_S then
      c.suspect_double = c.suspect_double + 1
      return "double"
    end
  end
  return nil
end

local function played_time(lane, position_s)
  if not lane.seg_start_s then return lane.played_s end
  return lane.play_base + math.max(0, position_s - lane.seg_start_s)
end

local function on_result(self, lane, result)
  local c = lane.counts
  if result.kind == "hit" then
    c.hits = c.hits + 1
    Metrics.push(lane.history, {
      corrected_ms = result.corrected_ms,
      signed_ms = result.signed_ms,
      step = result.step,
      peak = result.peak,
      played_s = played_time(lane, result.hit_s),
    })
    lane.latest = {
      corrected_ms = result.corrected_ms,
      signed_ms = result.signed_ms,
      step = result.step,
      at = self.clock(),
    }
  elseif result.kind == "miss" then
    c.misses = c.misses + 1
  elseif result.kind == "extra" then
    c.extras = c.extras + 1
    result.suspect = classify_extra(self, lane, result)
  elseif result.kind == "unscored" then
    c.unscored = c.unscored + 1
  end
  if self.on_result then self.on_result(lane.index, result) end
end

local function scoring_on(self, lane)
  local lc = self.config.lanes[lane.index]
  return self.scoring_allowed and self.config.scoring_enabled and lc.scoring
end

local function make_matcher(self, lane)
  local lc = self.config.lanes[lane.index]
  return Matcher.new({
    pattern = Patterns.from_steps(lc.steps),
    qn_to_time = self.qn_to_time,
    window_ms = self.config.match_window_ms,
    calibration_ms = lc.calibration_ms,
    origin_qn = (self.config.origin_bar - 1) * Patterns.QN_PER_BAR,
    emit = function(result) on_result(self, lane, result) end,
  })
end

local function start_segment(self, lane, seg, pos_s, pos_qn)
  if lane.seg_start_s then lane.play_base = lane.played_s end
  lane.segment = seg
  lane.newest_segment = seg
  lane.seg_start_s = pos_s
  lane.last_pos = pos_s
  lane.matcher = nil
  if scoring_on(self, lane) then
    lane.matcher = make_matcher(self, lane)
    lane.matcher:begin(pos_qn)
  end
end

local function close_segment(lane, end_s)
  local carry = {}
  if lane.matcher then
    carry = lane.matcher:finish(end_s)
  end
  if lane.seg_start_s then
    lane.played_s = played_time(lane, end_s)
  end
  return carry
end

local function handle_record(self, lane, rec)
  if rec.kind == Protocol.KIND_SEG_START then
    local continuous = rec.e == 1
    -- Without a continuous jump the end position is unknown (the SEG_END was
    -- lost or the detector reloaded). Only what was already reached may score.
    local carry = close_segment(lane, continuous and rec.c or lane.last_pos or rec.a)
    local old = lane.matcher
    start_segment(self, lane, rec.seg, rec.a, rec.b)
    if #carry > 0 then
      local shift = rec.b - rec.d
      local bars = shift / Patterns.QN_PER_BAR
      local phase_kept = math.abs(bars - math.floor(bars + 0.5)) < 1e-6
      if continuous and phase_kept and lane.matcher then
        lane.matcher:carry_over(carry, shift)
      elseif old then
        old:drop_carry(carry)
      end
    end
  elseif rec.kind == Protocol.KIND_SEG_END then
    local carry = close_segment(lane, rec.a)
    if lane.matcher then lane.matcher:drop_carry(carry) end
    lane.matcher = nil
    lane.newest_segment = rec.seg
    lane.segment = nil
    lane.seg_start_s = nil
    lane.last_pos = nil
    lane.play_base = lane.played_s
  elseif rec.kind == Protocol.KIND_HIT then
    if rec.seg ~= lane.segment then
      -- Marker lost to overflow, or the UI attached mid-segment. Never join
      -- this onto the old timeline.
      close_segment(lane, lane.last_pos or rec.a)
      start_segment(self, lane, rec.seg, rec.a, rec.b)
    end
    lane.counts.detected = lane.counts.detected + 1
    lane.last_event_at = self.clock()
    lane.last_event = { hit_s = rec.a, hit_qn = rec.b, peak = rec.c, sample_offset = rec.d, backdated = rec.e, seq = rec.seq }
    if lane.matcher then lane.matcher:onset(rec.a, rec.b, rec.c) end
    note_onset_time(lane, rec.a)
  end
end

local function is_playing(status)
  return status.play_state > 0 and status.play_state & 1 == 1
end

function S:tick()
  for i, lane in ipairs(self.lanes) do
    -- Clock first: every onset before this position is already in the ring.
    local status = Protocol.read_lane_status(self.read, i - 1)
    if status then
      lane.status = status
      if status.heartbeat ~= lane.last_heartbeat then
        lane.last_heartbeat = status.heartbeat
        lane.heartbeat_at = self.clock()
      end
    end
    lane.alive = lane.heartbeat_at ~= nil
      and lane.status.heartbeat > 0
      and self.clock() - lane.heartbeat_at < S.ALIVE_TIMEOUT_S

    local records, lost = lane.reader:poll()
    if lost > 0 then lane.lost_events = lane.lost_events + lost end
    for _, rec in ipairs(records) do handle_record(self, lane, rec) end

    -- This status predates the drained records, so it can describe a segment
    -- the stream has already moved past. Only a newer segment id starts one:
    -- that means the UI attached mid-segment and no marker will ever arrive.
    if status and lane.alive and is_playing(status) then
      if not lane.newest_segment or status.segment > lane.newest_segment then
        close_segment(lane, lane.last_pos or status.block_s)
        start_segment(self, lane, status.segment, status.block_s, status.block_qn)
      end
      if lane.segment == status.segment then
        lane.last_pos = status.block_s
        lane.played_s = played_time(lane, status.block_s)
        if lane.matcher then lane.matcher:advance(status.block_s) end
      end
    end
  end
end

-- Pattern, window, calibration or origin changed. Open targets are dropped
-- without scoring and matching restarts at the current position.
function S:config_changed()
  for _, lane in ipairs(self.lanes) do
    if lane.segment and lane.status then
      lane.matcher = nil
      if scoring_on(self, lane) then
        lane.matcher = make_matcher(self, lane)
        lane.matcher:begin(lane.status.block_qn)
      end
    end
  end
end

-- Clears UI-side results and skips events already in the ring. Never writes
-- gmem, so it cannot race the detectors.
function S:reset()
  for _, lane in ipairs(self.lanes) do
    lane.history = Metrics.new_history()
    lane.counts = new_counts()
    lane.latest = nil
    lane.last_event = nil
    lane.last_event_at = nil
    lane.recent_onsets = {}
    lane.lost_events = 0
    lane.reader:skip_to_head()
    lane.reader.dropped = 0
    lane.reader.torn = 0
    lane.played_s = 0
    lane.play_base = 0
    if lane.segment and lane.status then
      lane.seg_start_s = lane.status.block_s
    end
  end
  self:config_changed()
end

-- Window selection for stats. Returns entries for the configured window.
function S:window_entries(lane)
  local mode = self.config.window_mode
  local n = tonumber(mode:match("^hits(%d+)$"))
  if n then return Metrics.latest(lane.history, n) end
  local bars = tonumber(mode:match("^bars(%d+)$")) or 8
  return Metrics.since(lane.history, lane.played_s - bars * bar_seconds(self))
end

function S:stats(lane)
  return Metrics.compute(self:window_entries(lane))
end

S.format_ms = Timing.format_ms

return S
