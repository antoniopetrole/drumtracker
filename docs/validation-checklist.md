# Validation checklist

Three levels of evidence, kept distinct:

- **Unit**: `lua tests/run.lua`, simulated events.
- **REAPER**: `tests/reaper_integration.lua` in real REAPER 7.09 with ReaImGui 0.10.0.5, with the real JSFX and audio engine on Dummy Audio. Uses internal pulses and generated WAV files, with no microphone or interface.
- **You**: needs your interface and kit. **Nothing below has been tested with live ASIO input.**

## Already covered

| Behaviour | Unit | REAPER |
|---|---|---|
| Snare at +15 ms reads +15 (+15.011 measured) | yes | yes |
| Hat at -20 ms reads -20, never +20 (-19.99 measured) | yes | yes |
| 120 BPM grid: kick 0/1000, snare 500/1500 of 2000 ms, hat every 250 ms | yes | yes |
| Identical offsets: low spread with non-zero bias | yes | yes |
| No hit gives exactly one miss, after the window ends | yes | |
| One-to-one matching, nearest wins, extras separate, adjacent targets | yes | |
| Calibration can't turn good hits into extras | yes | |
| Loop wrap: each hit counted once, no misses at the seam | yes | yes |
| Seek, stop, restart: timelines never join | yes | stop and restart |
| Timing not quantised to blocks: 256, 512, 1024 sample blocks | | yes |
| Generated WAV impulses at +7 ms read +7.007, 8 of 8, none doubled | | yes |
| Ring, 60 Hz tone, fast strokes, soft stroke: one onset each | | yes |
| Below-threshold audio: no onset | | yes |
| Duplicate lane: flagged, can't corrupt, clears on removal | | yes |
| UI reopen: no stale flood | yes | yes |
| Silence shows `--`, not 0 | yes | |
| Missing ReaImGui: explains how to install, doesn't crash | | yes |
| Non-4/4 or tempo changes: refuses to score | yes | |
| Armed, monitoring-only tracks score while playing and while recording, and record no items | | yes |
| Opt-in track creation, and undo removes it | | yes |
| Audio pass-through: source never writes to `splN` | yes | |
| All dashboard tabs render without script errors | | yes |
| Accent and ghost groups, gap, spread, ghost misses and clipping: synthetic hits | yes | yes |
| Ghost straight after a ringing accent is still detected: 36 of 36, with no extras, on generated audio | | yes |
| 10 rudiments with stickings, accents and stroke counts; saved grooves round-trip | yes | |
| Patterns load from the phone page, including awkward groove names; unknown ones change nothing | | yes |
| Phone page, driven in a real browser with phone-size emulation: keeps updating, picker and buttons work, Reset needs two taps, it reports a closed dashboard and a lost connection, no JavaScript errors. All over localhost, not on a real phone or Wi-Fi | | yes |

## You: with your interface and kit

Run these in order. If one fails, later ones will likely fail too.

### A. First contact

- [ ] Script opens, and shows `No detector on this lane` for each lane.
- [ ] Setup > *Add Kick, Snare, Hi-hat tracks*: three tracks appear, Ctrl+Z removes them, then add them again.
- [ ] Each track's input matches the right mic.
- [ ] Status shows `Detectors 3/3`, and `Monitoring 3 tracks`.
- [ ] Your ASIO device is what's open (Preferences > Audio > Device).

### B. Sound check, transport stopped

- [ ] Hitting each drum moves only its own meter, or mostly.
- [ ] Each meter flashes on a hit. Diagnostics' "while stopped" count goes up by one for each hit.
- [ ] Your mic sound is unchanged by the detector: bypass it and compare.

### C. Live, the core requirement

- [ ] With the click on, press play: **hits appear without recording**.
- [ ] Reading while you play feels live: within about a tenth of a second.
- [ ] Hit late on purpose: reads `+`. Hit early on purpose: reads `-`.
- [ ] Stop hitting: counts of Miss go up, and the latest values stay put.
- [ ] Hit a kick where none is expected: Extra goes up.

### C2. Phone page

- [ ] Rerun `tools\install.ps1`, reopen the dashboard, and open `http://<your PC's IP>:8081/drums.html` on your phone.
- [ ] The page matches the dashboard while you play, and feels live enough from the drum stool.
- [ ] Play, Stop and Reset work. Reset needs two taps.
- [ ] Close the dashboard: the page says so, and shows no numbers.
- [ ] Turn off Wi-Fi on the phone: it says it can't reach REAPER, and recovers when Wi-Fi returns.

### C3. Patterns and dynamics

- [ ] Load each kind of pattern from the dashboard and from the phone.
- [ ] Save a groove, restart REAPER, load it again. Check the accents and ghosts came back.
- [ ] Clicking grid steps cycles on, accent, ghost, off. Dashboard's *Pattern* picker and *Undo load* work. These clicks haven't been tested: only the commands behind them.
- [ ] Play the Ghost note groove with obvious accents and very soft ghosts: the gap should read high. Then play them closer in level: it should drop.
- [ ] **Ghosts missed stays at zero** while you play real ghost notes straight after accents. This is the riskiest part on a real snare.
- [ ] Single stroke roll at your real speed: Extra stays at zero, so the wires and ring aren't causing false triggers.
- [ ] A hard hit with a kick or hat, but no snare: does the snare lane score a false ghost?
- [ ] Turn your preamp gain down a few dB: levels should move and the gap shouldn't.

### D. Real-world triggering

- [ ] One hard snare hit makes one Det count, not two. Same for kick and open hat.
- [ ] Fast double strokes, as fast as you actually play: both count.
- [ ] Soft ghost notes: decide whether you want them to count, and tune the threshold.
- [ ] Hard snare hit with the hat silent: hat's "Suspect: bleed" or Det shows how bad the bleed is. Tune it with the threshold and high-pass.
- [ ] Snare and hat together on the backbeat: both score.

### E. Calibration

- [ ] Run the loopback test in [timing-and-calibration.md](timing-and-calibration.md). Spread near zero. Bias near the reported round trip. **If bias differs a lot from the reported figure, trust the loopback, and tell me: it's the most important number here.**
- [ ] After applying it, a loopback run reads about 0 ms.
- [ ] Play to the click and check that the numbers feel honest. Change the buffer size and confirm that bias moves if you don't recalibrate.

### F. Transport edge cases

- [ ] Loop a 2-bar section and play through several passes: no phantom misses at the wrap.
- [ ] Pause, resume, stop, restart, click around the timeline while playing: nothing nonsensical.
- [ ] **Count-in and pre-roll:** turn each on. What does the first bar do? Set "Score from bar" if needed. Untested so far.
- [ ] Set a 3/4 project, or a tempo change: a banner refuses to score.

### G. Durability

- [ ] Close and reopen the dashboard mid-song: no flood of old hits.
- [ ] Change a detector's Lane ID while playing: the warning and the data make sense.
- [ ] Bypass and delete a detector: its lane says so.
- [ ] 20 minutes of playing at your normal buffer size: no dropouts, and REAPER's performance meter is unaffected.
- [ ] Save a preset, change things, load it. Restart REAPER: settings persist.
