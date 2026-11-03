# Example: kick, snare and hi-hat

This assumes close mics on interface inputs 1 (kick), 2 (snare) and 3 (hat). Adjust the inputs to match your wiring.

## Audio device

Options > Preferences > Audio > Device:

- Audio system: **ASIO**, with your interface's driver.
- Enable the input range that covers your mics.
- For playing live, a small buffer feels better (256 samples or less). Changing it means recalibrating.

## Project

1. New project. Set a tempo, say 120 BPM, in 4/4. Keep it constant.
2. Turn on the metronome.
3. Run **Live Drum Groove Monitor**. On the Setup tab, click **Add Kick, Snare, Hi-hat tracks**.

That gives you:

| Track | Input | Detector Lane ID | Default pattern |
|---|---|---|---|
| Kick | Mono 1 | 1 | Beats 1 and 3 (steps 0, 8) |
| Snare | Mono 2 | 2 | Beats 2 and 4 (steps 4, 12) |
| Hi-hat | Mono 3 | 3 | Eighth notes (steps 0, 2, 4, 6, 8, 10, 12, 14) |

Each is record-armed with monitoring on, in monitoring-only record mode, so pressing record can't create takes.

If you hear your mics through REAPER and don't want to (for instance, if you're using direct monitoring from the interface), pull the track faders down. The detector sits before the fader, so detection is unaffected.

## Sound check

With the transport stopped, hit each drum and watch its meter. Set each threshold in the Settings tab so that:

- every real stroke clears it, including the softest you care about, and
- bleed from the other drums doesn't.

Starting points. Your mics and gain will differ:

| Lane | Threshold | Retrigger | Filter on the FX window |
|---|---|---|---|
| Kick | -24 dB | 50 ms | Low-pass 200 Hz, to reject hat and snare bleed |
| Snare | -24 dB | 40 ms | None to start |
| Hi-hat | -30 dB | 30 ms | High-pass 2000 Hz, to reject snare and kick bleed |

Filters add a small delay, so set them before you calibrate.

## Calibrate

Calibrate tab > *Use for all lanes*, to get started. See [the calibration guide](../docs/timing-and-calibration.md) for the loopback test, which is what you want once you start trusting the numbers.

## Play

Press play, and play the groove. What a few bars might look like (these numbers are illustrative):

| Lane | Bias | Spread | What it says |
|---|---|---|---|
| Kick | -2.1 ms | 3.4 ms | Tight and on the grid |
| Snare | +14.8 ms | 3.9 ms | Consistently laid back. Intentional? It's a steady feel, not sloppiness |
| Hi-hat | -1.0 ms | 11.2 ms | Centred, but wandering: this is the limb to work on |

## Going further

- **Different groove:** edit the steps on the Pattern tab. Changes apply straight away. Save it to keep it.
- **Work on dynamics:** load the Ghost note groove or a rudiment, and watch the accent-ghost gap.
- **Skip your lead-in:** Settings > *Score from bar*.
- **Practise a section:** set a loop that's a whole number of bars.
- **Save it:** Settings > Presets.
- **More mics:** add a track and detector with Lane ID 4-8, then set its name and pattern.
- **No kit handy:** Diagnostics > Self-test sends pulses through the detector, to confirm everything's working.
