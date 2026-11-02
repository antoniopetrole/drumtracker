local t = require("harness")
local Matcher = require("matcher")
local P = require("patterns")
local T = require("timing")

local function setup(steps, overrides)
  local results = {}
  local o = overrides or {}
  local m = Matcher.new({
    pattern = P.from_steps(steps),
    qn_to_time = T.linear_qn_to_time(o.bpm or 120, o.offset_s),
    window_ms = o.window_ms or 80,
    calibration_ms = o.calibration_ms or 0,
    origin_qn = o.origin_qn or 0,
    settle_ms = 0,
    emit = function(r) results[#results + 1] = r end,
  })
  m:begin(o.start_qn or 0)
  return m, results
end

local function of_kind(results, kind)
  local out = {}
  for _, r in ipairs(results) do
    if r.kind == kind then out[#out + 1] = r end
  end
  return out
end

local SNARE = { 4, 12 } -- 0.5 s and 1.5 s at 120 BPM

t.test("snare +15 ms is reported as +15 ms", function()
  local m, r = setup(SNARE)
  m:onset(0.515, 0, 1)
  m:advance(0.7)
  local hits = of_kind(r, "hit")
  t.eq(#hits, 1)
  t.near(hits[1].corrected_ms, 15, 1e-6)
end)

t.test("snare -20 ms is reported as -20 ms, never +20", function()
  local m, r = setup(SNARE)
  m:onset(0.480, 0, 1)
  m:advance(0.7)
  t.near(of_kind(r, "hit")[1].corrected_ms, -20, 1e-6)
end)

t.test("no result until the late window has passed", function()
  local m, r = setup(SNARE)
  m:onset(0.515, 0, 1)
  m:advance(0.579)
  t.eq(#r, 0)
  m:advance(0.581)
  t.eq(#r, 1)
end)

t.test("no hit becomes exactly one miss once its window ends", function()
  local m, r = setup(SNARE)
  m:advance(0.579)
  t.eq(#of_kind(r, "miss"), 0)
  m:advance(0.581)
  m:advance(0.9)
  t.eq(#of_kind(r, "miss"), 1)
end)

t.test("off-pattern onset is an extra and takes no target", function()
  local m, r = setup(SNARE)
  m:onset(1.0, 0, 1) -- kick's spot, not the snare's
  m:advance(1.2)
  t.eq(#of_kind(r, "extra"), 1)
  t.eq(#of_kind(r, "hit"), 0)
  t.eq(#of_kind(r, "miss"), 1) -- 0.5 s was never played
end)

t.test("just outside the window is an extra plus a miss, not a match", function()
  local m, r = setup(SNARE)
  m:onset(0.5805, 0, 1)
  m:advance(0.8)
  t.eq(#of_kind(r, "hit"), 0)
  t.eq(#of_kind(r, "extra"), 1)
  t.eq(#of_kind(r, "miss"), 1)
end)

t.test("one-to-one: two onsets on a note give one hit and one extra", function()
  local m, r = setup(SNARE)
  m:onset(0.49, 0, 1)
  m:onset(0.52, 0, 1)
  m:advance(0.7)
  local hits = of_kind(r, "hit")
  t.eq(#hits, 1)
  t.near(hits[1].corrected_ms, -10, 1e-6) -- closest wins
  t.eq(#of_kind(r, "extra"), 1)
  t.eq(of_kind(r, "extra")[1].reason, "duplicate")
end)

t.test("closest candidate wins even when it arrives second", function()
  local m, r = setup(SNARE)
  m:onset(0.45, 0, 1)
  m:onset(0.505, 0, 1)
  m:advance(0.7)
  t.near(of_kind(r, "hit")[1].corrected_ms, 5, 1e-6)
end)

t.test("adjacent targets: each hat 8th at 120 BPM expects 250 ms spacing", function()
  local m, r = setup({ 0, 2, 4, 6, 8, 10, 12, 14 })
  for i = 0, 7 do m:onset(i * 0.25 + 0.003, 0, 1) end
  m:advance(1.9)
  local hits = of_kind(r, "hit")
  t.eq(#hits, 8)
  t.eq(#of_kind(r, "miss"), 0)
  t.eq(#of_kind(r, "extra"), 0)
  for i = 2, 8 do t.near(hits[i].target_s - hits[i - 1].target_s, 0.25, 1e-9) end
end)

t.test("window clamps to half the gap, so close notes never overlap", function()
  -- 16ths at 240 BPM are 62.5 ms apart: half-gap beats the 80 ms window.
  local m, r = setup({ 0, 1 }, { bpm = 240 })
  m:onset(0.040, 0, 1) -- nearer step 1 (62.5 ms) than step 0
  m:advance(0.2)
  local hits = of_kind(r, "hit")
  t.eq(#hits, 1)
  t.eq(hits[1].step, 1)
  t.near(hits[1].corrected_ms, -22.5, 1e-6)
  t.eq(#of_kind(r, "miss"), 1)
end)

t.test("off-pattern kick before the next bar doesn't steal its note", function()
  local m, r = setup({ 0, 8 })
  m:onset(0, 0, 1)
  m:onset(1, 0, 1)
  m:onset(1.5, 0, 1) -- off-pattern, nowhere near step 16 at 2.0 s
  m:onset(2.0, 0, 1)
  m:advance(2.3)
  t.eq(#of_kind(r, "hit"), 3)
  t.eq(#of_kind(r, "extra"), 1)
  t.eq(#of_kind(r, "miss"), 0)
end)

t.test("calibration: big latency keeps good hits matched, not extras", function()
  -- 150 ms of latency is outside the raw 80 ms window.
  local m, r = setup(SNARE, { calibration_ms = 150 })
  m:onset(0.660, 0, 1)
  m:advance(0.9)
  local hits = of_kind(r, "hit")
  t.eq(#hits, 1)
  t.near(hits[1].signed_ms, 160, 1e-6)
  t.near(hits[1].corrected_ms, 10, 1e-6)
  t.eq(#of_kind(r, "extra"), 0)
end)

t.test("calibration delays the miss deadline so a hit cannot arrive too late", function()
  local m, r = setup(SNARE, { calibration_ms = 150 })
  m:advance(0.65) -- past raw window, inside calibrated window
  t.eq(#r, 0)
  m:onset(0.66, 0, 1)
  m:advance(0.8)
  t.eq(#of_kind(r, "hit"), 1)
  t.eq(#of_kind(r, "miss"), 0)
end)

t.test("targets follow qn_to_time rather than assuming a zero origin", function()
  local m, r = setup(SNARE, { offset_s = 3.25 })
  m:onset(3.75 + 0.012, 0, 1)
  m:advance(4)
  t.near(of_kind(r, "hit")[1].corrected_ms, 12, 1e-6)
end)

t.test("empty pattern: everything is extra, nothing is missed", function()
  local m, r = setup({})
  m:onset(0.5, 0, 1)
  m:advance(3)
  t.eq(#of_kind(r, "extra"), 1)
  t.eq(#of_kind(r, "miss"), 0)
end)

t.test("segment start mid-bar expects only notes after it", function()
  local m, r = setup(SNARE, { start_qn = 2 }) -- 1.0 s; step 4 is behind us
  m:advance(1.7)
  local miss = of_kind(r, "miss")
  t.eq(#miss, 1)
  t.eq(miss[1].step, 12)
end)

t.test("hits before the origin bar are unscored, not extras or misses", function()
  local m, r = setup(SNARE, { origin_qn = 4 }) -- bar 1 is count-in
  m:onset(0.5, 0, 1)
  m:advance(1.9)
  t.eq(#of_kind(r, "unscored"), 1)
  t.eq(#of_kind(r, "extra"), 0)
  t.eq(#of_kind(r, "miss"), 0)
end)

t.test("finish: a note whose window was cut short is not a miss", function()
  local m, r = setup(SNARE)
  m:advance(0.51)
  m:finish(0.52)
  t.eq(#of_kind(r, "miss"), 0)
end)

t.test("finish scores a reached note that has a candidate", function()
  local m, r = setup(SNARE)
  m:onset(0.505, 0, 1)
  m:finish(0.52)
  t.eq(#of_kind(r, "hit"), 1)
end)

t.test("finish returns early hits on an unreached note as carry", function()
  local m, r = setup({ 0, 8 })
  m:onset(0.001, 0, 1)
  m:onset(1.001, 0, 1)
  m:onset(1.99, 0, 1)
  local carry = m:finish(1.999)
  t.eq(#of_kind(r, "hit"), 2)
  t.eq(#of_kind(r, "extra"), 0)
  t.eq(#carry, 1)
  t.eq(carry[1].target_qn, 4)
end)
