local t = require("harness")
local P = require("protocol")
local Fake = require("fake_gmem")
local Session = require("session")
local Config = require("config")
local Timing = require("timing")

local KICK, SNARE, HAT = 0, 1, 2

local function new_session(g, cfg, clock)
  return Session.new({
    read = g.read,
    qn_to_time = Timing.linear_qn_to_time(120),
    clock = function() return clock.now end,
    config = cfg,
  })
end

local function setup(mutate)
  local g = Fake.new()
  local clock = { now = 100 }
  local cfg = Config.defaults()
  if mutate then mutate(cfg) end
  return new_session(g, cfg, clock), g, cfg, clock
end

-- A transport at 120 BPM from `from` to `to`, polled at 60 Hz. `events` is a list
-- of { time, lane }; each enters the stream when the clock passes it.
local function play(s, g, clock, lanes, from, to, events)
  events = events or {}
  table.sort(events, function(a, b) return a[1] < b[1] end)
  local i = 1
  local pos = from
  while pos <= to + 1e-9 do
    while events[i] and events[i][1] <= pos do
      g:hit(events[i][2], events[i][1], events[i][1] * 2)
      i = i + 1
    end
    for _, lane in ipairs(lanes) do g:block(lane, pos, pos * 2) end
    s:tick()
    clock.now = clock.now + 1 / 60
    pos = pos + 1 / 60
  end
end

t.test("acceptance: full groove on three lanes scores clean", function()
  local s, g, _, clock = setup()
  for _, lane in ipairs({ KICK, SNARE, HAT }) do g:start_segment(lane, 0, 0) end
  local ev = {}
  for bar = 0, 3 do
    local base = bar * 2
    ev[#ev + 1] = { base + 0.002, KICK }
    ev[#ev + 1] = { base + 1.002, KICK }
    ev[#ev + 1] = { base + 0.515, SNARE }
    ev[#ev + 1] = { base + 1.515, SNARE }
    for h = 0, 7 do
      local time = base + h * 0.25 - 0.003
      if time >= 0 then ev[#ev + 1] = { time, HAT } end
    end
  end
  play(s, g, clock, { KICK, SNARE, HAT }, 0, 7.95, ev)

  local k, sn, h = s.lanes[1], s.lanes[2], s.lanes[3]
  t.eq(k.counts.misses, 0)
  t.eq(k.counts.extras, 0)
  t.eq(sn.counts.hits, 8)
  t.eq(sn.counts.misses, 0)
  t.near(s:stats(sn).mean, 15, 1e-6)
  t.near(s:stats(sn).sd, 0, 1e-6)
  t.near(s:stats(k).mean, 2, 1e-6)
  t.eq(h.counts.extras, 0)
  t.near(s:stats(h).mean, -3, 1e-6)
end)

t.test("acceptance: UI reopened after hits sees none of them", function()
  local s1, g, cfg, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s1, g, clock, { SNARE }, 0, 2, { { 0.5, SNARE }, { 1.5, SNARE } })
  t.eq(s1.lanes[2].counts.hits, 2)

  local s2 = new_session(g, cfg, clock)
  s2:tick()
  t.eq(s2.lanes[2].counts.detected, 0)
  t.eq(s2.lanes[2].counts.hits, 0)
  t.eq(s2.lanes[2].counts.misses, 0)
end)

t.test("UI opened mid-song counts no misses for what it never saw", function()
  local _, g, cfg, clock = setup()
  g:start_segment(SNARE, 0, 0)
  g:block(SNARE, 5.1, 10.2)
  local s2 = new_session(g, cfg, clock)
  play(s2, g, clock, { SNARE }, 5.1, 5.3)
  t.eq(s2.lanes[2].counts.misses, 0)
  t.truthy(s2.lanes[2].matcher, "scoring from here on")
end)

t.test("acceptance: loop wrap is a new segment, hits count once each", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1.99, { { 0.5, SNARE }, { 1.5, SNARE } })
  g:start_segment(SNARE, 0, 0, 2, 4, true) -- loop [0, 2): position jumps back
  play(s, g, clock, { SNARE }, 0, 1.99, { { 0.51, SNARE }, { 1.51, SNARE } })
  local lane = s.lanes[2]
  t.eq(lane.counts.detected, 4)
  t.eq(lane.counts.hits, 4)
  t.eq(lane.counts.misses, 0)
  t.eq(lane.counts.extras, 0)
end)

t.test("loop: early downbeat before the wrap is scored on the new pass", function()
  local s, g, _, clock = setup()
  g:start_segment(KICK, 0, 0)
  play(s, g, clock, { KICK }, 0, 1.97, { { 0.002, KICK }, { 1.0, KICK } })
  g:hit(KICK, 1.99, 3.98) -- 10 ms early for the downbeat at the loop point
  g:start_segment(KICK, 0, 0, 2, 4, true)
  play(s, g, clock, { KICK }, 0, 0.2)
  local lane = s.lanes[1]
  t.eq(lane.counts.hits, 3)
  t.eq(lane.counts.extras, 0)
  t.eq(lane.counts.misses, 0)
  t.near(lane.latest.corrected_ms, -10, 1e-6)
end)

t.test("loop: a jump that changes pattern phase doesn't carry", function()
  local s, g, _, clock = setup()
  g:start_segment(KICK, 0, 0)
  play(s, g, clock, { KICK }, 0, 1.97, { { 0.002, KICK }, { 1.0, KICK } })
  g:hit(KICK, 1.99, 3.98)
  g:start_segment(KICK, 0.5, 1, 2, 4, true) -- wraps to beat 2
  play(s, g, clock, { KICK }, 0.5, 0.6)
  t.eq(s.lanes[1].counts.extras, 1)
end)

t.test("acceptance: seek never joins two timelines", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.45)
  g:start_segment(SNARE, 40, 80, 0.45, 0.9, true)
  play(s, g, clock, { SNARE }, 40, 40.55, { { 40.5, SNARE } })
  local lane = s.lanes[2]
  t.eq(lane.counts.detected, 1)
  t.eq(lane.counts.misses, 0) -- 0.5 s was never reached before the seek
end)

t.test("stop: open notes don't become misses, and play starts clean", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.51)
  g:end_segment(SNARE, 0.52, 1.04)
  g:block(SNARE, 0.52, 1.04, 0)
  s:tick()
  t.eq(s.lanes[2].counts.misses, 0)
  t.eq(s.lanes[2].matcher, nil)

  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.7, { { 0.5, SNARE } })
  t.eq(s.lanes[2].counts.hits, 1)
  t.eq(s.lanes[2].counts.misses, 0)
end)

t.test("status older than a fresh loop marker doesn't restart the segment", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1.99, { { 0.5, SNARE }, { 1.5, SNARE } })
  -- The marker is in the ring; the status still describes the block before it.
  g:start_segment(SNARE, 0, 0, 2, 4, true)
  s:tick()
  t.eq(s.lanes[2].counts.misses, 0)
  play(s, g, clock, { SNARE }, 0, 0.7, { { 0.5, SNARE } })
  t.eq(s.lanes[2].counts.hits, 3)
  t.eq(s.lanes[2].counts.misses, 0)
  t.eq(s.lanes[2].counts.extras, 0)
end)

t.test("detector reload mid-play continues without bogus misses", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.45)
  g:start_segment(SNARE, 10, 20) -- not continuous: no SEG_END was ever sent
  play(s, g, clock, { SNARE }, 10, 10.7, { { 10.5, SNARE } })
  t.eq(s.lanes[2].counts.misses, 0)
  t.eq(s.lanes[2].counts.hits, 1)
end)

t.test("detector vanishing shows as dead, and doesn't fake data", function()
  local s, g, _, clock = setup()
  t.eq(s.lanes[2].alive, false)
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.1)
  t.eq(s.lanes[2].alive, true)
  clock.now = clock.now + 5
  s:tick()
  t.eq(s.lanes[2].alive, false)
end)

t.test("silence is not perfect timing: stats stay undefined", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1.8)
  local lane = s.lanes[2]
  t.eq(lane.latest, nil)
  t.eq(s:stats(lane).mean, nil)
  t.eq(lane.counts.misses, 2)
end)

t.test("reset clears results and doesn't replay the ring", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1, { { 0.5, SNARE } })
  t.eq(s.lanes[2].counts.hits, 1)
  g:hit(SNARE, 1.01) -- in the ring, unread, when reset lands
  s:reset()
  t.eq(s.lanes[2].counts.hits, 0)
  t.eq(s.lanes[2].latest, nil)
  play(s, g, clock, { SNARE }, 1.05, 1.7, { { 1.5, SNARE } })
  t.eq(s.lanes[2].counts.detected, 1)
  t.eq(s.lanes[2].counts.hits, 1)
  t.eq(s.lanes[2].counts.misses, 0)
end)

t.test("muted lane detects but doesn't score", function()
  local s, g, _, clock = setup(function(c) c.lanes[2].scoring = false end)
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1.8, { { 0.5, SNARE } })
  local c = s.lanes[2].counts
  t.eq(c.detected, 1)
  t.eq(c.hits + c.misses + c.extras, 0)
end)

t.test("unsupported project: hits are shown but never scored", function()
  local s, g, _, clock = setup()
  s.scoring_allowed = false
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 1.8, { { 0.5, SNARE } })
  t.eq(s.lanes[2].counts.detected, 1)
  t.eq(s.lanes[2].counts.hits, 0)
  t.eq(s.lanes[2].counts.misses, 0)
end)

t.test("config change takes effect from now, without bogus results", function()
  local s, g, cfg, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.7, { { 0.5, SNARE } })
  cfg.lanes[2].calibration_ms = 20
  s:config_changed()
  play(s, g, clock, { SNARE }, 0.72, 1.8, { { 1.53, SNARE } })
  t.near(s.lanes[2].latest.corrected_ms, 10, 1e-6)
  t.eq(s.lanes[2].counts.hits, 2)
  t.eq(s.lanes[2].counts.misses, 0)
end)

t.test("window modes pick hits or played bars, across loops", function()
  local s, g, cfg, clock = setup()
  g:start_segment(HAT, 0, 0)
  local ev = {}
  for i = 0, 15 do ev[#ev + 1] = { i * 0.25 + 0.001, HAT } end
  play(s, g, clock, { HAT }, 0, 4.1, ev)
  local lane = s.lanes[3]
  cfg.window_mode = "hits16"
  t.eq(s:stats(lane).n, 16)
  cfg.window_mode = "bars4"
  t.eq(s:stats(lane).n, 16)
  g:start_segment(HAT, 0, 0, 4.1, 8.2, true)
  play(s, g, clock, { HAT }, 0, 1.0)
  t.truthy(lane.played_s > 5, "played time keeps growing across the wrap")
end)

t.test("bleed: hat extra at the snare's moment is a suspect, snare still counts", function()
  local s, g, _, clock = setup(function(c) c.lanes[3].steps = { 0 } end)
  g:start_segment(SNARE, 0, 0)
  g:start_segment(HAT, 0, 0)
  play(s, g, clock, { SNARE, HAT }, 0, 0.8, { { 0.5, SNARE }, { 0.501, HAT } })
  t.eq(s.lanes[2].counts.hits, 1)
  t.eq(s.lanes[3].counts.extras, 1)
  t.eq(s.lanes[3].counts.suspect_bleed, 1)
end)

t.test("simultaneous snare and hat both score on a shared beat", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  g:start_segment(HAT, 0, 0)
  play(s, g, clock, { SNARE, HAT }, 0, 0.7, { { 0.5, SNARE }, { 0.5, HAT } })
  t.eq(s.lanes[2].counts.hits, 1)
  t.truthy(s.lanes[3].counts.hits >= 1)
  t.eq(s.lanes[3].counts.suspect_bleed, 0)
end)

t.test("double trigger shows as a suspect", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  play(s, g, clock, { SNARE }, 0, 0.7, { { 0.5, SNARE }, { 0.52, SNARE } })
  t.eq(s.lanes[2].counts.hits, 1)
  t.eq(s.lanes[2].counts.extras, 1)
  t.eq(s.lanes[2].counts.suspect_double, 1)
end)

t.test("identical offsets give low spread with non-zero bias", function()
  local s, g, _, clock = setup()
  g:start_segment(SNARE, 0, 0)
  local ev = {}
  for bar = 0, 7 do
    ev[#ev + 1] = { bar * 2 + 0.5 + 0.03, SNARE }
    ev[#ev + 1] = { bar * 2 + 1.5 + 0.03, SNARE }
  end
  play(s, g, clock, { SNARE }, 0, 16, ev)
  local st = s:stats(s.lanes[2])
  t.near(st.mean, 30, 1e-6)
  t.near(st.sd, 0, 1e-6)
end)

t.test("ring overflow during a stall is reported and stays consistent", function()
  local s, g, _, clock = setup()
  g:start_segment(HAT, 0, 0)
  s:tick()
  for i = 1, P.RING_SIZE + 10 do g:hit(HAT, i * 0.25, i * 0.5) end
  g:block(HAT, (P.RING_SIZE + 10) * 0.25, (P.RING_SIZE + 10) * 0.5)
  clock.now = clock.now + 1 / 60
  s:tick()
  t.truthy(s.lanes[3].lost_events > 0)
  t.eq(s.lanes[3].counts.detected, P.RING_SIZE)
end)
