# ULTRABASS:9000

ULTRABASS:9000 is a free, open-source macOS app that sends system audio to multiple output devices at
once, each with its own volume, 5-band EQ, crossover filters (high-pass, low-pass, band-pass with real
dB/octave slopes), and delay for time alignment.

macOS's built-in Multi-Output Device can do exactly one of those things: play the same signal to more
than one device. It can't EQ, filter, or delay any of them independently, and once you build one, the
system volume keys stop working. ULTRABASS:9000 adds the missing part: real per-device processing, plus
**acoustic auto-sync**, which plays a sweep from each output in turn, listens back on the Mac's built-in
microphone, and computes the delay needed to line them up at the listening position. Measured
repeatability on the author's own hardware: about 0.2 ms.

No kernel extension, no audio driver, no installer, no `sudo`. It uses a Core Audio process tap
(macOS 14.2+) and a private aggregate device, both userspace APIs.

> Status: multi-output routing, per-device EQ and filters, per-device delay, and acoustic auto-sync are
> built and working, verified on real hardware. Volume-key capture (using the Mac's F10-F12 keys to
> control this app instead of the system) is planned but not built yet. See [ROADMAP.md](ROADMAP.md)
> for the full history.

## How this compares

A fair comparison against the closest real alternatives on macOS, plus one from Linux that's worth
knowing about even though it doesn't run the same way:

| Tool | Multiple outputs at once | Per-device EQ/filters | Per-device delay | Auto-measures the delay | Price |
|---|---|---|---|---|---|
| **ULTRABASS:9000** | Yes | Yes | Yes | Yes (mic + sweep) | Free |
| macOS Multi-Output Device (built in) | Yes | No | No | No | Free |
| SoundSource 6 | Yes (Output Groups) | Only volume is independent per device in a group | No | No | $49 |
| Airfoil | Yes, kept in sync | No | Yes, manual sliders | No | $35 |
| GroundControl SPHERE | Yes, per channel of one interface | Yes, AU per channel | Yes, per channel | No | $199 (2.1) to $499 (9.1.6) |
| CamillaDSP | Yes, with a hand-built aggregate device | Yes, very capable | Yes | No | Free, open source |

Full research, including hardware (miniDSP, AV receivers) and the real forum threads people used to ask
for this, is in [MARKET.md](MARKET.md).

## FAQ

### Why do the volume keys stop working with a Multi-Output Device?

Apple's Multi-Output Device has no single volume it can report to the system, since it's really several
independent devices playing the same stream. macOS doesn't know which one you mean when you press F11,
so it disables the system volume keys rather than guess.

With ULTRABASS:9000 running, the keys are dead for a different reason. The tap mutes the original
playback path (`muteBehavior = .mutedWhenTapped`), so there's no default-device volume left for the
system keys to control in the first place. Per-device gain lives inside the app itself, as a slider per
output. Capturing the volume keys so they control ULTRABASS:9000's own gain instead is on the roadmap,
not shipped.

### Does it need a driver or kernel extension?

No. It uses `CATapDescription`, added in macOS 14.2, to tap system audio in userspace, and a private
Core Audio aggregate device to fan that audio out to the selected outputs. No `.kext`, no
`AudioServerPlugIn` bundle in `/Library/Audio/Plug-Ins/HAL`, no admin installer, no `coreaudiod`
restart. The aggregate device exists only while the app is running and is torn down when it quits.

### Why is there no download?

macOS only grants the microphone/audio-capture permission this app needs (`NSAudioCaptureUsageDescription`)
to a properly signed build. An ad-hoc or unsigned build launches fine and looks like it's working, but
the permission prompt never appears and the tap returns silence forever, which is worse than not
shipping a build at all. Producing a signed release needs an Apple Developer ID, which this project
doesn't have yet. Until then, building it yourself with your own free Apple Development identity is
what makes the permission prompt appear correctly. See "Build and run" below.

### What does acoustic auto-sync measure, and what can't it measure?

It plays a short logarithmic sweep from each selected output device in turn, records the result on the
Mac's built-in microphone, and cross-correlates each recording against a reference sweep to find how
many samples late (or early) that device arrived relative to the others. From that it computes a delay
per device so all of them arrive together at wherever the microphone is sitting, which in practice means
wherever the Mac is sitting.

What it does not do: it is not room correction. It measures arrival time, not frequency response, so it
has nothing to say about how a speaker sounds, only when it arrives. It's also anchored to one position;
move the Mac and the alignment is stale. And it can't measure headphones or earbuds at all, since a
microphone in the room can't hear audio that never left the transducer. Those outputs are reported as
skipped rather than given a guessed-at delay.

### Does it work with Bluetooth speakers and AirPods?

A Bluetooth speaker works like any other output: it can be EQ'd, filtered, delayed, and measured by
acoustic auto-sync, since the sound leaves the speaker and reaches the microphone like anything else.
Two caveats apply to any Bluetooth or wireless device in the mix. First, every output in the set syncs
to the slowest one, and Bluetooth audio commonly adds 150-250 ms of latency on its own, which the whole
system then inherits; that's fine for music, bad for video or games. Second, AirPods and other earbuds
or headphones are outputs a microphone can't hear, so acoustic auto-sync skips them; you can still EQ
and manually delay them, just not measure them automatically.

### Does it handle surround sound or Dolby Atmos?

No. The process tap captures a stereo mixdown of system audio, so there's no 5.1 or Atmos passthrough.
Each output device still gets its own stereo processing chain, which covers stereo speakers, a
subwoofer crossed over from a stereo pair, or a Bluetooth speaker alongside built-in speakers, but not a
full multichannel home-theater layout.

## Build and run

Requires Xcode 26.x and macOS 26+. The Xcode project is generated, not committed:

```sh
brew install xcodegen        # once
xcodegen generate
open UltraBass9000.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project UltraBass9000.xcodeproj -scheme UltraBass9000 -destination 'platform=macOS' build
xcodebuild -project UltraBass9000.xcodeproj -scheme UltraBass9000 -destination 'platform=macOS' test
```

On first launch macOS asks for audio recording permission. Denying it leaves the app running but
silent. Core Audio provides no way to query the answer, so the app watches for sustained digital
silence and tells you what happened.

The build must be signed with a real Development identity (`DEVELOPMENT_TEAM` in `project.yml`).
Ad-hoc signed builds run fine but never trigger the permission prompt, and the tap then returns
nothing but zeros forever.

For scripted testing, `open UltraBass9000.app --args -UB9KAutoStart YES` starts the engine against
the persisted device selection without a click.

## How it works

No kernel extension, no audio driver, no installer, no `sudo`.

```
  every app  →  default output device
                    │
                    │  CATapDescription(stereoGlobalTapButExcludeProcesses: [self])
                    │  muteBehavior = .mutedWhenTapped     ← original path is muted
                    │  isPrivate = true
                    ▼
              [ process tap ]───────────┐
                                        │   private aggregate device
              [ output device A ]───────┤   main + clock = device A
              [ output device B ]───────┤   drift compensation on B, C
              [ output device C ]───────┘   stacked = false
                                        │
                                        ▼
                          one IOProc, one output AudioBuffer per device
                                        │
                        per-device: delay → EQ/filters → gain → meter
```

Two decisions carry most of the design.

**The aggregate is _not_ stacked**, and this one has to be measured, not read. `AudioHardware.h` says a
value of 0 for `kAudioAggregateDeviceIsStackedKey` means "the output streams are all fed the same
data," which reads as though 1 is the per-device layout. On macOS 27.0 with two stereo outputs, the
opposite is true:

| `stacked` | output buffers | channels each |
|-----------|----------------|---------------|
| `true`    | 1              | 2             |
| `false`   | 2              | 2             |

`true` is what Apple's own Multi-Output Device uses (its UID is literally `~:AMS2_StackedOutput:0`) and
it mirrors. `false` gives one `AudioBuffer` per sub-device, which is what makes "different EQ on the
subwoofer than on the headphones" something that can exist at all. The engine re-checks this at runtime
and logs a warning if the HAL ever lays the aggregate out differently.

**Clock drift is the HAL's job.** Each device runs on its own crystal, and they diverge over time.
Rather than writing an adaptive resampler, the first selected device becomes the aggregate's clock and
every other sub-device gets `kAudioSubDeviceDriftCompensationKey`. Sub-*tap* drift compensation is a
separate decision and is deliberately disabled for Bluetooth clocks and virtual tap sources: enabling
it there makes the HAL add or drop a sample every fraction of a second, and that's audible.

## Layout

| Path | What lives there |
|---|---|
| `Sources/UltraBass9000/Audio/Capture/` | Process tap creation and teardown |
| `Sources/UltraBass9000/Audio/DSP/` | Biquad design (RBJ cookbook) and the per-device processing model |
| `Sources/UltraBass9000/Audio/Render/` | Aggregate planning, aggregate device, filter bank, waveform rings, the real-time render callback |
| `Sources/UltraBass9000/Audio/Engine/` | `AudioEngine`, the orchestrator the UI binds to |
| `Sources/UltraBass9000/Audio/Calibration/` | Acoustic auto-sync: sweep playback, microphone recording, cross-correlation |
| `Sources/UltraBass9000/Audio/Support/` | Core Audio property helpers, device model, device registry |
| `Sources/UltraBass9000/Views/` | SwiftUI mixer |
| `Tests/UltraBass9000Tests/` | Pure planning and DSP logic: clock choice, drift rules, buffer layout, filter slopes, sync-signal correlation |

## Conventions

**Real-time safety.** `AggregateOutput.render` runs on Core Audio's real-time thread. It must not
allocate, lock, log, send Objective-C messages, or read a `weak` reference (weak reads take a global
runtime lock). All shared state lives in `RenderControlBlock` as naturally-aligned plain memory.
Lifetime is guaranteed by teardown order rather than by reference counting.

**Filter coefficients are double-buffered.** The UI writes the bank the render thread is not using and
publishes it with one 32-bit store; the render thread reads that index once per callback. A
half-applied update would mix five coefficients from two different filter designs, and the result is
frequently unstable: an unstable biquad squeals at full scale. `BiquadDesign` also refuses to emit
anything non-finite or unstable, falling back to pass-through.

**Teardown order is not negotiable:** `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
`AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. The aggregate references the
tap, and `AudioDeviceDestroyIOProcID` is what guarantees the last callback has returned.

**Swift 5 language mode**, deliberately. See the comment in `project.yml`.

**The Xcode project is generated.** Edit `project.yml`, never the `.xcodeproj`.

## Credits

[FineTune](https://github.com/ronitsingh10/FineTune) (GPL-3) was read as a reference for Core Audio
tap and aggregate-device behaviour. No code was copied; the debt is to its comments, particularly the
explanation of Bluetooth drift-compensation crackle.
