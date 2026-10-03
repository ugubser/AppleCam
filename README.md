# AppleCam

AppleCam is a native macOS app that replaces a physical green screen with a still background image and publishes the result as a virtual camera for video calls.

Built with Swift, SwiftUI, AVFoundation, Core Image, Metal and Apple's Core Media I/O Camera Extension framework. Video processing happens locally; there are no third-party runtime dependencies or cloud processing services.

## Current status

Version **0.1.0, build 12** is a development prototype. Signed and notarized builds have been produced, and the owner has confirmed Logitech BRIO output in Google Meet through Chrome. Microsoft Teams web and sustained conference-call performance remain acceptance targets, not completed qualifications.

The latest validation run passed **88 automated tests**. Capture resolution and frame rate are selectable from the formats reported by each camera, including fractional and custom rates within supported ranges. The initial performance target remains 1920 × 1080 at nominal 30 fps. Synthetic processing measured about 30 fps; live BRIO capture has also been observed around 15 fps, so the target is not a guarantee of current camera or meeting performance. Historical measurements and their limits are recorded in [the validation plan](docs/VALIDATION_PLAN.md).

## Features

- GPU green-screen keying with up to six sampled screen colours.
- Tolerance, colour softness, foreground protection, small-hole filling and green-spill controls.
- Local Picture/Mask preview; the virtual camera receives the finished picture.
- Live green-screen on/off, background replacement and preview/sending switches.
- Apple Video Effects can run alongside green-screen processing.
- Per-camera profiles: automatic saving on every edit and again at quit of resolution/frame rate, background, all colour samples, calibration, green-screen and preview modes, and expanded/collapsed controls.
- A collapsible green-screen section and four saved background buttons per camera. Click an empty button to import; click a populated button to switch instantly; right-click to replace or clear it.
- Private copies of imported backgrounds survive moving or deleting the original images. Images referenced by other buttons or cameras are retained.
- Restored settings never automatically start capture or sending.

AppleCam provides video only. Keep your usual microphone selected in your meeting app. Its controls are in its own window and menu-bar menu. The ineffective Apple Video Effects button has been removed; use macOS's menu-bar video controls while a camera is active.

## Requirements

- Xcode with the macOS SDK and command-line tools selected. Development has been validated with Xcode 27 on macOS 27 and an Apple M1 Ultra Mac Studio.
- The project deployment target is macOS 15; older supported versions and other hardware have not been fully qualified.
- A built-in, external or Continuity camera exposed through AVFoundation. AppleCam discovers its resolutions and frame-rate ranges; the primary tested physical camera remains Logitech BRIO.
- A physical green screen and an opaque PNG or JPEG background.
- Appropriate Apple Developer signing/provisioning for the camera extension and Developer ID distribution.

## Build and test

```sh
git clone https://github.com/ugubser/AppleCam.git
cd AppleCam
./scripts/verify.sh
```

The verification script runs the Swift package tests, builds the app and extension without distribution signing, and checks the embedded extension layout. Logs go to ignored `work/`; build products go to ignored `build/`. This does not install or activate the camera extension.

For tests alone:

```sh
swift test
```

Open `AppleCam.xcodeproj` in Xcode and select the **AppleCam** scheme to build the app. The shared scheme includes the embedded camera extension.

For a development-signed build using the configured team:

```sh
xcodebuild -project AppleCam.xcodeproj -scheme AppleCam -configuration Debug \
  -derivedDataPath build/Signed -allowProvisioningUpdates build
```

The project contains public bundle and team identifiers, but no signing credentials. To use another developer team, configure matching signing identities, bundle identifiers and entitlements for both targets, update the distribution export options, and adjust the integration-test signing expectations. Keep private keys and account credentials in Xcode or the keychain.

## Using the camera

1. Put the signed, notarized app in **Applications**, open it, and use **Install camera extension** for the initial setup. Approve the extension in macOS settings if prompted.
2. Select your camera, choose a supported resolution and frame rate, choose a background and enable **Green screen**. Start **Preview locally** and grant camera access when prompted.
3. Use **Replace samples** on a clear patch of green screen. Add samples for other shades, up to six total. Sampling reads the incoming camera picture even when viewing the mask.
4. In **Mask** view, white is retained, black is removed and grey is partly transparent. Adjust tolerance and softness, then foreground protection and hole filling as needed. Return to **Picture** to adjust green spill.
5. Click **Send to AppleCam**, then select **AppleCam** in your meeting application's camera selector. Confirm its preview before joining a call.

You can change the background or toggle green screen while running. Turning green screen off intentionally sends the unprocessed camera picture when broadcasting. **Preview locally** ends publication while keeping local capture open; **Stop** ends capture and publication. Leave the app running while using its virtual camera.

Settings save separately for each camera, automatically and again on quit. Existing build-11 settings migrate into the original camera’s profile; its background becomes button 1. Camera/format changes require **Stop**, while background buttons and keying controls work live. After a full quit and reopen, select Preview locally or Send to AppleCam explicitly. A disconnected saved camera is not replaced with another camera. Missing backgrounds and settings-save errors are reported in the interface. No camera frames are recorded by AppleCam.

Build 12 changes the camera extension: after replacing the app in Applications, click **Install camera extension** to update it. Follow any approval or restart requirement reported by macOS. Select **Send to AppleCam** and reselect AppleCam in the meeting preview to verify delivery. Updating the app alone does not replace an already activated extension.

The selected format applies to capture, keying and frames sent into the extension. A meeting client can negotiate a different output resolution/rate; the extension preserves the whole picture with aspect-fit letterboxing and reduces cadence only when explicitly requested. It does not invent extra frames or change the physical camera setting. The extension advertises common resolutions plus attached-camera resolutions visible when its streams are created. A newly attached camera with an unusual resolution may require the extension to be recreated before that resolution can be published; local capture is independent of this catalogue. Unsupported publication formats report an error instead of changing the selection. Live format negotiation with the updated extension and browser remains an owner acceptance check.

Apple effects are controlled by macOS and are not blocked by AppleCam. Effects applied separately in a meeting app may further change the finished picture.

## Signed distribution

```sh
xcodebuild -project AppleCam.xcodeproj -scheme AppleCam -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/AppleCam.xcarchive \
  -derivedDataPath build/Distribution -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/AppleCam.xcarchive \
  -exportPath build/Notarization -exportOptionsPlist Config/DeveloperIDExport.plist \
  -allowProvisioningUpdates
```

The export submits to Apple's notary service using the account configured in Xcode. After Apple accepts the submission:

```sh
xcodebuild -exportNotarizedApp -archivePath build/AppleCam.xcarchive \
  -exportPath build/Notarized
codesign --verify --deep --strict build/Notarized/AppleCam.app
xcrun stapler validate build/Notarized/AppleCam.app
spctl --assess --type execute --verbose=2 build/Notarized/AppleCam.app
```

Do not disable SIP or modify Apple's camera services to install the extension. Build archives, app bundles, signing material and local logs are excluded from Git.

## Project layout

| Path | Contents |
| --- | --- |
| `AppleCam/` | SwiftUI interface, camera model, capture, Metal processing and frame transport |
| `AppleCamCameraExtension/` | Core Media I/O virtual camera provider and streams |
| `Shared/` | Camera contract, timing, calibration, queue and preference models |
| `Tests/` | Unit, synthetic media and signing integration tests |
| `Config/` | App/extension metadata, entitlements and export configuration |
| `docs/` | Requirements, architecture, development plan and validation history |
| `artifacts/fixtures/` | Synthetic background fixture used in tests |
| `artifacts/verification/` | Reproducible validation summaries; historical records are dated |
| `scripts/verify.sh` | Local test and build verification |

Start with the [PRD](docs/PRD.md), [architecture](docs/ARCHITECTURE.md), [development plan](docs/DEVELOPMENT_PLAN.md) and [validation plan](docs/VALIDATION_PLAN.md). Some documents retain historical milestone notes; this README describes the current implemented behavior. Contributor rules are in [AGENTS.md](AGENTS.md).
