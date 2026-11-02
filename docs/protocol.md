# Shared-memory protocol

The definitive map of `gmem[]`, shared by `jsfx/Live Drum Onset Detector.jsfx` and `lua/protocol.lua`. `tests/test_protocol.lua` fails if the constants in those two files drift apart.

- Namespace: `LiveDrumGrooveMonitor_v1`, via `options:gmem=` and `reaper.gmem_attach`. Named gmem has 8 million entries; this uses under 34,000.
- All values are doubles.

## Layout

```text
MAX_LANES   = 8
GLOBAL_SIZE = 1024
LANE_BASE   = 1024 + lane_index * 4096     lane_index = Lane ID - 1
RING_OFFSET = 64                           record area starts at LANE_BASE + 64
RING_SIZE   = 256
RECORD_SIZE = 8
record(seq) = LANE_BASE + 64 + ((seq - 1) % 256) * 8
```

### Global header

| Index | Field | Writer |
|---|---|---|
| 0 | Magic `1279539015` | JSFX |
| 1 | Protocol version `1` | JSFX |
| 2 | UI heartbeat (informational) | Lua |
| 3 | Instance id counter | JSFX |

### Lane header, at `LANE_BASE +`

| Offset | Field |
|---|---|
| 0 | Latest published sequence: monotonic, 1-based |
| 1 | Heartbeat: a seqlock, odd while the per-block fields are being written |
| 2 | Envelope peak over the last block, linear |
| 3 | QN of the last onset published while playing |
| 4 | Current transport segment id |
| 5 | Owning instance id |
| 6, 7 | Project seconds and QN at the start of the current block |
| 8 | JSFX `play_state` |
| 9, 10, 11 | Tempo, `ts_num`, `ts_denom` |
| 12, 13 | `srate`, `samplesblock` |
| 14 | Samples until the "second instance on this lane" warning lapses |
| 15 | Triggers while the transport wasn't playing |
| 16 | Peak of the most recent trigger, playing or not |
| 17 | All triggers, playing or not |
| 18 | Current threshold, linear |
| 19 | Self-test mode, 0 = off |

### Event records

| Offset | HIT | SEG_START | SEG_END |
|---|---|---|---|
| 0 | Project seconds | Position, seconds | Position, seconds |
| 1 | QN | Position, QN | Position, QN |
| 2 | Peak | Previous segment end, seconds | 0 |
| 3 | Commit marker | Commit marker | Commit marker |
| 4 | Segment id | Segment id | Segment id |
| 5 | Kind = 0 | Kind = 1 | Kind = 2 |
| 6 | Sample offset in its block (can be negative when backdated across a block) | Previous segment end, QN | 0 |
| 7 | Samples backdated | 1 if a jump during continuous play | 0 |

## Publishing

The writer sets the marker to `-seq`, writes the fields, sets the marker to `+seq`, then advances the lane's head. The reader checks `marker == seq` before and after copying. A mismatch means the record was overwritten, and it counts as lost, never as data.

The per-block fields use the heartbeat as a seqlock: odd, write, even. A reader that sees an odd value, or a change across its read, discards the snapshot and tries next frame.

Neither side takes a lock.

## One writer per lane

Every instance gets a unique id at `@init`. Each block, the owner stamps its id in the lane header.

- A new instance waits until the lane is free, or the owner's heartbeat has stopped for about 250 ms, before taking over. This covers a deleted, bypassed or re-laned owner.
- If two instances both believe they own a lane, the higher id yields.
- While standing by, an instance keeps detecting but publishes nothing, and raises the duplicate warning. Its FX window also says so.

Tested in REAPER: a duplicate running a different self-test offset couldn't alter the owner's results.

## Segments

A segment is a run of continuous transport. Hits only ever match notes in their own segment, so unrelated timelines never connect.

- `SEG_START` is published on the first playing block, and on any block whose position doesn't follow from the previous one (seek or loop wrap). `SEG_END` is published when play stops or pauses.
- A pending hit is flushed first, so events stay in order.
- Markers travel in the ring with the hits, so they're ordered with them. The Lua side can't confuse a stale status snapshot for a new segment, because only a segment id above any it has seen can start one from status.

## Session policy

| Situation | What happens |
|---|---|
| UI opens or reopens | Reader starts at the current head. Nothing is replayed |
| UI opens mid-song | Scoring starts from the current position. No misses for what it never saw |
| Reset session | UI state clears and the reader skips to head. **Never writes gmem**, so it can't race a detector |
| JSFX reloads, or its Lane ID changes | Sequence and segment continue from gmem, so both stay monotonic. A new `SEG_START` follows |
| UI falls behind by a whole ring | Lost count is reported. The newest 256 records are read |
| Head goes backwards | Treated as reinitialised memory: reader resyncs without replaying |
| Hit with an unknown segment id (marker lost to overflow) | Starts a new segment at that hit |

`@init` sets `ext_noinit = 1`, otherwise REAPER would re-run it on every transport start.
