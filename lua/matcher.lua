-- matcher.lua: online one-to-one matching of onsets to expected notes, for one
-- lane within one transport segment.
--
-- Each onset attaches on arrival to the nearest open target. A target stays
-- pending until its window has fully passed; then its closest candidate becomes
-- the scored hit, any others become extras, and no candidates means a miss.
-- Results are final once emitted, so old scores never change, at the cost of
-- display lag bounded by the late window + settle time.
--
-- All times given to the matcher are raw project seconds.

local Patterns = require("patterns")
local Timing = require("timing")

local M = {}
M.__index = M

-- opts: pattern, qn_to_time, window_ms, calibration_ms, origin_qn, settle_ms,
--       emit(result)
function M.new(opts)
  local self = setmetatable({}, M)
  self.pattern = opts.pattern
  self.qn_to_time = opts.qn_to_time
  self.window_ms = opts.window_ms or 80
  self.calibration_ms = opts.calibration_ms or 0
  self.origin_qn = opts.origin_qn or 0
  self.settle_ms = opts.settle_ms or 15
  self.emit = opts.emit
  self.pending = {}     -- open targets, ascending
  self.next_step = nil  -- next absolute step to enumerate
  self.active = false
  return self
end

-- Half-gap clamp so adjacent targets' windows never overlap.
local function window_for(self, abs_step, target_s)
  local w = self.window_ms / 1000
  local prev = Patterns.prev_expected(self.pattern, abs_step)
  local nxt = Patterns.next_expected(self.pattern, abs_step + 1)
  if prev then
    local gap = target_s - self.qn_to_time(Patterns.step_to_qn(prev, self.origin_qn))
    if gap / 2 < w then w = gap / 2 end
  end
  if nxt then
    local gap = self.qn_to_time(Patterns.step_to_qn(nxt, self.origin_qn)) - target_s
    if gap / 2 < w then w = gap / 2 end
  end
  return w
end

-- Begin a segment at project position start_qn. Notes before that position are
-- not expected, since nobody can have played them in this segment.
function M:begin(start_qn)
  self.pending = {}
  self.active = true
  -- Small tolerance so a target exactly at the start counts.
  local step = math.ceil((start_qn - self.origin_qn) / Patterns.QN_PER_STEP - 1e-6)
  if step < 0 then step = 0 end -- scoring begins at the origin bar
  self.next_step = step
end

-- Make sure every target whose window opens at or before `t` exists.
local function extend(self, t)
  while true do
    local step = Patterns.next_expected(self.pattern, self.next_step)
    if not step then return end -- empty pattern
    local qn = Patterns.step_to_qn(step, self.origin_qn)
    local target_s = self.qn_to_time(qn)
    local w = window_for(self, step, target_s)
    if target_s - w > t then return end
    self.pending[#self.pending + 1] = {
      step = step, qn = qn, time = target_s, window = w, candidates = {},
    }
    self.next_step = step + 1
  end
end

local function emit_extra(self, onset, reason)
  self.emit({
    kind = "extra", reason = reason,
    hit_s = onset.hit_s, hit_qn = onset.hit_qn, peak = onset.peak,
  })
end

local function resolve(self, target)
  local best, best_abs = nil, math.huge
  for _, c in ipairs(target.candidates) do
    local a = math.abs(c.calibrated_s - target.time)
    if a < best_abs then best, best_abs = c, a end
  end
  if best then
    local signed = Timing.signed_error_ms(best.hit_s, target.time)
    self.emit({
      kind = "hit",
      step = target.step, target_qn = target.qn, target_s = target.time,
      hit_s = best.hit_s, hit_qn = best.hit_qn, peak = best.peak,
      signed_ms = signed,
      corrected_ms = Timing.corrected_error_ms(signed, self.calibration_ms),
    })
    for _, c in ipairs(target.candidates) do
      if c ~= best then emit_extra(self, c, "duplicate") end
    end
  else
    self.emit({
      kind = "miss", step = target.step, target_qn = target.qn, target_s = target.time,
    })
  end
end

-- Feed one onset. Calibration is applied before matching, so a large latency
-- cannot push good hits outside the window and turn them into extras.
function M:onset(hit_s, hit_qn, peak)
  if not self.active then return end
  local cal_s = Timing.calibrated_time(hit_s, self.calibration_ms)
  local onset = { hit_s = hit_s, hit_qn = hit_qn, peak = peak, calibrated_s = cal_s }

  if cal_s < self.qn_to_time(self.origin_qn) - self.window_ms / 1000 then
    -- Count-in before the reference bar: neither scored nor an extra.
    self.emit({ kind = "unscored", hit_s = hit_s, hit_qn = hit_qn, peak = peak })
    return
  end

  extend(self, cal_s)

  local best, best_abs = nil, math.huge
  for _, target in ipairs(self.pending) do
    local a = math.abs(cal_s - target.time)
    if a <= target.window and a < best_abs then best, best_abs = target, a end
  end
  if best then
    best.candidates[#best.candidates + 1] = onset
  else
    emit_extra(self, onset, "off_pattern")
  end
end

-- Advance the audio clock, closing every target whose window has fully passed.
-- `now_s` must be read before draining events, so that all onsets earlier than
-- it have been delivered.
function M:advance(now_s)
  if not self.active then return end
  -- Calibration moves onsets earlier, so in raw clock terms the latest possible
  -- onset for a target sits at target + window + calibration.
  local cal = self.calibration_ms / 1000
  local settle = self.settle_ms / 1000
  extend(self, now_s - cal)
  while self.pending[1] do
    local target = self.pending[1]
    if now_s < target.time + target.window + cal + settle then break end
    table.remove(self.pending, 1)
    resolve(self, target)
  end
end

-- End the segment at raw position end_s. Fully elapsed targets resolve as usual.
-- A target reached but with its window cut short scores if it has a candidate;
-- with none it is not a miss, since the player never had the whole window.
-- A target never reached is not a miss either. Its early candidates are returned
-- so that a seamless loop can carry them over (see carry_over).
function M:finish(end_s)
  if not self.active then return {} end
  local cal = self.calibration_ms / 1000
  self:advance(end_s)
  local carry = {}
  for _, target in ipairs(self.pending) do
    -- A note exactly at end_s is the far side of a loop point: not reached.
    if target.time + cal < end_s - 1e-6 then
      if #target.candidates > 0 then resolve(self, target) end
    else
      for _, c in ipairs(target.candidates) do
        carry[#carry + 1] = { onset = c, target_qn = target.qn, target_s = target.time }
      end
    end
  end
  self.pending = {}
  self.active = false
  return carry
end

-- Report onsets from finish() as extras when there is no seamless continuation.
function M:drop_carry(carry)
  for _, item in ipairs(carry) do
    emit_extra(self, item.onset, "off_pattern")
  end
end

-- After a loop wrap: `carry` holds onsets played just before the loop end that
-- attached to a note on the far side of it. If the jump preserves pattern phase
-- that note is the one about to play, so re-attach with the error it had.
-- qn_shift = new position QN - old position QN. Call after begin().
function M:carry_over(carry, qn_shift)
  for _, item in ipairs(carry) do
    local new_qn = item.target_qn + qn_shift
    local abs = (new_qn - self.origin_qn) / Patterns.QN_PER_STEP
    local step = math.floor(abs + 0.5)
    local placed = false
    if math.abs(abs - step) < 1e-6 and step >= 0 and self.pattern[step % Patterns.STEPS] then
      extend(self, self.qn_to_time(new_qn))
      for _, target in ipairs(self.pending) do
        if target.step == step then
          local shift_s = target.time - item.target_s
          local c = item.onset
          target.candidates[#target.candidates + 1] = {
            hit_s = c.hit_s + shift_s,
            hit_qn = c.hit_qn + qn_shift,
            peak = c.peak,
            calibrated_s = c.calibrated_s + shift_s,
          }
          placed = true
          break
        end
      end
    end
    if not placed then emit_extra(self, item.onset, "off_pattern") end
  end
end

return M
