local t = require("harness")
local Fake = require("fake_gmem")
local Session = require("session")
local Config = require("config")
local Metrics = require("metrics")
local Timing = require("timing")
local Library = require("library")

local SNARE = 1

local function db_to_peak(db) return 10 ^ (db / 20) end

local function setup(mutate)
  local g = Fake.new()
  local clock = { now = 100 }
  local cfg = Config.defaults()
  Library.apply(cfg, "groove:ghost-notes", {})
  if mutate then mutate(cfg) end
  local s = Session.new({
    read = g.read,
    qn_to_time = Timing.linear_qn_to_time(120),
    clock = function() return clock.now end,
    config = cfg,
  })
  g:start_segment(SNARE, 0, 0)
  return s, g, clock
end

-- hits: list of { time, peak }
local function play(s, g, clock, to, hits)
  local i, pos = 1, 0
  while pos <= to do
    while hits[i] and hits[i][1] <= pos do
      g:hit(SNARE, hits[i][1], hits[i][1] * 2, hits[i][2])
      i = i + 1
    end
    g:block(SNARE, pos, pos * 2)
    s:tick()
    clock.now = clock.now + 1 / 60
    pos = pos + 1 / 60
  end
end

-- The ghost note groove's snare, one bar at 120 BPM: accents at 0.5 and 1.5 s,
-- ghosts at 0.875, 1.125 and 1.875 s.
local function bar(accent_peak, ghost_peak)
  return {
    { 0.5, accent_peak }, { 0.875, ghost_peak }, { 1.125, ghost_peak },
    { 1.5, accent_peak }, { 1.875, ghost_peak },
  }
end

t.test("gap is accents minus ghosts, in dB", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, bar(db_to_peak(-6), db_to_peak(-24)))
  local d = s:dynamics(s.lanes[2])
  t.near(d.gap, 18, 1e-6)
  t.near(d.accent.mean, -6, 1e-6)
  t.near(d.ghost.mean, -24, 1e-6)
  t.eq(d.accent.n, 2)
  t.eq(d.ghost.n, 3)
end)

t.test("the gap doesn't depend on mic gain", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, bar(db_to_peak(-20), db_to_peak(-38)))
  t.near(s:dynamics(s.lanes[2]).gap, 18, 1e-6)
end)

t.test("steady dynamics read as low spread, uneven as high", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, {
    { 0.5, db_to_peak(-6) }, { 0.875, db_to_peak(-20) }, { 1.125, db_to_peak(-30) },
    { 1.5, db_to_peak(-6) }, { 1.875, db_to_peak(-25) },
  })
  local d = s:dynamics(s.lanes[2])
  t.near(d.accent.sd, 0, 1e-6)
  t.near(d.ghost.sd, 5, 1e-6)
end)

t.test("a lane with no marks reports no dynamics at all", function()
  local s = setup()
  t.eq(s:dynamics(s.lanes[1]), nil)
end)

t.test("no hits: undefined, never a fabricated 0 dB gap", function()
  local s = setup()
  local d = s:dynamics(s.lanes[2])
  t.eq(d.gap, nil)
  t.eq(d.accent.mean, nil)
  t.eq(d.ghost.sd, nil)
end)

t.test("accents alone give levels but no gap", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, { { 0.5, 0.5 }, { 1.5, 0.5 } })
  local d = s:dynamics(s.lanes[2])
  t.eq(d.gap, nil)
  t.truthy(d.accent.mean)
end)

t.test("undetected ghosts are counted, not silently left out of the picture", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, { { 0.5, 0.5 }, { 1.125, 0.05 }, { 1.5, 0.5 } })
  local lane = s.lanes[2]
  t.eq(lane.counts.ghost_misses, 2)
  t.eq(lane.counts.accent_misses, 0)
  t.eq(s:dynamics(lane).ghost.n, 1)
end)

t.test("clipped accents are flagged", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, bar(1.0, 0.1))
  t.eq(s:dynamics(s.lanes[2]).accent.clipped, 2)
end)

t.test("normal notes join neither group", function()
  local s, g, clock = setup(function(cfg)
    cfg.lanes[2].accents = { 4 }
    cfg.lanes[2].ghosts = { 7 }
  end)
  play(s, g, clock, 2.05, bar(0.5, 0.1))
  local d = s:dynamics(s.lanes[2])
  t.eq(d.accent.n, 1)
  t.eq(d.ghost.n, 1)
end)

t.test("dynamics follow the same window as timing", function()
  local s, g, clock = setup(function(cfg) cfg.window_mode = "hits16" end)
  local hits = {}
  for b = 0, 7 do
    for _, h in ipairs(bar(0.5, 0.1)) do hits[#hits + 1] = { h[1] + b * 2, h[2] } end
  end
  play(s, g, clock, 16.05, hits)
  local d = s:dynamics(s.lanes[2])
  t.eq(d.accent.n + d.ghost.n, 16)
end)

t.test("metrics stay separate from timing: bad dynamics don't move bias", function()
  local s, g, clock = setup()
  play(s, g, clock, 2.05, bar(0.9, 0.009))
  t.near(s:stats(s.lanes[2]).mean, 0, 1e-6)
  t.truthy(Metrics.dynamics({}).gap == nil)
end)
