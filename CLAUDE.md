# Claude Build Instructions — REAPER Live Drum Groove Monitor

> **Your assignment:** Build a working, real-time, multichannel acoustic drum timing trainer for REAPER. This document is an implementation brief for Claude Code in VS Code. **Write the code, tests, setup instructions, and an example REAPER workflow; do not stop after proposing a plan.** If REAPER is unavailable in your environment, implement everything testable without it and clearly distinguish verified functionality from functionality that requires testing inside REAPER.

## 1. Product vision

I am a drummer using an acoustic kit, close microphones, an audio interface, and REAPER on Windows. I want to see **live, per-drum timing feedback** while I play to REAPER's click.

For example, at 120 BPM, I play a straightforward eighth-note rock groove. My interface channels are assigned to drums (kick, snare, hi-hat, etc.). The monitor detects hits from the **live incoming audio**, understands which beats/subdivisions each drum is *supposed* to play, and continuously shows whether each hit was early or late by how many milliseconds.

I am especially interested in whether each limb is consistently early/late and how tight its timing distribution is. **Do not automatically treat an intentional, consistently delayed snare as worse than a snare fluctuating unpredictably around zero.** Show both grid alignment and consistency as separate measurements.

**Hard requirement:** The feedback must update while I play, **without requiring a recording or offline analysis**. REAPER is the audio host. Claude Code/VS Code is the development environment; it is not the runtime UI.

## 2. Stack and architectural decisions

Use the simplest robust, REAPER-native architecture:

- **JSFX (EEL2)** on each monitored input track: detect audio onsets in REAPER's real-time audio thread; timestamp each hit using the transport position at the audio block plus the sample offset; publish events.
- **Named JSFX global shared memory** via `options:gmem=LiveDrumGrooveMonitor_v1` and `gmem[]`: communicate events from multiple detector instances to one UI script.
- **Lua ReaScript + ReaImGui**: receive events with `reaper.gmem_attach`, `reaper.gmem_read` and `reaper.gmem_write`; assign drum names/patterns; calculate hit-to-grid errors and rolling stats; draw the live dashboard and persist configuration.
- **Pure Lua modules** for time-grid matching, metrics, and event-buffer decoding so they can be unit-tested without REAPER.
- No Python server, audio loopback application, browser UI, external VST, or custom compiled extension in v1.

**Why this split?** `reaper.defer()` is suitable for drawing a responsive dashboard, not for sample-by-sample signal detection or accurate timestamping. Do not calculate onset time using the UI callback time or `os.clock()`.

Design for up to **8 independent mic lanes**, but make **kick, snare, and hi-hat** a polished, working MVP. One JSFX instance per monitored track is preferred over complicated automatic multichannel routing. Provide clear setup for one mono hardware input per REAPER track, record-arm + input monitoring, and the correct ASIO device on Windows.

## 3. Precise timing requirements

### 3.1 Use the correct audio clock

JSFX `beat_position` and `play_position` represent **the last audio-block boundary**, not an automatically advancing per-sample clock. Maintain a sample counter that starts at zero in `@block` and advances in `@sample`.

Within a block (constant-tempo, 4/4 MVP), calculate:

```text
sample_offset = 0, 1, ... samplesblock - 1
hit_project_seconds = play_position + sample_offset / srate
hit_qn = beat_position + sample_offset * tempo / (60 * srate)
```

Here `qn` denotes **quarter-note beat position**. Verify `@block` and `@sample` ordering and avoid an off-by-one counter error. Preserve floating-point precision until presentation.

The timing model must properly handle play, record, pause, stop, seek, restart, and loop wraps. Detect transport jumps/discontinuities and start a new measurement segment or session as appropriate; never connect unrelated event timelines. Default to analyzing only while the transport is playing/recording. Document and test any limitations around REAPER preroll/count-in and punch recording.

**Important:** Physical/input and output/monitoring latency can bias the measured offset, even when the event timestamps are sample-resolved. Provide an adjustable **signed per-lane timing calibration in milliseconds** (initially 0), clear guidance on validating calibration with a physical audio loopback or recorded reference impulse, and label uncalibrated results as such. Do not claim sub-millisecond *real-world* accuracy just because the sample interval is small. Be deliberate about input PDC, track FX latency, the click-to-output path, and where the JSFX sits in the FX chain. The detector should be early in the chain, before latency-inducing plugins.

### 3.2 Compare hits against an *expected drum pattern*

Do **not** merely snap each kick/snare/hat hit to the nearest arbitrary beat or subdivision; different drums have different expected notes.

Implement a configurable 16-step pattern grid in 4/4 (one step = 16th note = 0.25 quarter notes), with a default one-bar rock pattern:

- **Kick:** steps 0 and 8 (beats 1 and 3).
- **Snare:** steps 4 and 12 (beats 2 and 4).
- **Hi-hat:** steps 0, 2, 4, 6, 8, 10, 12, 14 (eighth notes).

Allow changing the 16 steps for each lane in the dashboard, muting a lane's scoring, and setting a pattern-origin/reference bar. Start with a fixed 4/4, constant-tempo project and explicitly document that initial limitation; do not silently generate wrong answers for different meters or variable tempo. Extensions for changing tempo/meter and multiple bars can be postponed.

For each onset, identify the nearest **unmatched expected note for that lane** inside a configurable matching window (initial default **±80 ms**, clamped to avoid overlapping adjacent expected-note windows). Match each expected note to **at most one** real hit. Calculate:

```text
signed_error_ms = (hit_project_seconds - target_project_seconds) * 1000
corrected_error_ms = signed_error_ms - lane_calibration_ms
```

Negative = early, positive = late, zero = on-grid. Keep the sign convention everywhere. Use actual target QN-to-project-time conversion where available (`reaper.TimeMap2_QNToTime`) rather than assuming all targets follow a zero-second origin in every project. Clearly separate timestamp conversion, calibration, and matching logic. Where Lua handles matching in real time, compensate hit timestamps *before matching* if that is necessary for the chosen calibration convention; test that calibration cannot mistakenly turn good hits into extras.

Handle and report:
- On-time / early / late hits.
- **Missed expected notes**, once the acceptable late window expires.
- **Extra/unmatched onsets**, including accidental ghost/bleed candidates, separately from scored notes.
- Double-trigger suppression and one-to-one matching.
- Boundary behavior near bar/loop transitions.

Don't let an off-pattern kick that happens near the next bar incorrectly match a different expected hit. An online event-matching strategy with a bounded pending window is preferable to retroactively changing older scores in confusing ways.

### 3.3 Onset detection

Create a lightweight, deterministic detector for **isolated close mics**:

- Rectified sample/envelope following or an equivalent transient detector.
- Adjustable per-lane trigger threshold/sensitivity.
- Adjustable attack/release or hysteresis; avoid multiple events from one drum strike.
- A configurable retrigger interval (e.g., 35–100 ms depending on the lane), but ensure it can handle intended rapid notes.
- Report trigger intensity/peak and detector state for diagnostics.
- Pass incoming audio through unchanged by default; **do not generate audible clicks or change mic audio**.

Start with reliable single-lane triggering, then three-lane detection. Snare bleed into hi-hat mics is an important real-world issue: provide per-lane filters/threshold tuning or an optional bleed-candidate diagnostic. **Do not blindly discard simultaneously occurring hits across drums**; a snare and hi-hat often occur at precisely the same intended time. False positives vs. missed soft strokes should be visible and tunable.

Prefer a simple working approach over premature DSP sophistication. State any detection delay/lookahead and how timestamps are compensated. If initial threshold detection is inaccurate, optionally use a short circular attack-history buffer and a post-trigger confirmation window to backdate the onset to the first attack; document the associated few milliseconds of display delay.

## 4. Shared-memory protocol (implement and document)

Avoid one global write index shared across tracks; separate instances could overwrite each other's events. Use **one fixed region per lane** with a single writer for that lane.

Suggested protocol (feel free to improve it, but keep a single documented `protocol.md` mapping used by both JSFX and Lua):

```text
Namespace: LiveDrumGrooveMonitor_v1
Global header: indices 0..1023
  [0] = magic constant
  [1] = protocol version (= 1)
  [2] = UI heartbeat or reserved

MAX_LANES   = 8
LANE_BASE   = 1024 + lane_index * 4096  // lane_index 0..7
RING_SIZE   = 256
RECORD_SIZE = 5

At LANE_BASE:
  +0   = latest_published_sequence
  +1   = JSFX heartbeat / block count
  +2   = latest envelope/level for input indicator
  +3   = last detected event QN position
  +4   = latest transport state/segment identifier
  +5   = reserved
  +16  = event ring, RING_SIZE records of RECORD_SIZE fields

Event record fields:
  [0] = hit_project_seconds
  [1] = hit_qn
  [2] = transient_peak
  [3] = sequence_commit_marker
  [4] = transport_segment_id or flags
```

Publish event fields **before** publishing sequence/index. Optionally set the record commit marker to `-sequence` first, write the other fields, then set it to `+sequence`, then update the lane's latest published sequence. Lua must verify the commit marker before and after reading a record to avoid showing partially written or overwritten data. The design does not require a global lock; allow robust overflow detection when UI falls behind. Each lane must have **exactly one JSFX writer** (warn on duplicate lane assignment). Provide an explicit 'Reset session' command that resets UI-side statistics and safely marks/reinitializes event consumption without relying on clearing live data while JSFX is writing.

Session handling across JSFX `@init`, loop wraps, and reopened projects must be robust. A new process/UI instance must not accidentally replay stale ring events as fresh hits. Consider a monotonic counter plus stream/transport generation ID; document and test the chosen policy. Keep all shared-memory indices within available limits.

The detector JSFX should expose a straightforward **Lane ID** control, with stable 1-based labels (Kick = lane 1, Snare = lane 2, Hi-hat = lane 3) mapped internally to 0-based memory offsets. Ensure REAPER track input routing is configured by the user; the plugin cannot magically know the physical interface port without inspecting REAPER settings.

## 5. Live dashboard (Lua + ReaImGui)

Make a dockable/resizable REAPER window called **Live Drum Groove Monitor**. The UI should remain responsive while monitoring audio and update as quickly as REAPER's deferred UI loop reasonably allows (aim for visually smooth ~30–60 fps; do not promise a hard real-time UI refresh guarantee).

Include:

1. **Status bar:** connection to JSFX shared memory, REAPER transport state, BPM, 4/4 meter, bar position, monitoring status when detectable, calibration warning, last event age.
2. **Drum lane cards:** configurable lane name, input activity meter, latest error as large `+14 ms (LATE)` / `-9 ms (EARLY)`, recent hit history, detected-hit count, misses, extras.
3. **Accuracy scatter plot:** x-axis = signed error ms around zero, colored points per drum, configurable target tolerance band (e.g., ±20 ms), latest ~32 matched hits per lane. This is the most important view for glancing at while playing.
4. **Rolling statistics per lane:** mean **signed** offset (bias), mean **absolute** error, standard deviation of signed offsets (consistency), percentage of matched hits inside ±10/±20 ms, and hit/miss/extra counts. Clearly distinguish bias from spread.
5. **16-step pattern editor:** interactive kick/snare/hat step toggles; later extend to 8 lanes.
6. **Controls:** Start/clear scoring, window size (last 16/32/64 hits or last N bars), matching tolerance, per-lane calibration, thresholds and retrigger settings (at least accessible on each JSFX if live Lua editing of JSFX parameters is not yet wired up), and Save/Load preset.
7. **Diagnostic area:** last event QN/project timestamp, detection peak, live level, last received sequence, dropped-buffer events, suspect triggers, JSFX status.

Show a meaningful no-signal/no-transport state, not fabricated zeros. An accuracy score is optional; if added, the exact formula must be transparent and must not collapse bias and consistency into one unexplained value.

Avoid unnecessary custom UI assets; use ReaImGui's standard drawing APIs and lightweight plots. Provide support for REAPER dark theme. Do not put DSP on the UI thread.

## 6. Configuration and persistence

- Save the lane-to-drum names, patterns, analysis settings, and calibration to a clear human-readable project-local or script-local config format. Lua tables serialized safely or REAPER ExtState/ProjExtState are both acceptable; explain the choice.
- Default should work for an empty REAPER project with three tracks named Kick, Snare, Hi-hat.
- The initial user workflow should not require knowing EEL2, editing memory indices, or manually changing code.
- If the script manages track discovery/FX insertion automatically, make it **opt-in**, reversible, and non-destructive. Do not silently alter existing FX, routing, project tempo, or recordings.
- If auto-configuration is too risky for v1, ship a clear guided manual setup and prioritize the functioning real-time analyzer.

## 7. Suggested repository structure

```text
live-drum-groove-monitor/
├── CLAUDE.md                       # this file
├── README.md                       # user installation, routing, use, troubleshooting
├── docs/
│   ├── protocol.md                 # definitive gmem indices and event semantics
│   ├── timing-and-calibration.md   # clock model, accuracy, known limitations
│   └── validation-checklist.md     # manual tests in REAPER
├── jsfx/
│   └── Live Drum Onset Detector.jsfx
├── lua/
│   ├── Live Drum Groove Monitor.lua # REAPER action entry point
│   ├── protocol.lua
│   ├── timing.lua
│   ├── patterns.lua
│   ├── metrics.lua
│   ├── config.lua
│   └── ui.lua
├── tests/
│   ├── test_timing.lua
│   ├── test_patterns.lua
│   ├── test_metrics.lua
│   └── test_protocol.lua
└── examples/
    └── three-mic-setup.md
```

You may adjust the exact folder structure for proper REAPER resource-path installation or Lua module resolution, but keep DSP, domain logic, shared-memory protocol, and UI separate. Include copy/paste installation instructions for the actual directory structure you choose. If no test runner is installed, write a dependency-free Lua test harness (`lua tests/run.lua`) instead of adding a large dependency.

## 8. Implementation order — actually execute these steps

### Milestone A — minimal end-to-end demo (highest priority)

1. Implement JSFX with one live mono mic input, threshold triggering, accurate sample-offset timestamp, and a one-lane gmem ring buffer.
2. Implement Lua script reading gmem events and printing live hit timestamps/levels to a simple ReaImGui panel.
3. Demonstrate that incoming hits appear **while transport is running and audio is input-monitored**, without recording a take.
4. Add one snare pattern with targets on beats 2 and 4 and show actual signed millisecond offset, calculated from project-time timestamps.
5. Provide test instructions for the user to manually validate those steps in REAPER.

### Milestone B — functional three-mic MVP

1. Expand fixed-lane protocol to 8 lanes with independent writers.
2. Add kick/snare/hat default pattern and editable steps.
3. Implement one-to-one target matching, misses, extras, rolling metrics, and per-lane calibration.
4. Deliver the dashboard (lane cards + timing scatter) and presets.
5. Test with simulated event sequences and synthetic impulse audio; document what still needs a real kit.

### Milestone C — durability and polish

1. Improve fast/soft hit triggering, hysteresis, and bleed diagnostics.
2. Handle stop/play/seek/loop/reset, UI restart, plugin reload, lane ID changes, and missing JSFX instances without stale results.
3. Add setup diagnostics and self-test mode, especially to verify that timing isn't quantized to UI frame or audio-block boundaries.
4. Optimize for low CPU use and no audio dropouts. Ensure UI closure and project unload do not leave stale state or hanging scripts.

**Don't begin with fancy scoring, beat-detection ML, network components, or automatic groove transcription.** Get a measurable, live 3-mic instrument working first.

## 9. Acceptance criteria / tests

**The project is acceptable only if these behaviors are demonstrable.** Unit tests can prove math, but real audio integration must be marked as requiring on-device validation if you cannot run REAPER yourself.

- [ ] Three mono interface inputs can be mapped to Kick, Snare, and Hi-hat via independent REAPER tracks and JSFX lane IDs.
- [ ] With record-arm, input monitoring, and transport running, hits appear live in the UI **without recording**.
- [ ] With 4/4 at 120 BPM, kick targets are at 0/1000 ms modulo the 2000 ms bar, snare at 500/1500 ms, and hat every 250 ms, **relative to a bar-aligned origin**.
- [ ] Synthetic snare at target +15 ms yields a displayed approximately `+15 ms` offset after configured calibration.
- [ ] Synthetic snare at target -20 ms yields approximately `-20 ms`, never `+20 ms`.
- [ ] Identical timing offsets repeated yield low standard deviation even when the mean signed offset is nonzero.
- [ ] No hit for an expected note becomes one miss after its allowable window ends; unrelated bleed is not automatically counted as a correct hit.
- [ ] One loud hit does not produce two hits unless there were two detectable separate attacks; threshold/retrigger behavior is adjustable.
- [ ] A 120 BPM eighth-note hi-hat test correctly expects 250 ms between hits.
- [ ] Tests distinguish false matches/extra hits, nearby adjacent targets, and one-to-one matching.
- [ ] Events arriving after REAPER transport restarts/loops do not get assigned to the previous session or counted twice.
- [ ] Multiple JSFX instances don't corrupt or overwrite one another's ring data.
- [ ] If ReaImGui is missing, the script explains how to install it instead of crashing.
- [ ] Closing/reopening the UI does not produce a flood of stale hits.
- [ ] The UI distinguishes *input/trigger silence* from 'perfect 0 ms timing'.
- [ ] README explains how to use Windows ASIO and how to validate/calibrate end-to-end latency.

**Synthetic testing suggestion:** Use mathematically generated note events for unit tests (e.g., target at 0.500 sec, hit at 0.514 sec) and optionally a REAPER project containing reference impulses on precisely aligned grid positions to validate the JSFX/transport timing path. Do not present a proof from simulated timestamps as proof that microphone/driver latency is calibrated.

## 10. Constraints and engineering standards

- Prioritize correctness in **milliseconds**. Show examples with explicit signed units.
- REAPER JSFX uses EEL2, not ordinary JavaScript. Validate JSFX-specific syntax, sections, and operator semantics.
- REAPER's `beat_position`/`play_position` are **block-based**. Never read them in `@sample` and assume they advanced for each sample.
- ReaScript Lua API functions are `reaper.*`; ReaImGui extension functions are exposed as `reaper.ImGui_*`, subject to installed API version. Check signatures against installed documentation rather than hallucinating.
- Keep event detection and writes lightweight. Avoid costly allocations or unnecessary work per sample.
- The user should never need to install a Python runtime to run this tool.
- Don't overwrite user project files or require destructive routing changes.
- Keep scope explicit: 4/4 + constant BPM first, other time signatures, tempo maps, multi-bar rhythmic phrases, swing templates, and complex flam/ghost-note classification can be future enhancements.
- Be cautious about false precision and timing bias from acoustic mic placement (sound propagation), interface buffer sizes, REAPER monitoring latency, any plugin delay compensation, and threshold-crossing detection.
- **If a REAPER API detail is uncertain, check official docs before implementing it.** Log any remaining uncertainty in the README. No fake test-pass claims.

## 11. References for implementation

Prefer official documentation and installed local API docs:

- REAPER JSFX overview: https://www.reaper.fm/sdk/js/js.php
- JSFX special variables (`@sample`, `tempo`, `play_position`, `beat_position`, `play_state`): https://www.reaper.fm/sdk/js/vars.php
- JSFX shared memory (`options:gmem`): https://www.reaper.fm/sdk/js/basiccode.php
- REAPER ReaScript API (`gmem_attach`, `gmem_read`, `gmem_write`, `TimeMap2_QNToTime`): https://www.reaper.fm/sdk/reascript/reascripthelp
- ReaImGui documentation: https://cfillion.ca/reaper_imgui_doc.html
- ReaImGui source (current location): https://codeberg.org/cfillion/reaimgui

The old GitHub ReaImGui repository was archived in 2026; use its Codeberg location or its ReaPack distribution. Check the available version/signatures in the user's REAPER install.

## 12. What to do when I hand you this file

1. Inspect the workspace and report briefly what already exists.
2. Create the files and implement **Milestone A**, then proceed into Milestone B. Don't stop at a design-only response.
3. Run the offline/unit tests available in the environment; fix failures.
4. Tell me precisely which REAPER resource directories to copy/install files into, how to configure three mic tracks, how to start the action, and how to validate hit timings.
5. Give a concise done/not-done checklist and **clearly identify anything that only I can test inside REAPER with my actual audio interface**.
6. If a REAPER install and UI are available to you, test there. Otherwise, do not imply you tested live input when you could not.

**Definition of done for MVP:** I can hit kick, snare, and hat while listening to REAPER's click; a visible REAPER window updates continuously with signed early/late milliseconds and rolling consistency for each drum, with no offline render or post-recording step.
