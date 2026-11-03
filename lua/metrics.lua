-- metrics.lua: rolling per-lane statistics. Bias and spread stay separate:
-- a steady +15 ms snare has mean +15 and sd ~0; a -20/+20 snare has mean 0 and
-- sd ~20. Neither is collapsed into a single score.

local M = {}

M.CAPACITY = 512

function M.new_history()
  return { first = 1, last = 0 }
end

function M.push(h, entry)
  h.last = h.last + 1
  h[h.last] = entry
  if h.last - h.first + 1 > M.CAPACITY then
    h[h.first] = nil
    h.first = h.first + 1
  end
end

function M.count(h) return h.last - h.first + 1 end

function M.latest(h, n)
  local out = {}
  for i = math.max(h.first, h.last - n + 1), h.last do out[#out + 1] = h[i] end
  return out
end

-- Entries at or after min_played_s. played_s is monotonic played time, so the
-- "last N bars" window stays correct across loop wraps.
function M.since(h, min_played_s)
  local out = {}
  for i = h.first, h.last do
    if h[i].played_s >= min_played_s then out[#out + 1] = h[i] end
  end
  return out
end

-- Every field except n is nil when undefined; callers must show "--", never 0.
function M.compute(entries)
  local n = #entries
  local result = { n = n }
  if n == 0 then return result end

  local sum, sum_abs, in10, in20 = 0, 0, 0, 0
  for _, e in ipairs(entries) do
    local v = e.corrected_ms
    sum = sum + v
    local a = math.abs(v)
    sum_abs = sum_abs + a
    if a <= 10 then in10 = in10 + 1 end
    if a <= 20 then in20 = in20 + 1 end
  end
  local mean = sum / n
  result.mean = mean
  result.mae = sum_abs / n
  result.pct10 = 100 * in10 / n
  result.pct20 = 100 * in20 / n

  if n >= 2 then
    local ss = 0
    for _, e in ipairs(entries) do
      local d = e.corrected_ms - mean
      ss = ss + d * d
    end
    result.sd = math.sqrt(ss / (n - 1))
  end
  return result
end

-- Accent/ghost dynamics in dB relative to full scale at the detector. The gap
-- between them doesn't depend on mic gain. Undefined values stay nil, as above.
-- A clipped accent reads quieter than it was, so the gap would be understated.
function M.dynamics(entries)
  local function group(level)
    local sum, n, clipped = 0, 0, 0
    for _, e in ipairs(entries) do
      if e.level == level then
        sum = sum + e.peak_db
        n = n + 1
        if e.clipped then clipped = clipped + 1 end
      end
    end
    local out = { n = n, clipped = clipped }
    if n == 0 then return out end
    out.mean = sum / n
    if n >= 2 then
      local ss = 0
      for _, e in ipairs(entries) do
        if e.level == level then ss = ss + (e.peak_db - out.mean) ^ 2 end
      end
      out.sd = math.sqrt(ss / (n - 1))
    end
    return out
  end
  local accent, ghost = group("accent"), group("ghost")
  local gap
  if accent.mean and ghost.mean then gap = accent.mean - ghost.mean end
  return { accent = accent, ghost = ghost, gap = gap }
end

return M
