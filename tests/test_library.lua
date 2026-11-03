local t = require("harness")
local L = require("library")
local C = require("config")
local Patterns = require("patterns")

local function list(x) return table.concat(x, ",") end
local function steps(cfg, lane) return list(cfg.lanes[lane].steps) end

local function rudiment(key)
  for _, r in ipairs(L.RUDIMENTS) do
    if r.key == key then return r end
  end
end

t.test("ten rudiments, each a valid bar", function()
  t.eq(#L.RUDIMENTS, 10)
  local keys = {}
  for _, r in ipairs(L.RUDIMENTS) do
    t.truthy(L.valid_sticking(r.sticking), r.name)
    t.truthy(not keys[r.key], "duplicate " .. r.key)
    keys[r.key] = true
    t.truthy(r.sticking:find("%u"), r.name .. " has no accent")
    t.truthy(r.sticking:find("%l"), r.name .. " has no ghost")
  end
end)

t.test("rudiment stroke counts match their names", function()
  local function strokes(key) return #rudiment(key).sticking:gsub("-", "") end
  t.eq(strokes("five-stroke-roll"), 10) -- two rolls per bar
  t.eq(strokes("seven-stroke-roll"), 14)
  t.eq(strokes("nine-stroke-roll"), 9)
  t.eq(strokes("thirteen-stroke-roll"), 13)
  t.eq(strokes("single-stroke-four"), 8)
  t.eq(strokes("single-stroke-seven"), 14)
end)

t.test("stickings and accents are the standard ones", function()
  t.eq(rudiment("single-paradiddle").sticking, "RlrrLrllRlrrLrll")
  t.eq(rudiment("triple-paradiddle").sticking:upper(), "RLRLRLRRLRLRLRLL")
  t.eq(rudiment("double-stroke-roll").sticking:upper(), "RRLLRRLLRRLLRRLL")
end)

t.test("a rudiment sets accents and ghosts, and mutes other lanes", function()
  local cfg = C.defaults()
  assert(L.apply(cfg, "rudiment:five-stroke-roll", {}))
  t.eq(steps(cfg, 2), "0,1,2,3,4,8,9,10,11,12")
  t.eq(list(cfg.lanes[2].accents), "4,12")
  t.eq(list(cfg.lanes[2].ghosts), "0,1,2,3,8,9,10,11")
  t.eq(cfg.lanes[2].scoring, true)
  t.eq(steps(cfg, 1), "")
  t.eq(cfg.lanes[1].scoring, false)
  t.eq(cfg.active_pattern.sticking, "rrllR---llrrL---")
end)

t.test("a rudiment goes on the chosen lane", function()
  local cfg = C.defaults()
  cfg.rudiment_lane = 4
  assert(L.apply(cfg, "rudiment:single-paradiddle", {}))
  t.eq(#cfg.lanes[4].steps, 16)
  t.eq(#cfg.lanes[2].steps, 0)
end)

t.test("clicking a step cycles off, normal, accent, ghost, off", function()
  local lane = { steps = {}, accents = {}, ghosts = {} }
  L.cycle_step(lane, 4)
  t.eq(list(lane.steps), "4")
  t.eq(L.level_map(lane)[4], nil)
  L.cycle_step(lane, 4)
  t.eq(L.level_map(lane)[4], "accent")
  L.cycle_step(lane, 4)
  t.eq(L.level_map(lane)[4], "ghost")
  L.cycle_step(lane, 4)
  t.eq(list(lane.steps), "")
  t.eq(L.has_dynamics(lane), false)
end)

t.test("loading a pattern leaves the kit's settings alone", function()
  local cfg = C.defaults()
  cfg.lanes[2].calibration_ms = 12.5
  cfg.lanes[2].calibrated = true
  cfg.lanes[2].name = "My snare"
  assert(L.apply(cfg, "rudiment:single-stroke-roll", {}))
  assert(L.apply(cfg, "groove:rock", {}))
  t.eq(cfg.lanes[2].calibration_ms, 12.5)
  t.eq(cfg.lanes[2].calibrated, true)
  t.eq(cfg.lanes[2].name, "My snare")
end)

t.test("rock beat restores the default groove, with no dynamics left over", function()
  local cfg = C.defaults()
  local want1, want2, want3 = steps(cfg, 1), steps(cfg, 2), steps(cfg, 3)
  assert(L.apply(cfg, "rudiment:single-stroke-roll", {}))
  assert(L.apply(cfg, "groove:rock", {}))
  t.eq(steps(cfg, 1), want1)
  t.eq(steps(cfg, 2), want2)
  t.eq(steps(cfg, 3), want3)
  t.eq(L.has_dynamics(cfg.lanes[2]), false)
  t.eq(cfg.lanes[1].scoring, true)
  t.eq(cfg.active_pattern.sticking, nil)
end)

t.test("the ghost note groove marks only the snare", function()
  local cfg = C.defaults()
  assert(L.apply(cfg, "groove:ghost-notes", {}))
  t.eq(list(cfg.lanes[2].accents), "4,12")
  t.eq(list(cfg.lanes[2].ghosts), "7,9,15")
  t.eq(L.has_dynamics(cfg.lanes[1]), false)
end)

t.test("editing a loaded groove doesn't change the built-in", function()
  local cfg = C.defaults()
  assert(L.apply(cfg, "groove:ghost-notes", {}))
  L.cycle_step(cfg.lanes[2], 1)
  cfg.lanes[1].steps[1] = 5
  assert(L.apply(cfg, "groove:ghost-notes", {}))
  t.eq(steps(cfg, 2), "4,7,9,12,15")
  t.eq(steps(cfg, 1), "0,6,8")
end)

t.test("unknown patterns change nothing", function()
  local cfg = C.defaults()
  local before = steps(cfg, 1)
  for _, id in ipairs({ "rudiment:nope", "groove:nope", "user:nope", "junk", "" }) do
    local ok, err = L.apply(cfg, id, {})
    t.eq(ok, nil)
    t.truthy(err)
  end
  t.eq(steps(cfg, 1), before)
end)

t.test("save, change, reload: a groove comes back exactly, dynamics included", function()
  local cfg, user = C.defaults(), {}
  cfg.lanes[1].steps = { 0, 3, 6, 10 }
  cfg.lanes[1].accents = { 0 }
  cfg.lanes[1].ghosts = { 3, 6 }
  cfg.lanes[3].scoring = false
  t.eq(L.save_user(cfg, user, "  Funk 1 "), "Funk 1")
  t.eq(cfg.active_pattern.id, "user:Funk 1")
  assert(L.apply(cfg, "groove:rock", user))
  t.eq(steps(cfg, 1), "0,8")
  assert(L.apply(cfg, "user:Funk 1", user))
  t.eq(steps(cfg, 1), "0,3,6,10")
  t.eq(list(cfg.lanes[1].accents), "0")
  t.eq(list(cfg.lanes[1].ghosts), "3,6")
  t.eq(cfg.lanes[3].scoring, false)
  t.eq(cfg.active_pattern.name, "Funk 1")
end)

t.test("a saved groove is a copy: later edits don't change it", function()
  local cfg, user = C.defaults(), {}
  L.save_user(cfg, user, "Mine")
  cfg.lanes[1].steps[1] = 5
  t.eq(user[1].lanes[1].steps[1], 0)
end)

t.test("saving an existing name replaces it, without a duplicate", function()
  local cfg, user = C.defaults(), {}
  L.save_user(cfg, user, "Mine")
  cfg.lanes[1].steps = { 2 }
  L.save_user(cfg, user, "Mine")
  t.eq(#user, 1)
  t.eq(user[1].lanes[1].steps[1], 2)
end)

t.test("empty names are refused", function()
  local cfg, user = C.defaults(), {}
  local name, err = L.save_user(cfg, user, "   ")
  t.eq(name, nil)
  t.truthy(err)
  t.eq(#user, 0)
end)

t.test("the saved-groove limit refuses new names but allows overwrites", function()
  local cfg, user = C.defaults(), {}
  for i = 1, L.MAX_USER_GROOVES do L.save_user(cfg, user, "g" .. i) end
  local name, err = L.save_user(cfg, user, "one more")
  t.eq(name, nil)
  t.truthy(err)
  t.eq(L.save_user(cfg, user, "g1"), "g1")
end)

t.test("deleting the active groove keeps the grid but drops the name", function()
  local cfg, user = C.defaults(), {}
  cfg.lanes[1].steps = { 7 }
  L.save_user(cfg, user, "Mine")
  t.eq(L.delete_user(cfg, user, "Mine"), true)
  t.eq(#user, 0)
  t.eq(steps(cfg, 1), "7")
  t.eq(cfg.active_pattern.id, nil)
  t.eq(L.delete_user(cfg, user, "Mine"), false)
end)

t.test("grooves survive the file format, including awkward names", function()
  local cfg, user = C.defaults(), {}
  cfg.lanes[2].accents = { 4 }
  L.save_user(cfg, user, 'Say "hi": 100%')
  local back = L.sanitize_user(assert(C.parse(C.encode(user))))
  t.eq(#back, 1)
  t.eq(back[1].name, 'Say "hi": 100%')
  assert(L.apply(cfg, 'user:Say "hi": 100%', back))
  t.eq(steps(cfg, 2), "4,12")
  t.eq(list(cfg.lanes[2].accents), "4")
end)

t.test("bad entries in a hand-edited file are dropped", function()
  local back = L.sanitize_user({
    "junk", { name = "", lanes = {} }, { name = "no lanes" },
    { name = "ok", lanes = { { steps = { 0, 99, 2.5, "x" }, accents = { 0, 5 }, scoring = "yes" } } },
    { name = "ok", lanes = {} },
  })
  t.eq(#back, 1)
  t.eq(list(back[1].lanes[1].steps), "0")
  t.eq(list(back[1].lanes[1].accents), "0") -- 5 isn't a step
  t.eq(back[1].lanes[1].scoring, false)
  t.eq(#back[1].lanes, 8)
  t.eq(#L.sanitize_user("nonsense"), 0)
end)

t.test("settings keep the active pattern, dynamics and rudiment lane", function()
  local cfg = C.defaults()
  cfg.rudiment_lane = 4
  L.apply(cfg, "rudiment:single-paradiddle", {})
  local back = assert(C.decode(C.encode(cfg)))
  t.eq(back.active_pattern.id, "rudiment:single-paradiddle")
  t.eq(back.active_pattern.sticking, "RlrrLrllRlrrLrll")
  t.eq(back.rudiment_lane, 4)
  t.eq(list(back.lanes[4].accents), "0,4,8,12")
end)

t.test("settings saved before patterns existed are labelled honestly", function()
  local back = assert(C.decode("return { lanes = { { steps = { 1, 2 } } } }"))
  t.eq(back.active_pattern.id, nil)
  t.eq(back.active_pattern.name, "Custom")
  t.eq(back.rudiment_lane, 2)
  t.eq(#back.lanes[1].accents, 0)
end)

t.test("bad sticking, lanes and dynamics in settings fall back", function()
  local back = assert(C.decode([[return { rudiment_lane = 99,
    lanes = { { steps = { 1, 2 }, accents = { 1, 9 }, ghosts = "x" } },
    active_pattern = { id = "rudiment:x", name = "X", sticking = "RLXX" } }]]))
  t.eq(back.rudiment_lane, 8)
  t.eq(list(back.lanes[1].accents), "1")
  t.eq(#back.lanes[1].ghosts, 0)
  t.eq(back.active_pattern.sticking, nil)
end)

t.test("pickers list rudiments, grooves, then yours", function()
  local cfg, user = C.defaults(), {}
  L.save_user(cfg, user, "Mine")
  local groups = L.groups(user)
  t.eq(groups[1].title, "Rudiments")
  t.eq(#groups[1].items, 10)
  t.eq(groups[2].items[1].id, "groove:rock")
  t.eq(groups[2].items[2].id, "groove:ghost-notes")
  t.eq(groups[3].items[1].id, "user:Mine")
  t.truthy(Patterns.STEPS == 16)
end)
