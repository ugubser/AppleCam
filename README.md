# AppleCam

AppleCam is a native macOS app that replaces a physical green screen with a still background image and publishes the result as a virtual camera for video calls.

Built with Swift, SwiftUI, AVFoundation, Core Image, Metal and Apple's Core Media I/O Camera Extension framework. Video processing happens locally; there are no third-party runtime dependencies or cloud processing services.

## Current status

Version **0.1.0, build 11** is a development prototype. Signed and notarized builds have been produced, and the owner has confirmed Logitech BRIO output in Google Meet through Chrome. Microsoft Teams web and sustained conference-call performance remain acceptance targets, not completed qualifications.

The latest validation run passed **71 automated tests**. The pipeline targets 1920 × 1080 at nominal 30 fps. Synthetic processing measured about 30 fps; live BRIO capture has also been observed around 15 fps, so the target is not a guarantee of current camera or meeting performance. Historical measurements and their limits are recorded in [the validation plan](docs/VALIDATION_PLAN.md).

## Features

- GPU green-screen keying with up to six sampled screen colours.
- Tolerance, colour softness, foreground protection, small-hole filling and green-spill controls.
- Local Picture/Mask preview; the virtual camera receives the finished picture.
- Live green-screen on/off, background replacement and preview/sending switches.
- Apple Video Effects can run alongside green-screen processing.
- Automatic saving of camera selection, background, colour samples, calibration and preview mode.
- A private copy of the imported background survives moving or deleting the original image.
- Restored settings never automatically start capture or sending.

AppleCam provides video only. Keep your usual microphone selected in your meeting app. Its controls are in its own window and menu-bar menu; the Apple Video Effects button opens Apple's existing system panel.

## Requirements

- Xcode with the macOS SDK and command-line tools selected. Development has been validated with Xcode 27 on macOS 27 and an Apple M1 Ultra Mac Studio.
- The project deployment target is macOS 15; older supported versions and other hardware have not been fully qualified.
- A camera offering 1920 × 1080 at nominal 30 fps. The initial target is Logitech BRIO.
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
2. Select your camera, choose a background and enable **Green screen**. Start **Preview locally** and grant camera access when prompted.
3. Use **Replace samples** on a clear patch of green screen. Add samples for other shades, up to six total. Sampling reads the incoming camera picture even when viewing the mask.
4. In **Mask** view, white is retained, black is removed and grey is partly transparent. Adjust tolerance and softness, then foreground protection and hole filling as needed. Return to **Picture** to adjust green spill.
5. Click **Send to AppleCam**, then select **AppleCam** in your meeting application's camera selector. Confirm its preview before joining a call.

You can change the background or toggle green screen while running. Turning green screen off intentionally sends the unprocessed camera picture when broadcasting. **Preview locally** ends publication while keeping local capture open; **Stop** ends capture and publication. Leave the app running while using its virtual camera.

Settings save automatically. After a full quit and reopen, select Preview locally or Send to AppleCam explicitly. A disconnected saved camera is not replaced with another camera. Missing backgrounds and settings-save errors are reported in the interface. No camera frames are recorded by AppleCam.

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
