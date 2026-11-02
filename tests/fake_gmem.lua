-- Lua model of the JSFX writer side, for protocol and session tests.
local P = require("protocol")

local F = {}
F.__index = F

function F.new()
  local self = setmetatable({ mem = {} }, F)
  self.read = function(i) return self.mem[i] or 0 end
  self.write = function(i, v) self.mem[i] = v end
  self.write(P.G_MAGIC, P.MAGIC)
  self.write(P.G_VERSION, P.VERSION)
  return self
end

function F:publish(lane, kind, a, b, c, d, e)
  local base = P.lane_base(lane)
  local s = self.read(base + P.H_SEQ) + 1
  local rb = P.record_base(lane, s)
  self.write(rb + P.R_COMMIT, -s)
  self.write(rb + P.R_A, a)
  self.write(rb + P.R_B, b)
  self.write(rb + P.R_C, c or 0)
  self.write(rb + P.R_SEG, self.seg_of(self, lane))
  self.write(rb + P.R_KIND, kind)
  self.write(rb + P.R_D, d or 0)
  self.write(rb + P.R_E, e or 0)
  self.write(rb + P.R_COMMIT, s)
  self.write(base + P.H_SEQ, s)
end

-- The JSFX counts segments privately and copies the id to the header per block.
function F:seg_of(lane)
  self.segments = self.segments or {}
  return self.segments[lane] or 0
end

-- Per-block status, as @block writes it.
function F:block(lane, pos_s, pos_qn, play_state)
  local base = P.lane_base(lane)
  local hb = self.read(base + P.H_HEARTBEAT)
  self.write(base + P.H_HEARTBEAT, hb + 1)
  self.write(base + P.H_SEGMENT, self:seg_of(lane))
  self.write(base + P.H_BLOCK_S, pos_s)
  self.write(base + P.H_BLOCK_QN, pos_qn)
  self.write(base + P.H_PLAY_STATE, play_state or 1)
  self.write(base + P.H_TEMPO, 120)
  self.write(base + P.H_TS_NUM, 4)
  self.write(base + P.H_TS_DENOM, 4)
  self.write(base + P.H_SRATE, 48000)
  self.write(base + P.H_HEARTBEAT, hb + 2)
end

function F:hit(lane, t, qn, peak)
  self:publish(lane, P.KIND_HIT, t, qn or t * 2, peak or 0.5, 0, 0)
end

function F:start_segment(lane, pos_s, pos_qn, prev_s, prev_qn, continuous)
  self.segments = self.segments or {}
  self.segments[lane] = self:seg_of(lane) + 1
  self:publish(lane, P.KIND_SEG_START, pos_s, pos_qn, prev_s or 0, prev_qn or 0, continuous and 1 or 0)
end

function F:end_segment(lane, pos_s, pos_qn)
  self:publish(lane, P.KIND_SEG_END, pos_s, pos_qn, 0, 0, 0)
end

return F
