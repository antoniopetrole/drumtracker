-- patterns.lua: the 16-step expected-note grid for one 4/4 bar.
-- A step is a 16th note: 0.25 quarter notes. Steps are 0-based, matching the
-- docs ("kick on steps 0 and 8").

local M = {}

M.STEPS = 16
M.QN_PER_STEP = 0.25
M.QN_PER_BAR = 4

function M.empty()
  local p = {}
  for i = 0, M.STEPS - 1 do p[i] = false end
  return p
end

function M.from_steps(list)
  local p = M.empty()
  for _, s in ipairs(list) do
    if s >= 0 and s < M.STEPS then p[math.floor(s)] = true end
  end
  return p
end

function M.to_steps(pattern)
  local out = {}
  for i = 0, M.STEPS - 1 do
    if pattern[i] then out[#out + 1] = i end
  end
  return out
end

function M.default_kick() return M.from_steps({ 0, 8 }) end
function M.default_snare() return M.from_steps({ 4, 12 }) end
function M.default_hat() return M.from_steps({ 0, 2, 4, 6, 8, 10, 12, 14 }) end

-- Absolute step 0 is QN `origin_qn`.
function M.step_to_qn(abs_step, origin_qn)
  return origin_qn + abs_step * M.QN_PER_STEP
end

-- Next absolute step >= abs_step that the pattern expects, or nil if empty.
function M.next_expected(pattern, abs_step)
  for offset = 0, M.STEPS - 1 do
    local candidate = abs_step + offset
    if pattern[candidate % M.STEPS] then return candidate end
  end
  return nil
end

-- Previous absolute step < abs_step that the pattern expects, or nil if empty.
function M.prev_expected(pattern, abs_step)
  for offset = 1, M.STEPS do
    local candidate = abs_step - offset
    if pattern[candidate % M.STEPS] then return candidate end
  end
  return nil
end

return M
