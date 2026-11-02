local t = require("harness")
local M = require("metrics")

local function entries(values)
  local out = {}
  for i, v in ipairs(values) do out[i] = { corrected_ms = v, played_s = i } end
  return out
end

t.test("steady +15 ms: high bias, near-zero spread", function()
  local s = M.compute(entries({ 15, 15, 15, 15, 15, 15 }))
  t.near(s.mean, 15)
  t.near(s.sd, 0)
  t.near(s.mae, 15)
end)

t.test("-20/+20 ms: zero bias, large spread", function()
  local s = M.compute(entries({ -20, 20, -20, 20 }))
  t.near(s.mean, 0)
  t.truthy(s.sd > 20)
  t.near(s.mae, 20)
end)

t.test("sd is the sample standard deviation", function()
  t.near(M.compute(entries({ 2, 4, 4, 4, 5, 5, 7, 9 })).sd, 2.13809, 1e-4)
end)

t.test("percent within bands, inclusive", function()
  local s = M.compute(entries({ 0, 10, 15, 20, 30 }))
  t.near(s.pct10, 40)
  t.near(s.pct20, 80)
end)

t.test("no data means nil, never a fabricated zero", function()
  local s = M.compute({})
  t.eq(s.n, 0)
  t.eq(s.mean, nil)
  t.eq(s.sd, nil)
  t.eq(s.mae, nil)
end)

t.test("one hit has a mean but no spread", function()
  local s = M.compute(entries({ 5 }))
  t.near(s.mean, 5)
  t.eq(s.sd, nil)
end)

t.test("history caps and returns the newest", function()
  local h = M.new_history()
  for i = 1, M.CAPACITY + 10 do M.push(h, { corrected_ms = i, played_s = i }) end
  t.eq(M.count(h), M.CAPACITY)
  local last = M.latest(h, 2)
  t.eq(#last, 2)
  t.eq(last[2].corrected_ms, M.CAPACITY + 10)
end)

t.test("since filters by played time", function()
  local h = M.new_history()
  for i = 1, 10 do M.push(h, { corrected_ms = i, played_s = i }) end
  t.eq(#M.since(h, 8), 3)
end)
