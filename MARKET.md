# UltraBass 9000: Market Position

Research date: 2026-08-13. This document checks the claim in `ROADMAP.md` ("nothing on the market
does all six") against independent evidence, and covers the tools the roadmap research didn't reach:
CamillaDSP, miniDSP, Dirac Live, Sonarworks SoundID, Roon, and a search for a tool called JustRoom
that turned up nothing under that name.

## The plain answer

No macOS tool does what UltraBass 9000 does, but the reason isn't that the DSP is exotic. Per-output
EQ, crossover filters, and delay all exist elsewhere on macOS today. Ginger Audio's GroundControl
SPHERE puts an AU plugin slot and a delay line, accurate to 0.01 ms, on every channel it sees.
CamillaDSP does the same processing for free, on macOS, Linux, and Windows.

What's missing is the combination of three things at once: automatic system-wide capture (every app,
with zero routing setup), independently-clocked physical output devices rather than channels of one
interface, and a built-in step that measures the delay instead of asking the user to compute or dial
it in by hand. Take away any one of those three and the field opens up. Keep all three and, as far as
this research found, UltraBass 9000 is alone.

That's a narrower claim than "nothing on the market does all six" (the ROADMAP's phrasing), and it's
worth being precise about why. SPHERE's per-channel delay and EQ are real and shipping, but SPHERE is
a monitor controller: audio has to be deliberately routed to it from a DAW or through its own virtual
bridge device, and its own literature describes "multi-output" as combining several audio interfaces
into one bigger interface for channel count, using macOS's own Multi-Output Device under the hood.
That's the same primitive UltraBass 9000 replaces, used for a different reason: getting to 16 channels
for Atmos, not spanning a laptop's built-in speakers and a separate Bluetooth speaker that don't share
a clock.

## Comparison

Grouped by what kind of thing each one is, since that's the axis that actually explains the gaps.

### macOS apps

| Tool | Price | Captures any app, no setup | Independent physical devices at once | Per-device EQ/filters | Per-device delay | Measures the delay for you |
|---|---|---|---|---|---|---|
| **UltraBass 9000** | Free, source-only | Yes (process tap) | Yes | Yes (5-band + HP/LP/BP, real slopes) | Yes | Yes (sweep + built-in mic) |
| SoundSource 6 | $49 | Yes | Yes (Output Groups, added Dec 2025) | Only the volume slider is independent per device in a group; EQ/effects apply per app or per device outside a group | No | No |
| Loopback | $99 | Yes (virtual device) | Yes (into one aggregate) | No | No | No |
| Audio Hijack | $69 | Per session you build | Yes, one Output Device block per chain | Yes, per chain you wire up | No delay block | No |
| Airfoil | $35 | Yes | Yes, and it keeps them in sync | No | Yes, manual sliders | No |
| eqMac | Free (MIT) | Yes | Lists Multi-Output/Aggregate as a selectable output | One system-wide EQ chain, not independent per device | No | No |
| FineTune | Free (GPL-3) | Yes | Yes | Per-app/global EQ, not independent per simultaneous output device | No | No |
| AudioRouterNow | Free (Apache-2.0) | Yes | Yes | None | No | No |

### Not macOS apps, but adjacent

| Tool | What it is | Where it stops short of UltraBass 9000's case |
|---|---|---|
| **CamillaDSP** | Free, open-source DSP engine, Linux/macOS/Windows | Does the crossover/EQ/delay math as well as anything on this list. On macOS it needs a virtual driver (typically BlackHole) as its input, because it isn't itself a system-audio tap, and each instance targets one output device; feeding several independently-clocked devices means building your own merged/aggregate device first. Delay values come from your own measurement (REW, a stopwatch, trial and error), not from CamillaDSP. |
| Sonarworks SoundID Reference | Speaker/headphone calibration | A user asked for this directly on Sonarworks' own support forum ("Multiple Stereo Outputs Simultaneously and Independently?") and the answer, confirmed elsewhere in their support docs, is that it isn't supported: one calibrated output at a time. |
| Roon | Music player with a DSP engine | Per-zone parametric EQ, yes. Per-zone delay for keeping zones in sync is a standing feature request on Roon's own community forum ("DSP function to add delay for better zone sync"), not a shipped feature. |
| Dirac Live | Room correction, paired with an AVR/streamer or run as a computer processor/plugin | Built for correcting one output path (a receiver's speaker set, or a DAW's monitor bus), not for fanning independently-processed audio out to several unrelated consumer devices attached to the same Mac at once. |
| HouseCurve | Room correction and time-alignment app | iOS and car-audio focused; its own site does not list macOS as supported. |
| JustRoom | — | No macOS app, plugin, or project by this name turned up in any search. If it refers to something else, this research didn't find it. |
| BlackHole | Free virtual audio driver | A null sink, nothing more. It's the plumbing other tools (including CamillaDSP setups) route through, not a competitor in its own right. GPL-3, and Existential Audio requires a separate commercial license for closed-source reuse. |

### Hardware

| Option | Cost | What it aligns |
|---|---|---|
| miniDSP (2x4HD, 4x10HD, etc.) | Roughly $100–$600 per unit | Crossovers and time alignment across the channels wired into that one box, using its own gain/delay block. Measurement is external: Room EQ Wizard plus a UMIK mic, done by hand, not automated inside the box. Needs an amp per channel and physical wiring; works with any source since it sits inline, not just a Mac. |
| AV receiver with Audyssey/YPAO/Dirac | A few hundred to a few thousand dollars | The closest hardware analog to acoustic auto-sync: the receiver plays tones through its included mic and calculates distance/delay/EQ automatically. But it only reaches speakers wired to that receiver, and the Mac is just a source feeding it one stereo or HDMI signal, not the thing doing the alignment. |

Where UltraBass 9000 sits relative to both: it does in software, for free, what a miniDSP or receiver
does in a box, but for devices that were never going to share a wire; a laptop's built-in speakers, a
USB DAC, a Bluetooth speaker, and an AirPlay target, each running on its own clock, with the Mac's own
microphone standing in for a UMIK. It gives up what the hardware gives you in return: those boxes work
with a turntable or a game console just as well as a Mac, they don't ask you to compile anything, and
in the receiver's case the auto-calibration routine is a mature, decades-refined feature, not one built
by a single developer and measured on one machine.

## Who actually asks for this

The author's case (a MacBook with weak bass, a JBL Bass Pro Go standing in for a subwoofer, and a
monitor with better stereo separation than either, wanting all three time-aligned and crossed over
into one system) is a specific instance of a pattern that shows up repeatedly, described in different
words by people who don't know a name for what they want:

- **The exact feature request, unanswered.** A Sonarworks user asks point-blank whether SoundID
  Reference can drive "Multiple Stereo Outputs Simultaneously and Independently." The response,
  and Sonarworks' own docs, confirm it can't: [Sonarworks Support community post](https://support.sonarworks.com/hc/en-us/community/posts/20237494424850-Multiple-Stereo-Outputs-Simultaneously-and-Independently).
- **The delay half of the problem, asked from the Bluetooth side.** A Tom's Guide Forum user trying
  to run two Bluetooth speakers off one source hits a roughly 100 ms mismatch and asks if they can
  manually add delay to the faster speaker to bring them back in step: ["can I create a bluetooth delay?"](https://forums.tomsguide.com/threads/can-i-create-a-bluetooth-delay.461396/).
  No general answer existed for speakers from different brands.
- **The volume-control half of the problem**, which is what most people actually run into first,
  since it's what breaks the moment you build a Multi-Output Device: ["How to adjust volume on a
  Multi-Output Device?"](https://discussions.apple.com/thread/256169243) and ["Multi-Output Device
  sync issue"](https://discussions.apple.com/thread/7925534) on Apple's own community forums, plus a
  [MacRumors thread](https://forums.macrumors.com/threads/anyway-to-control-volume-for-mult-outpit-device-even-if-third-party-or-cludgy.2367662/)
  asking for any workaround, "even if third party or cludgy."
- **The professional version of the same ask.** On Gearspace, an engineer mixing 2.75 m from an LCR
  monitor setup describes measuring arrival-time differences up to 1.9 ms between speakers and
  inserting manual delays after the EQ stage in a BSS speaker-management system to correct it
  (["Speakers time align," Gearspace, 2015](https://gearspace.com/board/post-production-forum/1052364-speakers-time-align.html)).
  Same physics, done with a few thousand dollars of rack gear instead of a laptop mic.
- **The feature request Roon users keep filing.** ["DSP function to add delay for better zone
  sync"](https://community.roonlabs.com/t/dsp-function-to-add-delay-for-better-zone-sync/158356) asks
  for exactly the alignment UltraBass 9000 automates, aimed at a different product that hasn't shipped
  it.

None of these people were asking for "a macOS app with per-output EQ and delay sync." They were
describing the two symptoms (can't control volume once devices are combined, can't get them to sound
like one system) separately, because nothing ties the two problems together into one feature. That's
the actual gap, and it's a real one, not a marketing frame stretched to fit.

Realistically, three groups would use this:

1. **Desk setups missing bass**, the author's own case: a laptop or a small monitor pair plus a
   Bluetooth speaker or a cheap subwoofer, wanting the low end crossed over correctly and time-aligned
   instead of just loud and smeared.
2. **People who already built a Multi-Output Device** and hit the volume-key and per-device tuning
   wall that Apple's own community forum is full of complaints about, without wanting to pay $49 for
   SoundSource and still not getting delay sync out of it.
3. **Hobbyists doing on a budget what a miniDSP + REW session does**, minus the standalone mic and the
   manual correlation work, at the cost of it only working for a Mac's own attached outputs and only
   at one listening position.

## Where it's weaker than the alternatives

Said plainly, in the same terms as the feature list, not hedged:

- **Stereo only.** The tap is a stereo mixdown. No 5.1 or Atmos passthrough, which rules out the exact
  home-theater use case GroundControl SPHERE Atmos and AV receivers are built for.
- **Latency is a shared tax.** Every device syncs to the slowest one in the set. Put an AirPods pair
  in the mix and the whole system inherits its 150-250 ms, which breaks video lip-sync and makes games
  unplayable. That's a real toggle to design around, not a footnote.
- **System-wide only, not per-app.** SoundSource and FineTune both let you send Spotify to one place
  and Zoom to another with independent volume. UltraBass 9000 processes what the whole Mac is playing
  as one signal, split only by output device.
- **The microphone measures arrival time, not frequency response.** Acoustic auto-sync tells you how
  far apart your devices arrived and computes a delay from that; it is not room correction, it doesn't
  touch EQ, and it says nothing about how a device actually sounds in the room, only when. Dirac Live,
  Sonarworks, and Audyssey all measure and correct frequency response; this doesn't.
- **One listening position, and headphones can't be measured at all.** The whole calibration is
  anchored to wherever the Mac's built-in mic is. Move, and it's wrong. Headphones and earbuds are
  skipped outright, since a microphone can't hear them; the app reports this rather than guessing.
- **Five-band IIR, not FIR or convolution.** CamillaDSP and SPHERE both support arbitrary FIR/convolution
  correction filters. This is RBJ-cookbook biquads: five bands plus three filter types, which covers
  crossover and tonal shaping but not surgical correction.
- **No binary, no notarization, macOS 26+ only.** Every other tool on this list is a download.
  This one is a `git clone` and a local Xcode build, on the newest shipping macOS, because the audio
  capture permission this app needs is only granted to a properly signed build, and that isn't set up
  yet. That's a real barrier for anyone who isn't comfortable with Xcode.
- **No LICENSE file is committed yet.** The repository is public and described as open source, but
  without a license file the redistribution terms are formally undefined. Worth fixing independent of
  this research.
- **One developer, one machine, one measurement.** The ~0.2 ms repeatability figure for acoustic
  auto-sync is real, reported by the author from their own hardware, not a lab result or a spec that's
  been reproduced elsewhere. Treat it as "this is what it did for me," not a guarantee.

## Sources

- [SoundSource Output Groups manual](https://www.rogueamoeba.com/support/manuals/soundsource/?page=output-groups) and [SoundSource 6 announcement](https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/) and [AlternativeTo coverage](https://alternativeto.net/news/2025/12/soundsource-6-brings-grouped-outputs-airplay-support-quick-configs-and-refreshed-ui) — confirms Output Groups is new (Dec 2025) and that only the volume slider is independently adjustable per device within a group.
- [Rogue Amoeba SoundSource purchase page](https://rogueamoeba.com/soundsource/buy.php) — $49 list price, confirmed August 2026.
- [Ginger Audio GroundControl SPHERE manual](https://www.gingeraudio.com/manuals/sphere) — per-channel AU plugin slots, per-channel delay to 0.01 ms, "Multi-output device" for combining interfaces, requires explicit routing rather than automatic system capture.
- [GroundControl Sphere Studio, Sweetwater](https://www.sweetwater.com/store/detail/GCSphereStu--ginger-audio-groundcontrol-sphere-studio) and [Sphere Atmos, Sweetwater](https://www.sweetwater.com/store/detail/GCSphereAtmos--ginger-audio-groundcontrol-sphere-atmos) — $199 (Studio, 2.1) and $499 (Atmos, 9.1.6) list pricing.
- [CamillaDSP](https://www.camilladsp.com/) and [CamillaDSP CoreAudio backend docs](https://github.com/HEnquist/camilladsp/blob/master/backend_coreaudio.md) — macOS support via CoreAudio, BlackHole as the typical capture source.
- [How to run CamillaDSP with Multiple DACs, Mark Zachmann](https://medium.com/home-wireless/how-to-run-camilladsp-with-multiple-dacs-9672a4639cf3) — confirms multiple independent output devices require manually building a merged/aggregate device; not native to CamillaDSP.
- [eqMac](https://eqmac.app/) and [eqMac GitHub](https://github.com/bitgapp/eqMac) — multi-output/aggregate device support as an output choice, one system-wide EQ chain.
- [FineTune](https://github.com/ronitsingh10/FineTune) — per-app volume/EQ, multi-device output, media keys; GPL-3.
- [AudioRouterNow](https://github.com/mauriciomorkun/AudioRouterNow) and [MacRumors thread](https://forums.macrumors.com/threads/audiorouternow-free-open-source-audio-router-for-macos-no-kext-menu-bar.2484444/) — routing only, no EQ, confirmed by the maintainer's own description; thread shows no requests for EQ/delay, only routing stability.
- [AudioRouter, jkjoplin](https://github.com/jkjoplin/AudioRouter) — a separate, smaller open-source project doing per-app (not per-device) EQ and routing; not in the original roadmap research.
- [Sonarworks Support: "Multiple Stereo Outputs Simultaneously and Independently?"](https://support.sonarworks.com/hc/en-us/community/posts/20237494424850-Multiple-Stereo-Outputs-Simultaneously-and-Independently) and ["Should SoundID Reference work with multiple outs?"](https://support.sonarworks.com/hc/en-us/community/posts/4410308085778-Should-SoundID-Reference-work-with-multiple-outs) — confirms no multi-output support.
- [Roon: "DSP function to add delay for better zone sync"](https://community.roonlabs.com/t/dsp-function-to-add-delay-for-better-zone-sync/158356) and [Roon DSP Engine docs](https://help.roonlabs.com/portal/en/kb/roon-labs-llc/audio/dsp-engine) — per-zone EQ shipped, per-zone delay a standing feature request.
- [Dirac Live](https://www.dirac.com/products/room-correction) and [Dirac Live 3.11 changelog](https://helpdesk.dirac.com/en/dirac-live/Dirac-Live-311-LATEST-Software-Changelog-bfed) — time alignment and room correction for a single processed output path.
- [HouseCurve](https://housecurve.com/) and [HouseCurve Time Alignment docs](https://housecurve.com/docs/tuning/time_align.html) — iOS/car-audio tool; macOS not listed as supported.
- [miniDSP digital crossover basics](https://www.minidsp.com/applications/digital-crossovers/digital-crossover-basics) — gain/delay block for time alignment across a box's own channels, measured externally with REW.
- [Apple Community: "How to adjust volume on a Multi-Output Device?"](https://discussions.apple.com/thread/256169243), ["Multi-Output Device sync issue"](https://discussions.apple.com/thread/7925534) — real users hitting the volume and sync problems this app addresses.
- [MacRumors: "Anyway to control volume for mult-outpit device, even if third party or cludgy?"](https://forums.macrumors.com/threads/anyway-to-control-volume-for-mult-outpit-device-even-if-third-party-or-cludgy.2367662/)
- [Tom's Guide Forum: "can I create a bluetooth delay?"](https://forums.tomsguide.com/threads/can-i-create-a-bluetooth-delay.461396/) — real user asking for manual delay to fix a Bluetooth speaker mismatch; page could not be fully loaded, description reflects search-result summary only.
- [Gearspace: "Speakers time align"](https://gearspace.com/board/post-production-forum/1052364-speakers-time-align.html) — real engineer measuring and correcting up to 1.9 ms of arrival-time mismatch between monitors; page returned a 403 on direct fetch, description reflects search-result summary only.
- Local verification against this repository: `git log` (`f83b691` "Phase 4: per-device delay lines and acoustic auto-sync", `ddb7d46`, `8d1de38` "Band-pass with real edges and slopes"), and `Sources/UltraBass9000/Audio/Calibration/AcousticCalibrator.swift`, read directly for what acoustic auto-sync actually measures and what it skips.
