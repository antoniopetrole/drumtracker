local t = require("harness")
local C = require("config")

t.test("round trip keeps settings", function()
  local cfg = C.defaults()
  cfg.lanes[2].calibration_ms = 12.5
  cfg.lanes[2].steps = { 4, 6, 12 }
  cfg.lanes[1].name = 'Kick "in"'
  cfg.match_window_ms = 60
  local back = assert(C.decode(C.encode(cfg)))
  t.eq(back.lanes[2].calibration_ms, 12.5)
  t.eq(table.concat(back.lanes[2].steps, ","), "4,6,12")
  t.eq(back.lanes[1].name, 'Kick "in"')
  t.eq(back.match_window_ms, 60)
end)

t.test("settings cannot reach anything: empty environment", function()
  local v, err = C.decode("return os.execute('echo pwned')")
  t.eq(v, nil)
  t.truthy(err)
end)

t.test("bad values fall back or clamp", function()
  local cfg = assert(C.decode([[return {
    match_window_ms = 99999, window_mode = "nonsense",
    lanes = { { steps = { 0, 99, -1, 2.5, "x", 8 }, calibration_ms = "wat", name = "" } },
  }]]))
  t.eq(cfg.match_window_ms, 200)
  t.eq(cfg.window_mode, "hits32")
  t.eq(table.concat(cfg.lanes[1].steps, ","), "0,8")
  t.eq(cfg.lanes[1].calibration_ms, 0)
  t.eq(cfg.lanes[1].name, "Kick")
end)

t.test("binary chunks are refused", function()
  t.eq((C.decode("\27Lua")), nil)
end)

t.test("garbage gives an error, not a crash", function()
  t.eq((C.decode("this is not lua {")), nil)
end)
