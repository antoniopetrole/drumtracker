-- protocol.lua: gmem layout and event-stream decoding.
-- docs/protocol.md is the definitive description. Keep it, this file and
-- jsfx/Live Drum Onset Detector.jsfx in step.
-- No REAPER dependency: `read` is injected so tests can fake gmem.

local P = {}

P.NAMESPACE = "LiveDrumGrooveMonitor_v1"
P.MAGIC = 1279539015 -- arbitrary constant; only compared, never interpreted
P.VERSION = 1

P.MAX_LANES = 8
P.GLOBAL_SIZE = 1024
P.LANE_STRIDE = 4096
P.RING_OFFSET = 64
P.RING_SIZE = 256
P.RECORD_SIZE = 8

-- Global header
P.G_MAGIC = 0
P.G_VERSION = 1
P.G_UI_HEARTBEAT = 2
P.G_INSTANCE_COUNTER = 3

-- Lane header offsets
P.H_SEQ = 0            -- latest published sequence (monotonic, 1-based)
P.H_HEARTBEAT = 1      -- seqlock: odd while the owner updates the block fields
P.H_LEVEL = 2          -- detector envelope peak over the last block, linear
P.H_LAST_QN = 3        -- QN of the last onset published while playing
P.H_SEGMENT = 4        -- current transport segment id
P.H_OWNER = 5          -- owning instance id
P.H_BLOCK_S = 6        -- project seconds at start of current block
P.H_BLOCK_QN = 7       -- QN at start of current block
P.H_PLAY_STATE = 8     -- JSFX play_state
P.H_TEMPO = 9
P.H_TS_NUM = 10
P.H_TS_DENOM = 11
P.H_SRATE = 12
P.H_SAMPLESBLOCK = 13
P.H_DUPLICATE = 14     -- samples until the "second instance on this lane" warning lapses
P.H_IDLE_TRIGGERS = 15 -- triggers while the transport was not playing
P.H_LAST_PEAK = 16     -- peak of the most recent trigger (playing or not)
P.H_TRIGGER_TOTAL = 17 -- all triggers, playing or not
P.H_THRESHOLD = 18     -- current threshold, linear
P.H_SELFTEST = 19      -- self-test mode (0 = off)

-- Record fields
P.R_A = 0      -- HIT: project seconds | SEG_*: position in seconds
P.R_B = 1      -- HIT: QN              | SEG_*: position in QN
P.R_C = 2      -- HIT: peak            | SEG_START: previous segment end, seconds
P.R_COMMIT = 3 -- -seq while writing, +seq once complete
P.R_SEG = 4    -- transport segment id
P.R_KIND = 5
P.R_D = 6      -- HIT: sample offset in block | SEG_START: previous end, QN
P.R_E = 7      -- HIT: samples backdated      | SEG_START: 1 if continuous jump

P.KIND_HIT = 0
P.KIND_SEG_START = 1
P.KIND_SEG_END = 2

function P.lane_base(lane_index)
  return P.GLOBAL_SIZE + lane_index * P.LANE_STRIDE
end

function P.record_base(lane_index, seq)
  return P.lane_base(lane_index) + P.RING_OFFSET
    + ((seq - 1) % P.RING_SIZE) * P.RECORD_SIZE
end

function P.is_initialised(read)
  return read(P.G_MAGIC) == P.MAGIC and read(P.G_VERSION) == P.VERSION
end

function P.version_mismatch(read)
  return read(P.G_MAGIC) == P.MAGIC and read(P.G_VERSION) ~= P.VERSION
end

local Reader = {}
Reader.__index = Reader

-- A reader starts at the current head, so anything already in the ring is
-- never replayed: closing and reopening the UI cannot flood it with old hits.
function P.new_reader(read, lane_index)
  local self = setmetatable({}, Reader)
  self.read = read
  self.lane = lane_index
  self.base = P.lane_base(lane_index)
  self.consumed = read(self.base + P.H_SEQ)
  self.dropped = 0
  self.torn = 0
  self.resyncs = 0
  return self
end

-- Skip whatever is in the ring. Used by 'Reset session'; never writes gmem.
function Reader:skip_to_head()
  self.consumed = self.read(self.base + P.H_SEQ)
end

local function read_record(self, seq)
  local read, rb = self.read, P.record_base(self.lane, seq)
  if read(rb + P.R_COMMIT) ~= seq then return nil end
  local rec = {
    seq = seq,
    a = read(rb + P.R_A),
    b = read(rb + P.R_B),
    c = read(rb + P.R_C),
    seg = read(rb + P.R_SEG),
    kind = read(rb + P.R_KIND),
    d = read(rb + P.R_D),
    e = read(rb + P.R_E),
  }
  if read(rb + P.R_COMMIT) ~= seq then return nil end
  return rec
end

-- Returns committed records in order, and how many records were lost since the
-- last call so the caller knows the stream has a gap.
function Reader:poll()
  local latest = self.read(self.base + P.H_SEQ)
  local out, lost = {}, 0

  if latest < self.consumed then
    -- Head went backwards: the shared block was reinitialised.
    self.consumed = latest
    self.resyncs = self.resyncs + 1
    return out, 0
  end

  if latest - self.consumed > P.RING_SIZE then
    local first = latest - P.RING_SIZE
    lost = first - self.consumed
    self.consumed = first
  end

  local seq = self.consumed + 1
  while seq <= latest do
    local rec = read_record(self, seq)
    if rec then
      out[#out + 1] = rec
    else
      -- Overwritten underneath us: the writer lapped the reader.
      lost = lost + 1
      self.torn = self.torn + 1
    end
    seq = seq + 1
  end
  self.consumed = latest
  self.dropped = self.dropped + lost
  return out, lost
end

-- Consistent snapshot of the lane's per-block fields, or nil when the owner was
-- mid-update (the caller just tries again next frame).
function P.read_lane_status(read, lane_index)
  local b = P.lane_base(lane_index)
  local hb = read(b + P.H_HEARTBEAT)
  if hb % 2 ~= 0 then return nil end
  local s = {
    heartbeat = hb,
    seq = read(b + P.H_SEQ),
    level = read(b + P.H_LEVEL),
    last_qn = read(b + P.H_LAST_QN),
    segment = read(b + P.H_SEGMENT),
    owner = read(b + P.H_OWNER),
    block_s = read(b + P.H_BLOCK_S),
    block_qn = read(b + P.H_BLOCK_QN),
    play_state = read(b + P.H_PLAY_STATE),
    tempo = read(b + P.H_TEMPO),
    ts_num = read(b + P.H_TS_NUM),
    ts_denom = read(b + P.H_TS_DENOM),
    srate = read(b + P.H_SRATE),
    samplesblock = read(b + P.H_SAMPLESBLOCK),
    duplicate = read(b + P.H_DUPLICATE),
    idle_triggers = read(b + P.H_IDLE_TRIGGERS),
    last_peak = read(b + P.H_LAST_PEAK),
    trigger_total = read(b + P.H_TRIGGER_TOTAL),
    threshold = read(b + P.H_THRESHOLD),
    selftest = read(b + P.H_SELFTEST),
  }
  if read(b + P.H_HEARTBEAT) ~= hb then return nil end
  return s
end

return P
