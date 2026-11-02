local t = require("harness")
local Remote = require("remote")
local Fake = require("fake_gmem")
local Session = require("session")
local Config = require("config")
local Timing = require("timing")

local SNARE = 1

local function setup()
  local g = Fake.new()
  local clock = { now = 100 }
  local cfg = Config.defaults()
  local session = Session.new({
    read = g.read,
    qn_to_time = Timing.linear_qn_to_time(120),
    clock = function() return clock.now end,
    config = cfg,
  })
  local detectors = {}
  for i = 1, 8 do detectors[i] = {} end
  local app = {
    session = session, config = cfg, now = function() return clock.now end,
    status = {
      detectors = detectors, project_ok = true, bpm = 120,
      transport = { label = "Playing", playing = true, bar = 1, beat = 1.5, metronome = true },
    },
  }
  return app, g, clock
end

local function run_snare(app, g, clock, hits)
  g:start_segment(SNARE, 0, 0)
  local pos, i = 0, 1
  while pos < 0.9 do
    while hits[i] and hits[i] <= pos do
      g:hit(SNARE, hits[i], hits[i] * 2)
      i = i + 1
    end
    g:block(SNARE, pos, pos * 2)
    app.session:tick()
    clock.now = clock.now + 1 / 60
    pos = pos + 1 / 60
  end
end

t.test("strings are escaped so names can't break the JSON", function()
  t.eq(Remote.encode('a"b\\c\nd'), '"a\\"b\\\\c\\u000ad"')
end)

t.test("numbers are short, signed, and exact enough", function()
  t.eq(Remote.encode(15.0113), "15.01")
  t.eq(Remote.encode(-20), "-20")
  t.eq(Remote.encode(0.5), "0.5")
  t.eq(Remote.encode(10.0), "10")
  t.eq(Remote.encode(100.0), "100")
  t.eq(Remote.encode(0.0), "0")
  t.eq(Remote.encode(-0.001), "0")
end)

t.test("nil, nan and inf become null, never a fake number", function()
  t.eq(Remote.encode(nil), "null")
  t.eq(Remote.encode(0 / 0), "null")
  t.eq(Remote.encode(math.huge), "null")
end)

t.test("no hits yet: the snapshot has no fabricated zeros", function()
  local app, g, clock = setup()
  run_snare(app, g, clock, {})
  local json = Remote.build(app, 1)
  t.eq(json:find('"bias":0', 1, true), nil)
  t.eq(json:find('"spread":0', 1, true), nil)
  t.truthy(json:find('"latest":null', 1, true) == nil)
  t.truthy(json:find('"name":"Snare"', 1, true))
end)

t.test("hits carry their signed offset through to the snapshot", function()
  local app, g, clock = setup()
  run_snare(app, g, clock, { 0.515 })
  local json = Remote.build(app, 7)
  t.truthy(json:find('"seq":7', 1, true))
  t.truthy(json:find('"word":"LATE"', 1, true))
  t.truthy(json:find('"text":"+15 ms"', 1, true))
  t.truthy(json:find('"points":[15', 1, true), json)
end)

t.test("points are capped so the snapshot stays small", function()
  local app = setup()
  local Metrics = require("metrics")
  for lane = 1, 8 do
    app.config.lanes[lane].steps = { 0 }
    for i = 1, 64 do
      Metrics.push(app.session.lanes[lane].history, { corrected_ms = -12.34, played_s = i })
    end
  end
  local json = Remote.build(app, 1)
  local _, count = json:gsub("%-12%.34", "")
  t.truthy(count >= 8 * Remote.MAX_POINTS, count)
  t.truthy(#json < 16000, "must fit REAPER's web reply limit: " .. #json)
end)

t.test("lane state says why a lane has no data", function()
  t.eq((Remote.lane_state({ alive = false }, {}, true)), "none")
  t.eq((Remote.lane_state({ alive = false }, { {} }, true)), "bad")
  t.eq((Remote.lane_state({ alive = true, status = { duplicate = 5 } }, { {} }, true)), "bad")
  t.eq((Remote.lane_state({ alive = true, status = { duplicate = 0 } }, { {} }, false)), "idle")
  t.eq((Remote.lane_state({ alive = true, status = { duplicate = 0 } }, { {} }, true)), "live")
end)
