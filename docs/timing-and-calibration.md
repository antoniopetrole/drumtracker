# Timing and calibration

## The clock

JSFX `play_position` and `beat_position` hold the position at the **start of the audio block**; they don't advance per sample. The detector counts samples from 0 in `@block`:

```text
hit_project_seconds = play_position + sample_offset / srate
hit_qn              = beat_position + sample_offset * tempo / (60 * srate)
```

Tested in REAPER: at block sizes 256, 512 and 1024, self-test pulses land on many different offsets within a block, and measured spread stays around 0.01 ms, far below the block length. Timing is not quantised to blocks or to UI frames.

## From hit to error

```text
signed_error_ms    = (hit_seconds - target_seconds) * 1000
corrected_error_ms = signed_error_ms - lane_calibration_ms
```

Negative is early, positive is late. Targets come from `TimeMap2_QNToTime`, not from assumptions about the project origin.

Calibration is applied to the hit's time **before** matching, so a large latency can't push good hits out of the window and turn them into extras.

## Detection

1. The channel you chose goes through optional detection-only filters, then is rectified into a peak envelope with instant attack.
2. A trigger needs the envelope above threshold and the retrigger interval elapsed. It also needs either that the envelope has fallen below threshold minus hysteresis since the last hit, or that this attack clears a mask set by the previous peak, decaying over `Ring mask decay`. That lets a fast second stroke through while a ringing drum can't re-trigger itself.
3. **Backdating:** threshold crossing lags the true start of the attack, so the detector looks back up to 5 ms for the first sample above a quarter of the threshold that follows at least 1 ms of quiet. With no quiet run, as when a hit lands on a still-ringing drum, it reports the crossing itself, which is slightly late.
4. **Confirm window** (2 ms by default): the hit is published that much later so it can report its true peak. This delays the event only, not its timestamp.

Filters add a small delay of their own that isn't compensated: under 1 ms for a low-pass around 200 Hz, less for higher settings. Calibrate with your filters set.

Tested in REAPER with synthetic audio at -30 dB threshold: a 120 ms-ring 200 Hz tone, a 60 Hz tone, two strokes 100 ms apart and a -24 dB stroke each gave exactly one onset within about 0.1 ms, and a -40 dB stroke gave none. Real drums are messier: only your kit can tell you how good the defaults are.

## Display lag

A result appears once the late window closes: at most the window (80 ms by default) plus 15 ms settling, plus up to one audio block and one UI frame. That's what makes one-to-one matching possible without changing scores you've already seen.

## Latency: why hits read late

The transport position at a block is what REAPER is generating *now*. Follow one click through:

1. REAPER generates a click at position P, and it takes the **output latency** to reach your ears.
2. You hit dead on what you heard.
3. The mic signal takes the **input latency** to get back, plus sound travel from the drum to the mic.
4. By then the transport is past P. The hit's timestamp is about P + output + input.

So uncalibrated, a perfect hit reads late by the round trip. Calibration subtracts it.

| Source | Size | Covered by |
|---|---|---|
| Interface buffers and converters | Often 5-30 ms | Loopback test. Reported latency covers most of it |
| Other plugins on the track | Depends | Keep the detector **first** in the chain. The Diagnostics tab warns if it isn't |
| Hard-wired monitoring path to your ears | Depends | Loopback, if the loopback follows the same output |
| Air: stick to mic, and speaker to ear | About 0.3 ms per 10 cm, 3 ms per metre | Not covered. Headphones remove the speaker part |
| Threshold and backdating | Under a few ms; varies with how hard you hit | Not covered: partly shows up as spread |

Changing your ASIO buffer size or sample rate changes the latency: **recalibrate after changing either**.

## Calibrating

**Reported latency, the quick way.** Calibrate tab > *Use for all lanes*. This trusts the driver's figure, and drivers aren't always honest. Good enough to start.

**Loopback, the real measurement.**

1. Run a cable from an interface **output** to an unused **input**. Turn levels down first.
2. Send REAPER's click to that output (Preferences > Audio > Metronome, or the master routing).
3. Temporarily point a lane's track at that input, and set its pattern to quarter notes: steps 0, 4, 8, 12.
4. Set the threshold so the meter's click peak clears it. Press play. Let about 32 hits build up.
5. Spread should be near zero. If it isn't, fix the threshold first.
6. Bias is now your hardware round trip. Click *Use measured bias*: the bias should settle near 0 ms.
7. Enter that value for your other lanes, and put the track's input back.

Treat the loopback click's own attack shape as a small uncertainty: a soft-edged click triggers a little late.

Reference check for the timing path, no kit needed: the Diagnostics tab's self-test runs pulses through the detector. Offsets you set should read back within a sample or so. This tests the software only, since it skips the interface entirely, so **it says nothing about your latency**.

## What these numbers can honestly claim

Timestamps resolve to a sample, about 0.02 ms. The real chain doesn't reach that. A hit's attack varies with stroke strength and mic placement, and a mic's transient isn't a crisp edge. Treat a couple of milliseconds as the practical floor for absolute numbers. **Comparisons within a lane are more trustworthy than absolute values**, because most of the error is constant.

## Transport behaviour

| Event | Behaviour |
|---|---|
| Stop, pause | Segment ends. Notes whose window was cut short aren't misses |
| Play, record | New segment. Notes before the start position aren't expected. Tested in REAPER, including record on monitoring-only tracks |
| Seek | New segment |
| Loop wrap | New segment. Tested in REAPER: each hit counted once, with no misses at the seam |
| Early hit just before a loop wrap | Scored against the note it was aiming for, when the loop is a whole number of bars |
| Late hit on a note just before the wrap | Lands in the new segment, usually an extra. Larger calibration values make this more likely |
| Tempo or project change | Open notes dropped, matching restarts |
| Playrate other than 1.0 | Refuses to score |
| Count-in, pre-roll, punch | **Untested.** Bars before "Score from bar" are ignored, which should help |
