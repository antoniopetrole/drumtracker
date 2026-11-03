-- library.lua: built-in rudiments and grooves, plus the user's saved grooves.
-- A pattern only ever sets lane steps, dynamics and scoring. Names, calibration
-- and thresholds belong to the kit and are never touched by loading one.
-- No REAPER dependency.

local Patterns = require("patterns")

local L = {}

L.MAX_NAME = 32
L.MAX_USER_GROOVES = 200
L.LANES = 8

-- One bar of 16ths. A capital is an accent, lowercase a ghost, - a rest. The letter
-- is the sticking, shown as a reading guide only: a mic can't tell which hand hit.
-- Everything here has to fit the 16th grid, which rules out flams, drags and
-- triplet-based rudiments for now.
L.RUDIMENTS = {
  { key = "single-stroke-roll", name = "Single stroke roll", sticking = "RlrlRlrlRlrlRlrl" },
  { key = "double-stroke-roll", name = "Double stroke roll", sticking = "RrLlRrLlRrLlRrLl" },
  { key = "single-paradiddle", name = "Single paradiddle", sticking = "RlrrLrllRlrrLrll" },
  { key = "triple-paradiddle", name = "Triple paradiddle", sticking = "RlrlrlrrLrlrlrll" },
  { key = "single-stroke-four", name = "Single stroke four", sticking = "rlrL----lrlR----" },
  { key = "single-stroke-seven", name = "Single stroke seven", sticking = "rlrlrlR-lrlrlrL-" },
  { key = "five-stroke-roll", name = "Five stroke roll", sticking = "rrllR---llrrL---" },
  { key = "seven-stroke-roll", name = "Seven stroke roll", sticking = "rrllrrL-llrrllR-" },
  { key = "nine-stroke-roll", name = "Nine stroke roll", sticking = "rrllrrllR-------" },
  { key = "thirteen-stroke-roll", name = "Thirteen stroke roll", sticking = "rrllrrllrrllR---" },
}

L.GROOVES = {
  { key = "rock", name = "Rock beat", lanes = {
    [1] = { steps = { 0, 8 }, scoring = true },
    [2] = { steps = { 4, 12 }, scoring = true },
    [3] = { steps = { 0, 2, 4, 6, 8, 10, 12, 14 }, scoring = true },
  } },
  { key = "ghost-notes", name = "Ghost note groove", lanes = {
    [1] = { steps = { 0, 6, 8 }, scoring = true },
    [2] = { steps = { 4, 7, 9, 12, 15 }, accents = { 4, 12 }, ghosts = { 7, 9, 15 }, scoring = true },
    [3] = { steps = { 0, 2, 4, 6, 8, 10, 12, 14 }, scoring = true },
  } },
}

function L.valid_sticking(s)
  return type(s) == "string" and #s == Patterns.STEPS and not s:find("[^RLrl%-]")
end

-- Sets of steps: returns levels[step] = "accent" | "ghost" | nil (normal).
function L.level_map(lane)
  local levels = {}
  for _, s in ipairs(lane.ghosts or {}) do levels[s] = "ghost" end
  for _, s in ipairs(lane.accents or {}) do levels[s] = "accent" end
  return levels
end

function L.has_dynamics(lane)
  return #(lane.accents or {}) > 0 or #(lane.ghosts or {}) > 0
end

local function sorted_keys(set)
  local out = {}
  for s in pairs(set) do out[#out + 1] = s end
  table.sort(out)
  return out
end

-- Grid click: off > normal > accent > ghost > off.
function L.cycle_step(lane, step)
  local on, accent, ghost = {}, {}, {}
  for _, s in ipairs(lane.steps) do on[s] = true end
  for _, s in ipairs(lane.accents or {}) do accent[s] = true end
  for _, s in ipairs(lane.ghosts or {}) do ghost[s] = true end
  if not on[step] then
    on[step] = true
  elseif accent[step] then
    accent[step] = nil
    ghost[step] = true
  elseif ghost[step] then
    ghost[step] = nil
    on[step] = nil
  else
    accent[step] = true
  end
  lane.steps, lane.accents, lane.ghosts = sorted_keys(on), sorted_keys(accent), sorted_keys(ghost)
end

local function clear_lanes(cfg)
  for i = 1, L.LANES do
    local lane = cfg.lanes[i]
    lane.steps, lane.accents, lane.ghosts = {}, {}, {}
    lane.scoring = false
  end
end

function L.apply_rudiment(cfg, rudiment)
  clear_lanes(cfg)
  local lane = cfg.lanes[cfg.rudiment_lane]
  lane.scoring = true
  for i = 1, #rudiment.sticking do
    local ch = rudiment.sticking:sub(i, i)
    if ch ~= "-" then
      lane.steps[#lane.steps + 1] = i - 1
      if ch:match("%u") then
        lane.accents[#lane.accents + 1] = i - 1
      else
        lane.ghosts[#lane.ghosts + 1] = i - 1
      end
    end
  end
  cfg.active_pattern = {
    id = "rudiment:" .. rudiment.key, name = rudiment.name, sticking = rudiment.sticking,
  }
end

local function copy(list)
  return { table.unpack(list or {}) }
end

local function apply_lanes(cfg, id, name, lanes)
  clear_lanes(cfg)
  for i = 1, L.LANES do
    local src = lanes[i]
    if src then
      local lane = cfg.lanes[i]
      lane.steps, lane.accents, lane.ghosts = copy(src.steps), copy(src.accents), copy(src.ghosts)
      lane.scoring = src.scoring == true
    end
  end
  cfg.active_pattern = { id = id, name = name }
end

-- user: the saved-groove list. Returns ok, or nil and a reason.
function L.apply(cfg, id, user)
  local kind, key = tostring(id):match("^(%a+):(.+)$")
  if kind == "rudiment" then
    for _, r in ipairs(L.RUDIMENTS) do
      if r.key == key then
        L.apply_rudiment(cfg, r)
        return true
      end
    end
  elseif kind == "groove" then
    for _, g in ipairs(L.GROOVES) do
      if g.key == key then
        apply_lanes(cfg, id, g.name, g.lanes)
        return true
      end
    end
  elseif kind == "user" then
    for _, g in ipairs(user) do
      if g.name == key then
        apply_lanes(cfg, id, g.name, g.lanes)
        return true
      end
    end
  end
  return nil, "No such pattern: " .. tostring(id)
end

-- An edit means the grid no longer matches the named pattern or its sticking.
function L.mark_modified(cfg)
  cfg.active_pattern.modified = true
end

function L.clean_name(name)
  if type(name) ~= "string" then return "" end
  local clean = name:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return clean:sub(1, L.MAX_NAME)
end

function L.capture(cfg, name)
  local groove = { name = name, lanes = {} }
  for i = 1, L.LANES do
    local lane = cfg.lanes[i]
    groove.lanes[i] = {
      steps = copy(lane.steps), accents = copy(lane.accents), ghosts = copy(lane.ghosts),
      scoring = lane.scoring,
    }
  end
  return groove
end

function L.find_user(user, name)
  for i, g in ipairs(user) do
    if g.name == name then return i, g end
  end
  return nil
end

-- Saves over a groove of the same name. Returns the cleaned name, or nil and why.
function L.save_user(cfg, user, name)
  name = L.clean_name(name)
  if name == "" then return nil, "Give the groove a name first." end
  local index = L.find_user(user, name)
  if not index and #user >= L.MAX_USER_GROOVES then
    return nil, "That's the limit of saved grooves. Delete one first."
  end
  local groove = L.capture(cfg, name)
  if index then
    user[index] = groove
  else
    user[#user + 1] = groove
    table.sort(user, function(a, b) return a.name:lower() < b.name:lower() end)
  end
  cfg.active_pattern = { id = "user:" .. name, name = name }
  return name
end

function L.delete_user(cfg, user, name)
  local index = L.find_user(user, name)
  if not index then return false end
  table.remove(user, index)
  -- The grid keeps playing what it had, but the name no longer exists.
  if cfg.active_pattern.id == "user:" .. name then
    cfg.active_pattern = { name = name, modified = true }
  end
  return true
end

-- Valid 16-grid steps from untrusted input, optionally only those in `within`.
function L.clean_steps(raw, within)
  local allowed
  if within then
    allowed = {}
    for _, s in ipairs(within) do allowed[s] = true end
  end
  local p = Patterns.empty()
  if type(raw) == "table" then
    for _, s in ipairs(raw) do
      if type(s) == "number" and s >= 0 and s < Patterns.STEPS and s == math.floor(s) then
        local step = math.floor(s)
        if not allowed or allowed[step] then p[step] = true end
      end
    end
  end
  return Patterns.to_steps(p)
end

-- Bad entries in a hand-edited file are dropped, not fatal.
function L.sanitize_user(raw)
  local out, seen = {}, {}
  if type(raw) ~= "table" then return out end
  for _, g in ipairs(raw) do
    if type(g) == "table" and #out < L.MAX_USER_GROOVES then
      local name = L.clean_name(g.name)
      if name ~= "" and not seen[name] and type(g.lanes) == "table" then
        seen[name] = true
        local lanes = {}
        for i = 1, L.LANES do
          local src = type(g.lanes[i]) == "table" and g.lanes[i] or {}
          local steps = L.clean_steps(src.steps)
          lanes[i] = {
            steps = steps,
            accents = L.clean_steps(src.accents, steps),
            ghosts = L.clean_steps(src.ghosts, steps),
            scoring = src.scoring == true,
          }
        end
        out[#out + 1] = { name = name, lanes = lanes }
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- Groups for pickers, in display order: { title, items = { { id, name } } }.
function L.groups(user)
  local rudiments, grooves, mine = {}, {}, {}
  for _, r in ipairs(L.RUDIMENTS) do
    rudiments[#rudiments + 1] = { id = "rudiment:" .. r.key, name = r.name }
  end
  for _, g in ipairs(L.GROOVES) do
    grooves[#grooves + 1] = { id = "groove:" .. g.key, name = g.name }
  end
  for _, g in ipairs(user) do
    mine[#mine + 1] = { id = "user:" .. g.name, name = g.name }
  end
  return {
    { title = "Rudiments", items = rudiments },
    { title = "Grooves", items = grooves },
    { title = "My grooves", items = mine },
  }
end

return L
