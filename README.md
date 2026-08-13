# UltraBass 9000

Multi-output audio control for macOS: send system audio to several devices at once, with
independent volume, EQ, filtering, delay and metering **per device**.

macOS's built-in Multi-Output Device can do exactly one of those things — play to more than one
device — and even then the volume keys stop working. This fixes that.

> Status: **Phase 1 complete** — system audio is captured and fanned out to multiple devices with
> independent per-device gain, mute and metering, verified on real hardware. EQ, filters, delay and
> waveforms are next. See [ROADMAP.md](ROADMAP.md).

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
silent — Core Audio provides no way to query the answer, so the app watches for sustained digital
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

Two decisions carry most of the design:

**The aggregate is _not_ stacked** — and this one has to be measured, not read.
`AudioHardware.h` says a value of 0 for `kAudioAggregateDeviceIsStackedKey` means "the output
streams are all fed the same data", which reads as though 1 is the per-device layout. On macOS 27.0
with two stereo outputs, the opposite is true:

| `stacked` | output buffers | channels each |
|-----------|----------------|---------------|
| `true`    | 1              | 2             |
| `false`   | 2              | 2             |

`true` is what Apple's own Multi-Output Device uses — its UID is literally `~:AMS2_StackedOutput:0`
— and it mirrors. `false` gives one `AudioBuffer` per sub-device, which is what makes "different EQ
on the subwoofer than on the headphones" a thing that can exist. The engine re-checks this at
runtime and logs a warning if the HAL ever lays the aggregate out differently.

**Clock drift is the HAL's job.** Each device runs on its own crystal and they diverge over time.
Rather than writing an adaptive resampler, the first selected device becomes the aggregate's clock
and every other sub-device gets `kAudioSubDeviceDriftCompensationKey`. Sub-*tap* drift compensation
is a separate decision and is deliberately disabled for Bluetooth clocks and virtual tap sources —
enabling it there makes the HAL add or drop a sample every fraction of a second, which is audible.

## Layout

| Path | What lives there |
|---|---|
| `Sources/UltraBass9000/Audio/Capture/` | Process tap creation and teardown |
| `Sources/UltraBass9000/Audio/Render/` | Aggregate planning, aggregate device, the real-time render callback |
| `Sources/UltraBass9000/Audio/Engine/` | `AudioEngine` — the orchestrator the UI binds to |
| `Sources/UltraBass9000/Audio/Support/` | Core Audio property helpers, device model, device registry |
| `Sources/UltraBass9000/Views/` | SwiftUI mixer |
| `Tests/UltraBass9000Tests/` | Pure planning logic — clock choice, drift rules, buffer layout |

## Conventions

**Real-time safety.** `AggregateOutput.render` runs on Core Audio's real-time thread. It must not
allocate, lock, log, send Objective-C messages, or read a `weak` reference (weak reads take a global
runtime lock). All shared state lives in `RenderControlBlock` as naturally-aligned plain memory.
Lifetime is guaranteed by teardown order rather than by reference counting.

**Teardown order is not negotiable:** `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
`AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. The aggregate references
the tap, and `AudioDeviceDestroyIOProcID` is what guarantees the last callback has returned.

**Swift 5 language mode**, deliberately — see the comment in `project.yml`.

**The Xcode project is generated.** Edit `project.yml`, never the `.xcodeproj`.

## Credits

[FineTune](https://github.com/ronitsingh10/FineTune) (GPL-3) was read as a reference for Core Audio
tap and aggregate-device behaviour. No code was copied; the debt is to its comments, particularly
the explanation of Bluetooth drift-compensation crackle.
