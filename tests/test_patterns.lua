local t = require("harness")
local P = require("patterns")

t.test("defaults are the rock pattern", function()
  t.eq(table.concat(P.to_steps(P.default_kick()), ","), "0,8")
  t.eq(table.concat(P.to_steps(P.default_snare()), ","), "4,12")
  t.eq(table.concat(P.to_steps(P.default_hat()), ","), "0,2,4,6,8,10,12,14")
end)

t.test("a step is a 16th: step 4 of bar 2 is QN 5", function()
  t.near(P.step_to_qn(16 + 4, 0), 5)
end)

t.test("next and prev wrap the bar", function()
  local kick = P.default_kick()
  t.eq(P.next_expected(kick, 9), 16)
  t.eq(P.prev_expected(kick, 16), 8)
  t.eq(P.prev_expected(kick, 0), -8)
end)

t.test("empty pattern has no notes", function()
  t.eq(P.next_expected(P.empty(), 0), nil)
  t.eq(P.prev_expected(P.empty(), 0), nil)
end)
