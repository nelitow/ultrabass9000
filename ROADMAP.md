# UltraBass 9000 — Feasibility + Roadmap

Research date: 2026-08-13 · Machine: macOS 27.0 (26A5406e), Xcode 26.6 (macOS 26.5 SDK)

---

## 1. Verdict: all six requirements are possible, none need a kernel extension

The big finding: **you do not need to write an audio driver.** Two APIs added since macOS 14.2 make
the whole thing a userspace app.

| # | Requirement | Possible | Mechanism | Tier |
|---|---|---|---|---|
| 1 | Volume per device | Yes | Software gain applied to that device's channel block in the render callback | **Easy** |
| 2 | EQ per device | Yes | Biquad cascade per channel block (RBJ cookbook coefficients) | **Easy** |
| 3 | Low-pass / high-pass / band-pass | Yes | Same biquad cascade, 3 extra coefficient formulas | **Easy** |
| 4 | Waveform per output | Yes | Lock-free ring buffer from the render callback → SwiftUI Canvas or Metal | **Easy** |
| 5 | Global volume on the Mac volume keys | Yes | `CGEventTap` on `NX_SYSDEFINED`, swallow F10/F11/F12, apply own gain, draw own HUD | **Medium** |
| 6 | Delay synchronization | Yes | Clock drift handled free by the HAL; manual per-device offset = delay line | **Medium→Hard** |

### The architecture that unlocks it

```
   all apps  →  default output device
                    │
                    │  CATapDescription(stereoMixdownOfProcesses:)
                    │  .muteBehavior = .mutedWhenTapped   ← original audio never reaches speakers
                    │  .isPrivate = true
                    ▼
              [ process tap ]────────┐
                                     │
              [ output device A ]────┤    ONE private aggregate device
              [ output device B ]────┤    main + clock = device A
              [ output device C ]────┘    kAudioSubDeviceDriftCompensationKey = true on B, C
                                     │
                                     ▼
                          single IOProc callback
                 in:  tapped stereo    out: channels [A0 A1 | B0 B1 | C0 C1]
                                     │
                    per-channel-block DSP, independent per device:
                      delay line → biquad chain (EQ + LP/HP/BP) → gain → meter tap
```

**Why this matters for difficulty ranking:** because every output lives in *one* aggregate device
driven by *one* render callback, "per-device DSP" is just "process this slice of the output buffer
differently." Per-device delay becomes a ring buffer per channel range. And clock drift between
devices — normally the hardest part of multi-output audio — is handled by Core Audio itself via
`kAudioSubDeviceDriftCompensationKey`. That demotes requirement 6 from *hard* to *mostly bookkeeping*.

### What it costs you

| Constraint | Consequence |
|---|---|
| Sync delays everything to the slowest device | AirPods in the set ≈ 150–250 ms system-wide. Video lip-sync breaks, games unplayable. **Needs a "sync off / low-latency" toggle**, not a fix. |
| Tap mixdown is stereo only | No 5.1/Atmos passthrough. Multi-channel needs a dummy device to prescribe the format. |
| No API to query tap permission | Denial looks exactly like silence. Must detect all-zero buffers for N seconds and surface a warning. |
| `ioQueue: nil` silently fails on macOS 26 | Always pass a real dispatch queue to `AudioDeviceCreateIOProcIDWithBlock`. |
| Bluetooth + sub-tap drift comp = rhythmic crackle | Turn sub-tap drift comp **off** when tap source and primary output share a clock domain (BT, or a virtual source). |
| Unsigned builds fail at runtime | TCC never prompts. Signing is step 0, not step 8. **Ad-hoc counts as unsigned** — set `DEVELOPMENT_TEAM`. |
| `kAudioAggregateDeviceIsStackedKey` is documented backwards | Measured on macOS 27.0: `true` → 1 mirrored buffer, `false` → one buffer per device. Must be **false**. |

### Rejected path: writing a HAL driver

Apple confirmed **`AudioDriverKit` entitlements will not be granted for virtual audio devices** — the
`com.apple.developer.driverkit.family.audio` entitlement is hardware-only. A virtual device means the
older `AudioServerPlugIn` model: a `.driver` bundle in `/Library/Audio/Plug-Ins/HAL`, admin installer,
`coreaudiod` restart, no Mac App Store. `AudioServerPlugIn` is *not* deprecated and still works
(you already have `ParrotAudioPlugin.driver` installed), but it buys only one thing the tap path
lacks: native volume-key handling without Accessibility permission. Not worth it.

---

## 2. Nothing on the market does all six

### Paid

| App | Price | Multi-out | Per-device EQ | Delay sync | Waveform | Volume keys |
|---|---|---|---|---|---|---|
| **SoundSource 6** | $49 | Device groups / AirPlay | Per-**app** + system, 10-band + AU | No | No | Yes |
| **Loopback** | $99 | Yes (virtual devices) | No | No | Meters | No |
| **Audio Hijack** | $69 | Yes (block canvas) | Yes (AU + built-ins) | No | Yes (scopes) | No |
| **Airfoil** | $35 | Yes, **synced** | No | **Yes** (manual sliders) | No | No |
| **GroundControl ROOM** | ~€63 | Yes | AU inserts | No | Meters | No |
| **GroundControl SPHERE** | $399 | Yes | Per-channel AU DSP | No | Meters | No |

Closest off-the-shelf combo is **SoundSource + Airfoil ($84)** — still no per-output EQ and per-output
delay in the same signal path, and no waveform per output. The gap is real.

**Steal from:** Airfoil's manual per-output latency sliders (it ships them because reported Bluetooth
latency is routinely wrong), Audio Hijack's block canvas, SoundSource's menu-bar-first interaction.

### Open source

| Project | License | Architecture | What it already solves |
|---|---|---|---|
| **FineTune** (`ronitsingh10/FineTune`) | GPL-3 | Process tap + private aggregate | **Multi-out with drift comp, media keys + custom HUD, per-app volume/EQ, AutoEQ, loudness comp.** 8.7k ★, macOS 15+, 12k LOC audio layer, actively maintained |
| eqMac | MIT | HAL driver (BackgroundMusic-derived) | System-wide EQ, volume mixer |
| BackgroundMusic | GPL-2 | HAL driver | Reference for implementing volume properties on a virtual device |
| AudioRouterNow | Apache-2.0 (v4) | HAL driver + ring-buffer daemon | Multi-out routing, no DSP |
| BlackHole | **GPL-3** | HAL driver | Null sink only. Commercial reuse requires a license from Existential Audio |

**FineTune is the single most valuable reference.** I read its source. It already contains the exact
aggregate-device construction, the `.mutedWhenTapped` tap setup, the `CGEventTap` media-key monitor
with watchdog re-arming, and hard-won comments like *why* sub-tap drift compensation must be off for
Bluetooth. It does **not** have: per-output-device EQ (its EQ is per-app/global), per-device delay
offsets, low-pass/band-pass filters (only peaking, shelves, high-pass), or waveform visualization.

So: **UltraBass 9000 = FineTune's plumbing + the four things it's missing.**

---

## 3. Roadmap, ordered by difficulty

Estimates assume solo work with AI assistance, from a standing start.

### Phase 0 — Setup ✅ done (2026-08-13)

Distribution is explicitly out of scope for now. The `Apple Development` cert already on this machine
is enough: Xcode's automatic signing satisfies the "must be signed or TCC never prompts" requirement
for local runs. Revisit `Developer ID Application` ($99/yr) only if this ever leaves the machine.

1. ~~Developer Program enrollment~~ — deferred, not a blocker for local development.
2. New Xcode project, SwiftUI + AppKit menu bar extra, deployment target **macOS 26.0**
   (Xcode 26.6 ships the 26.5 SDK — macOS 27 APIs need an Xcode 27 beta).
3. Add `NSAudioCaptureUsageDescription` to Info.plist. Enable Hardened Runtime + audio input entitlement.
4. Define one `AudioSource` protocol (float buffers + clock) before writing any DSP, so the capture
   layer can be swapped later without touching DSP, render, or UI.

### Phase 1 — Get sound flowing ✅ done (2026-08-13)

Build the spine end to end with zero DSP, so every later phase is an insert, not a rewrite.

1. Process tap: `CATapDescription(stereoMixdownOfProcesses: [])`, `.mutedWhenTapped`, `isPrivate = true`.
2. Private aggregate device: tap as sub-tap, N output devices as sub-devices, index 0 as clock,
   drift compensation on the rest.
3. One `AudioDeviceCreateIOProcIDWithBlock` callback (real dispatch queue, never `nil`).
4. Straight passthrough: copy tapped stereo into every output's channel block.
5. All-zero-buffer detector → "audio permission denied" banner.

**Done when:** one Spotify stream plays out of built-in speakers + a USB DAC at the same time.

### Phase 2 — The easy wins, all four at once ✅ done (2026-08-13)

These are the same code shape: a per-device processor chain over a channel range.

1. **Per-device gain** — one multiply. 1 hour.
2. **Per-device biquad cascade** — peaking, low/high shelf, low-pass, high-pass, band-pass. Port
   RBJ cookbook formulas; FineTune's `BiquadMath.swift` covers 4 of 6, add lowpass + bandpass. 1–2 days.
3. **Waveform per output** — lock-free SPSC ring buffer written from the IOProc, drained on a
   display-link timer, drawn in SwiftUI `Canvas` (Metal only if 60 fps × 5 devices struggles). 1–2 days.
4. Never allocate, lock, or log inside the IOProc. Pre-allocate everything; parameter changes go
   through an atomic swap of a coefficient struct.

**Done when:** you can put a 200 Hz low-pass on the subwoofer and see its waveform go smooth.

### Phase 3 — Global volume on the Mac keys (2 days)

1. `CGEventTap` at `.cgAnnotatedSessionEventTap`, mask `.systemDefined`, `.defaultTap` (not listen-only).
2. Decode subtype 8: `NX_KEYTYPE_SOUND_UP` (0), `SOUND_DOWN` (1), `MUTE` (7). Swallow the event.
3. Apply to a software master gain ahead of the per-device chains. Draw your own HUD.
4. **Two failure modes you must handle:** taps get silently disabled on `.tapDisabledByTimeout`
   (re-enable via watchdog), and they are per-session, so re-arm on wake and fast-user-switch.
5. Requires **Accessibility** permission — plan the onboarding screen for it.

**Done when:** F11/F12 moves all outputs together and your HUD shows instead of Apple's.

### Phase 4 — Delay synchronization ✅ done (2026-08-13)

1. **Free part:** clock drift is already handled by the aggregate's drift compensation. Verify with a
   1 kHz tone across a wired + USB pair over 30 minutes.
2. **Auto offset:** read `kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` +
   buffer frame size per sub-device, delay every device to match the slowest.
3. **Manual offset slider per device**, ±500 ms — because reported Bluetooth latency is routinely
   wrong. This is the same reason Airfoil ships one.
4. **Sync-off mode.** Syncing to AirPods imposes ~200 ms on everything. Make it a visible toggle
   with an explicit latency readout, not a hidden preference.
5. Alignment helper: click-track burst out of two devices, user nudges until it sounds like one click.

**Done when:** speakers + AirPods play a kick drum as one hit, and the app says how much latency it cost.

### Phase 5 — Make it pretty (3–5 days)

- Menu bar extra as the primary surface (SoundSource's model), full window for the mixer view.
- Per-device strip: waveform, EQ curve, gain, delay, mute/solo — one column per output.
- SwiftUI Liquid Glass (`.glassEffect()`, `GlassEffectContainer`) against the macOS 26.5 SDK.
  macOS 27 refines Liquid Glass rather than replacing it, so this stays valid.
- Draw the EQ curve as a real transfer function computed from the live biquad coefficients, not a
  decorative spline.

---

## 4. Total

> Phases 0, 1, 2 and 4 are done. Phase 3 (volume keys) and Phase 5 (polish) remain. Acoustic
> auto-sync and measured frequency response were added during Phase 4 and are not in the original
> table below.

| Phase | Effort |
|---|---|
| 0 — Unblock | 0.5 day |
| 1 — Sound flowing | 2–3 days |
| 2 — Volume, EQ, filters, waveform | 4–6 days |
| 3 — Volume keys | 2 days |
| 4 — Delay sync | 1–2 weeks |
| 5 — Polish | 3–5 days |
| **Total** | **5–7 weeks** greenfield, **2–3 weeks** if forking FineTune |

## 5. Decision (settled 2026-08-13)

**Greenfield, with FineTune as a read-only reference.** Rationale: keeps licensing unencumbered, and
lets the codebase be shaped around per-**device** processing from day one rather than bending
FineTune's per-**app** architecture. Cost: full 5–7 weeks instead of 2–3.

Reference discipline — read FineTune for the Core Audio details that are expensive to rediscover,
write your own code from that understanding:

| Read | For |
|---|---|
| `Audio/Engine/ProcessTapController.swift` | Aggregate construction, sub-device flattening, when to disable sub-tap drift comp |
| `Audio/Keys/MediaKeyMonitor.swift` | `CGEventTap` arming, watchdog on `.tapDisabledBy*`, re-arm on wake |
| `Audio/EQ/BiquadMath.swift` | Coefficient formulas + frequency pre-warping (missing lowpass/bandpass — add those) |
| `Audio/Permission/AudioRecordingPermission.swift` | TCC handling when there is no API to query status |

---

## Sources

- [Capturing system audio with Core Audio taps — Apple](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Create audio drivers with DriverKit — WWDC21](https://developer.apple.com/videos/play/wwdc2021/10190/) · [AudioDriverKit entitlement thread](https://developer.apple.com/forums/thread/682035)
- [Capturing System Audio on macOS in 2026 — DGR Labs](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [CoreAudio Taps for Dummies](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/) · [AudioCap sample](https://github.com/insidegui/AudioCap)
- [FineTune](https://github.com/ronitsingh10/FineTune) · [eqMac](https://github.com/yoavhacohen/eqMac) · [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) · [BlackHole](https://github.com/ExistentialAudio/BlackHole) · [AudioRouterNow](https://github.com/mauriciomorkun/AudioRouterNow)
- [SoundSource](https://rogueamoeba.com/soundsource/) · [Airfoil latency handling](https://rogueamoeba.com/support/knowledgebase/?showArticle=Airfoil-AudioLatency) · [Loopback drift correction](https://rogueamoeba.com/support/knowledgebase/?showArticle=Loopback-AggregateDeviceHandling)
- [Aggregate device drift correction — Apple Support](https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac)
