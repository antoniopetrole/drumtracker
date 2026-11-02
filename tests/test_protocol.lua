local t = require("harness")
local P = require("protocol")
local Fake = require("fake_gmem")

t.test("every lane fits in its region and all of gmem", function()
  t.truthy(P.RING_OFFSET + P.RING_SIZE * P.RECORD_SIZE <= P.LANE_STRIDE)
  t.truthy(P.lane_base(P.MAX_LANES) <= 8000000, "JSFX named gmem has 8M entries")
  t.eq(P.lane_base(0), 1024)
  t.eq(P.lane_base(7), 1024 + 7 * 4096)
end)

t.test("lane regions never overlap", function()
  local last_of_0 = P.record_base(0, P.RING_SIZE) + P.RECORD_SIZE - 1
  t.truthy(last_of_0 < P.lane_base(1))
end)

t.test("JSFX constants match lua/protocol.lua", function()
  local dir = arg and arg[0]:match("^(.*)[/\\]") or "tests"
  local f = assert(io.open(dir .. "/../jsfx/Live Drum Onset Detector.jsfx"))
  local src = f:read("a")
  f:close()
  local function constant(name)
    return tonumber(src:match("%f[%w_]" .. name .. "%s*=%s*(%-?%d+)%s*;"))
  end
  t.eq(constant("PR_MAGIC"), P.MAGIC)
  t.eq(constant("PR_VERSION"), P.VERSION)
  t.eq(constant("GLOBAL_SIZE"), P.GLOBAL_SIZE)
  t.eq(constant("LANE_STRIDE"), P.LANE_STRIDE)
  t.eq(constant("RING_OFFSET"), P.RING_OFFSET)
  t.eq(constant("RING_SIZE"), P.RING_SIZE)
  t.eq(constant("RECORD_SIZE"), P.RECORD_SIZE)
  for name, value in pairs(P) do
    if type(value) == "number" and name ~= "G_UI_HEARTBEAT"
      and (name:match("^H_") or name:match("^R_") or name:match("^KIND_") or name:match("^G_")) then
      local jsfx_name = name == "G_INSTANCE_COUNTER" and "G_COUNTER" or name
      t.eq(constant(jsfx_name), value, name)
    end
  end
  t.truthy(src:find("options:gmem=" .. P.NAMESPACE, 1, true))
end)

t.test("JSFX never writes to the audio channels", function()
  local dir = arg and arg[0]:match("^(.*)[/\\]") or "tests"
  local f = assert(io.open(dir .. "/../jsfx/Live Drum Onset Detector.jsfx"))
  local src = f:read("a")
  f:close()
  t.eq(src:find("spl%d+%s*[%+%-%*/]?=[^=]"), nil, "assignment to splN")
  t.eq(src:find("spl%(", 1), nil, "spl() access")
end)

t.test("a new reader ignores what's already in the ring", function()
  local g = Fake.new()
  for i = 1, 5 do g:hit(0, i) end
  local r = P.new_reader(g.read, 0)
  t.eq(#r:poll(), 0)
  g:hit(0, 6)
  local recs = r:poll()
  t.eq(#recs, 1)
  t.eq(recs[1].a, 6)
end)

t.test("reader returns records in order", function()
  local g = Fake.new()
  local r = P.new_reader(g.read, 0)
  for i = 1, 3 do g:hit(0, i * 0.5, i, 0.1 * i) end
  local recs = r:poll()
  t.eq(#recs, 3)
  t.eq(recs[3].a, 1.5)
  t.eq(recs[3].b, 3)
  t.near(recs[3].c, 0.3)
  t.eq(recs[3].seq, 3)
end)

t.test("overflow is counted, and only the newest ring-full is read", function()
  local g = Fake.new()
  local r = P.new_reader(g.read, 0)
  local total = P.RING_SIZE + 44
  for i = 1, total do g:hit(0, i) end
  local recs, lost = r:poll()
  t.eq(lost, 44)
  t.eq(#recs, P.RING_SIZE)
  t.eq(recs[1].a, 45)
  t.eq(recs[#recs].a, total)
  t.eq(r.dropped, 44)
end)

t.test("a record being overwritten is rejected, not misread", function()
  local g = Fake.new()
  local r = P.new_reader(g.read, 0)
  g:hit(0, 1)
  g.write(P.record_base(0, 1) + P.R_COMMIT, -(1 + P.RING_SIZE))
  local recs, lost = r:poll()
  t.eq(#recs, 0)
  t.eq(lost, 1)
end)

t.test("a record overwritten during the copy is rejected", function()
  local g = Fake.new()
  local r = P.new_reader(g.read, 0)
  g:hit(0, 1)
  local reads = 0
  r.read = function(i)
    if i == P.record_base(0, 1) + P.R_COMMIT then
      reads = reads + 1
      if reads == 2 then return -(1 + P.RING_SIZE) end
    end
    return g.read(i)
  end
  local recs, lost = r:poll()
  t.eq(#recs, 0)
  t.eq(lost, 1)
end)

t.test("lanes don't disturb each other", function()
  local g = Fake.new()
  local r0, r1, r7 = P.new_reader(g.read, 0), P.new_reader(g.read, 1), P.new_reader(g.read, 7)
  g:hit(0, 10)
  g:hit(1, 20)
  g:hit(7, 70)
  g:hit(0, 11)
  t.eq(#r0:poll(), 2)
  t.eq(r1:poll()[1].a, 20)
  t.eq(r7:poll()[1].a, 70)
end)

t.test("head moving backwards resyncs rather than replaying", function()
  local g = Fake.new()
  for i = 1, 5 do g:hit(0, i) end
  local r = P.new_reader(g.read, 0)
  g.write(P.lane_base(0) + P.H_SEQ, 2)
  t.eq(#r:poll(), 0)
  t.eq(r.resyncs, 1)
end)

t.test("skip_to_head discards pending events without writing gmem", function()
  local g = Fake.new()
  local r = P.new_reader(g.read, 0)
  g:hit(0, 1)
  local before = g.read(P.lane_base(0) + P.H_SEQ)
  r:skip_to_head()
  t.eq(#r:poll(), 0)
  t.eq(g.read(P.lane_base(0) + P.H_SEQ), before)
end)

t.test("status read during an update returns nil", function()
  local g = Fake.new()
  g:block(0, 1, 2)
  t.truthy(P.read_lane_status(g.read, 0))
  g.write(P.lane_base(0) + P.H_HEARTBEAT, 3) -- odd: writer in progress
  t.eq(P.read_lane_status(g.read, 0), nil)
end)

t.test("status that changes during the read returns nil", function()
  local g = Fake.new()
  g:block(0, 1, 2)
  local n = 0
  local read = function(i)
    if i == P.lane_base(0) + P.H_HEARTBEAT then
      n = n + 1
      if n == 2 then return 4 end
    end
    return g.read(i)
  end
  t.eq(P.read_lane_status(read, 0), nil)
end)
