# Audio and recording plan

Prepared on 4 November 2026 for the `feature/audio-and-recording` pull request. All six milestones are implemented in build 22; see the architecture section “Recording and audio build 22” and the validation record for what was and was not verified. Two decisions changed during implementation: browser pages form one shared channel, and screen sound pauses (fails closed) when a microphone user cannot be filtered out. Items marked **Proposed** are engineering suggestions awaiting the owner's decision; **Fact** items were checked against the installed macOS SDK or the current code.

## Scope change

The PRD currently excludes this work: "The first release excludes … audio processing, recording …", AC-PRV-01 requires that "No media files … are created by a normal AppleCam session", and the build-15 scene expansion states "Audio remains excluded: clip players are muted, browser HTML media is forced silent and Web Audio is disabled." This pull request needs a recorded owner decision that replaces those three statements. **Proposed** replacement: AppleCam records only after an explicit Record action, writes only to a folder the person chose, shows a recording indicator for as long as a file is being written, and never uploads recordings.

## Goals

1. Record the canvas output to a movie file, both during a local preview and while sending to the AppleCam camera.
2. Capture audio from microphones and from browser, window, screen and video-clip layers.
3. Mix those channels with per-channel volume and mute.
4. Show which channels are recorded and at what level.

## Current state

**Fact.** Every source is deliberately silent today:

- `SceneMediaSource` plays clips with `player.isMuted = true; player.volume = 0`.
- Window and screen capture use `configuration.capturesAudio = false`.
- `BrowserSceneSource` injects a script that forces every `<audio>`/`<video>` element muted and replaces `AudioContext` with a constructor that throws.
- The app has no microphone entitlement or usage description.
- The AppleCam virtual camera is video-only. A meeting app takes its audio straight from a microphone and never sees AppleCam audio.

## a) Getting hold of each audio source

| Source | API (public) | What one channel contains | Permission |
| --- | --- | --- | --- |
| Microphone | `AVCaptureSession` + `AVCaptureAudioDataOutput`, one session per device; several microphones can run at once | One device | Microphone (new: `NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input`) |
| Window layer | ScreenCaptureKit `capturesAudio` on the layer's existing stream; `excludesCurrentProcessAudio` keeps AppleCam out | **The whole app that owns the window**, not that window: two Safari windows, or all Chrome tabs, share one channel | Screen & System Audio Recording (already granted) |
| Screen layer | ScreenCaptureKit display stream with `capturesAudio` | **All apps' sound**, including notification sounds and the meeting app itself unless excluded | Screen & System Audio Recording |
| Browser layer | WebKit plays page audio in its own helper processes and has no public audio-sample API. A Core Audio process tap (`AudioHardwareCreateProcessTap`, `CATapDescription`) on AppleCam's WebKit processes captures it and can silence local playback while tapping | **All browser layers together** in one channel, because WebKit shares one audio process per app. Per-layer volume/mute is only possible for `<audio>`/`<video>` elements through the page script, not for Web Audio | System Audio Recording (new: `NSAudioCaptureUsageDescription`) |
| Video-clip layer | `AVPlayerItem` with an `AVAudioMix` processing tap, or an `AVAssetReader` audio track driven by the layer clock | One clip layer | None |

**Fact.** These APIs exist in the macOS 27 SDK: `SCStreamConfiguration.capturesAudio`, `excludesCurrentProcessAudio`, `captureMicrophone` / `microphoneCaptureDeviceID` (macOS 15), `SCRecordingOutput` (macOS 15), `AudioHardwareCreateProcessTap` and `CATapDescription`.

**Proposed.** Use `AVCaptureSession` for microphones rather than ScreenCaptureKit's microphone option, so microphones work without a screen layer and each device is its own channel.

## b) Mixing

**Proposed.**

- **Graph.** One `AVAudioEngine`, with one source node per channel fed from a lock-free ring buffer and a mixer stage for gain and mute. The output is 48 kHz, 32-bit float stereo; mono microphones are centred.
- **Clocks.** Every device runs on its own clock, so each ring buffer runs a drift-correcting resampler. Without one, an hour-long recording slowly loses sync or clicks.
- **Real-time rules.** The render callback never allocates, locks or logs. The main thread exchanges gain and mute values with it atomically.
- **Sync.** Audio and video both use host time, as video frames already do. Each channel gets an offset slider for Bluetooth or HDMI latency.
- **Meters.** Peak and RMS in dBFS per channel and for the mix, computed on the audio thread and published to the UI about 20 times a second. A clipping marker holds for about 2 seconds.
- **Monitoring.** Off by default. Playing the mix through speakers while a microphone is open causes echo and feedback.
- **Failure rule.** Following AGENTS.md, a source that fails during a recording stops the recording and explains why. It does not silently continue with silence. See open question 6.

## c) Recording

**Proposed.**

- **Writer.** `AVAssetWriter` takes the compositor's canvas buffers, the same frames that are previewed or sent, through the hardware VideoToolbox encoder. It also takes the mixed audio and, optionally, one track per channel.
  - `SCRecordingOutput` is not suitable: it records ScreenCaptureKit captures, not AppleCam's composited canvas.
- **What is recorded.** The canvas at canvas size and frame rate, including scene switches. A meeting app requesting a smaller format does not affect the recording. Mask preview is never recorded.
- **Container.** QuickTime `.mov` written in fragments (`movieFragmentInterval`), so a crash or power loss keeps everything up to the last few seconds.
- **Storage.** The person picks a folder once, kept as a security-scoped bookmark (new entitlements: user-selected read-write and app-scoped bookmarks). Files are named by date and time.
  - Recording stops with an explanation when free space falls below a margin.
  - Planned HEVC bit rates: about 10 Mbit/s at 1920 × 1080 30 fps (≈ 4.5 GB per hour) and about 50 Mbit/s at 3840 × 2160 60 fps (≈ 22 GB per hour).
- **Indicator.** A red recording state, elapsed time and file size are always visible. macOS adds its own microphone and screen-recording indicators.

## d) Representing it to the person

**Proposed** (sketch; see open question 8):

- **Toolbar.** A Record button next to Preview and Send. Recording needs a running scene; Stop ends sending, preview and recording together, and a separate control stops only the recording.
- **Audio mixer strip.** A collapsible strip under the canvas, so levels stay visible while editing, as in Logic Pro, Final Cut Pro and broadcast tools. Apple's HIG keeps controls you watch continuously in view rather than in an inspector tab you have to open.
  - Each channel shows an icon, name, level meter, volume fader in dB, mute button and a record indicator, plus an add-microphone control.
- **Layer inspector.** Browser, window, screen and clip layers get an "Audio" switch that adds or removes their channel, with a note when a channel covers more than the layer (whole app, all browser layers, all system sound).
- **Scenes.** Microphones belong to the session and are heard in every scene. A layer's channel is heard only while its scene is active.

## Testing approach

**Proposed.**

- **Unit tests.** Gain/dB conversion and mute; meter maths (peak, RMS, clipping hold); the ring buffer and the drift resampler, tested with synthetic clocks at ±200 ppm; mixer output against reference sums; file naming; the low-disk rule; and mapping channels to tracks.
- **Integration tests.** A generated tone and timed flash through the real writer, with the file read back to measure audio/video offset and duration.
- **Not unit-testable.** Microphone, process-tap and ScreenCaptureKit audio need permissions and real devices. They are verified manually with recorded steps, as earlier layer types were.

## Proposed milestones within this pull request

1. Record video only (canvas to `.mov`), with folder choice, indicator and low-disk stop.
2. Microphones, mixer, meters and the mixer strip.
3. Window and screen audio through ScreenCaptureKit.
4. Video-clip layer audio.
5. Browser audio through a process tap.
6. Separate channel tracks, offsets and the remaining polish.

## Owner decisions (4 November 2026)

All ten open questions were answered on 4 November 2026.

- **Meetings:** recordings only in this pull request. Design the mixer so its output can later feed a separate virtual-microphone project; that virtual microphone is not built here.
- **Tracks:** the stereo mix as track 1, plus one track per recorded channel.
- **Format:** HEVC in QuickTime `.mov`.
- **Source failure:** a source that fails during a recording stops the recording, keeps the file written up to that point, and explains the failure. There is no silent fallback.
- **Scenes:** a layer's audio is heard only while its scene is live. Microphones are heard in every scene.
- **Mixer:** a collapsible strip under the canvas.
- **Monitoring:** sources AppleCam plays itself (browser layers and video clips) are captured without playing through the speakers. A Monitor switch plays the mix on a chosen output, such as headphones. Another app's sound, captured through a window or screen layer, still plays as that app normally would, because AppleCam cannot mute other apps.
- **Meeting audio:** never recorded. **Proposed rule:** captured window and screen audio excludes every other process that is currently using audio input (Core Audio's per-process input state), since that is what a meeting app or a browser in a call does. This also excludes, for example, all of Chrome while a Meet tab is in a call; the mixer says so.
- **Record button:** starts the scene preview if nothing is running. Stopping produces one complete file; there is no pause.
- **Microphone mode:** the mode chosen in Control Center for AppleCam applies (Voice Isolation, Wide Spectrum or Standard), and the mixer shows the current mode.
- **Save location:** the first recording asks for a folder, suggesting Movies/AppleCam. Later recordings go there automatically, and the folder can be changed under Output.
