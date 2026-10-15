# Forte

A menu-bar app that makes your Mac louder and better-sounding, system-wide, with **no audio driver to install**.

**System volume**
- Master output volume and mute, synced with the volume keys. The menu-bar icon shows the level.
- Software volume for outputs macOS can't control (most HDMI/DisplayPort displays).
- Microphone input level and mute.

**Per-app mixer**
- A volume slider (0–200%) and mute for every app using audio, with its icon and a live activity meter.
- Helper processes are grouped under their app (Safari's WebKit GPU process, Chrome's audio service and so on).
- Settings are remembered per app and re-applied when the app plays again.

**Devices**
- Every speaker, headphone, USB DAC, Bluetooth and AirPlay output and every input, with channel count and transport.
- One-click switching of the default output or input, and sample-rate selection where the device supports it.
- Follows connection, disconnection, default-device and sample-rate changes, plus sleep/wake.

**Sound**
- Volume boost to 800% (+18 dB), with an always-on look-ahead brickwall limiter so it never clips (ceiling −1 dBFS).
- 10-band graphic EQ (32 Hz–16 kHz) with a live response curve, 16 built-in presets (Flat, Bass Boost, Vocal, Rock, Classical…), your own presets and reset to flat.
- Bass (100 Hz shelf) and treble (10 kHz shelf) tone controls.
- Balance and stereo width.

## How it works

macOS 14.2 added Core Audio **process taps**, which let one app capture and mute other apps' output. Forte:

```
apps you've adjusted ─▶ one tap per app ───┐
every other app ─────▶ one global tap ─────┤   (tapped apps are muted at the source)
                                           ▼
private aggregate device [ real output device + taps ]
                     │  one IOProc (C, real-time safe)
                     ▼
per-app gain + mix ─▶ EQ + tone ─▶ boost ─▶ width ─▶ balance ─▶ limiter ─▶ volume ─▶ real output device
```

- Forte excludes itself from every tap. It also excludes processes that record the output device (eqMac's or Loopback's engine), which prevents feedback loops through virtual devices.
- An app gets its own tap the first time you change its volume. When it launches helpers or quits, the running taps' process lists are updated in place (`kAudioTapPropertyDescription`), so other audio never glitches.
- Quitting the app (or a crash) destroys the taps and apps play normally again.
- The DSP runs in plain C (`Packages/ForteKit/Sources/BSKernel`), so the audio thread never allocates, locks or touches the Swift runtime. UI changes reach it through relaxed atomics and are smoothed (20 ms gains, 30 ms EQ) to avoid zipper noise.

## Requirements

- macOS 14.4 or later
- Xcode 16 or later (built with Xcode 27 / Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change `project.yml`

## Build and run

```sh
open Forte.xcodeproj           # then ⌘R
# or from the command line:
xcodebuild -project Forte.xcodeproj -scheme Forte -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Forte.app
```

On first launch macOS asks for **System Audio Recording** access. Forte needs it to read app audio, and the audio never leaves your Mac.

Signing uses the Apple Development identity for team `H8HKVKKHWL` (set in `project.yml`). Change `DEVELOPMENT_TEAM` there and run `xcodegen generate` to use another team. Keep a stable signing identity: macOS ties the permission grant to it.

## Tests

```sh
cd Packages/ForteKit && swift test
```

The 15 tests cover:
- transparency at default settings, and limiter ceiling under +24 dB boost with heavy bass EQ on full-scale noise
- EQ band accuracy (±0.25 dB), the bass/treble shelves, EQ bypass, width and balance
- software output volume after the limiter, and recovery from NaN/Inf input
- the IOProc: per-app source mixing with gain and mute, click-free gain glides, activity metering, and channel mapping (interleaved, planar, mono, multichannel, tap after device inputs)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Banner says permission is needed | System Settings › Privacy & Security › Screen & System Audio Recording, then enable Forte under *System Audio Recording Only*. |
| Reset the permission prompt | `tccutil reset AudioCapture io.github.broisnischal.forte` |
| Signal-flow debugging | Launch with `--args -diagnostics YES`, then run `/usr/bin/log stream --predicate 'subsystem == "io.github.broisnischal.forte"'`. It logs input/output levels each second and the app list (▶ playing, `[mixed]` has its own tap) every 5 s. |
| A mixed app's first sound leaks at 100% | A brand-new process plays through the shared tap until Forte claims it (normally within a few ms). Long-running apps are unaffected. |

## Layout

```
Forte/                 SwiftUI menu-bar app (controller, views, assets)
Packages/ForteKit/
  Sources/BSKernel/          C DSP kernel + HAL IOProc
  Sources/ForteKit/    Core Audio plumbing: tap/aggregate router, devices and volume, app grouping, presets, permission
  Tests/                     Swift Testing suites for the DSP and IOProc
scripts/make-icon.swift      Regenerates the app icon set
project.yml                  XcodeGen spec for Forte.xcodeproj
```
