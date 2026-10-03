# AppleCam sources and decisions

Prepared on 2 October 2026. This record distinguishes primary-source facts, local observations and proposed engineering choices. Existing camera behavior is not evidence that AppleCam’s extension transport works.

## Primary evidence

| Source | What it supports | What it does not establish |
| --- | --- | --- |
| [Apple camera-extension session](https://developer.apple.com/videos/play/wwdc2022/10022/) | Public camera-extension architecture; creative cameras; sink queues; source delivery; role-account sandbox | Reliable activation on the owner's macOS 27 installation or AppleCam implementation quality |
| [Creating a camera extension](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o?changes=_7_3_5) | Xcode template, bundle packaging, approval and selectable camera devices | A ready-made chroma key or custom buttons in Apple's panel |
| [Apple System Extensions](https://developer.apple.com/documentation/systemextensions/) | Matching signing teams and notarization or App Store distribution requirements | Availability of signing credentials for the owner's particular account |
| [System Video Effects UI API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface%28_%3A%29) | Public entry point for the existing system interface | Adding third-party controls to that interface |
| [Apple video effects guidance](https://support.apple.com/en-us/105117) | Built-in effects and their hardware conditions | Studio Light or Center Stage availability on every external webcam |
| [Core Image chroma-key recipe](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_filer_recipes/ci_filter_recipes.html) | Colour-key and compositing building blocks | Perfect handling of physical lenses, reflections or green clothing |
| [Microsoft Teams web limitations](https://learn.microsoft.com/en-us/microsoftteams/teams-desktop-client-features) | Web client supports ordinary backgrounds; physical green-screen feature is unavailable | Acceptance of a particular untested AppleCam camera extension or the tenant's camera policy |
| [OBS virtual-camera guidance](https://obsproject.com/kb/virtual-camera-troubleshooting) | Modern macOS virtual camera uses a camera extension | Root cause of the owner's missing process |

Apple's documentation pages can be JavaScript-rendered. Where the page body was not available to the reader, the installed macOS SDK declarations and Apple session transcript were used for the narrow API and architecture checks. The [environment document](ENVIRONMENT.md) records those local checks.

## Proposed design decisions

| Decision | Proposal | Reason and validation boundary |
| --- | --- | --- |
| D01 Product shape | Native menu-bar app plus embedded camera extension | Small interface and a standard selectable camera; custom Apple-panel controls have no verified public extension point |
| D02 Capture location | AVFoundation capture and processing in the host app | Clear foreground-user attribution and easier native preview; M0 must prove Apple-controls behavior |
| D03 Transport | Host supplies finished buffers through a CMIO sink; extension publishes a source | Public Apple mechanism with explicit frame ownership; M0 must establish callback and queue contracts |
| D04 Processing | Metal-backed Core Image with a tested reference keyer | Reuses Apple image infrastructure while retaining control over key and spill behavior |
| D05 Initial support | Current Apple silicon Mac, BRIO and Chrome Teams web | Bounded, representative owner workflow; not a claim of broad compatibility |
| D06 Backgrounds | Imported JPEG or PNG still image | Reduces first-release scope; animated backgrounds remain deferred unless requested |
| D07 Output | Proposed 1080p 30 fps and opaque SDR frames | Appropriate initial call target; input format and performance must be measured |
| D08 Apple effects | Open system UI and allow effects alongside keying; owner removed effect restrictions on 2026-10-02 | Public integration without promising unsupported hardware features |
| D09 Failure policy | Stop frames and show the error | Preserves the owner's no-fallback principle and avoids raw-camera exposure |
| D10 Distribution | Signed and notarized personal-use app with SIP enabled | Uses normal system protections; signing prerequisites are part of M0 |
| D11 Dependencies | Apple frameworks initially | No third-party package is required by the current design |
| D12 Source and artifacts | Keep the project in AppleCam with versionable docs and private ignored paths | Matches the owner's destination and sensitive-data instructions |

The owner confirmed the BRIO, Chrome, still-image and 1080p 30 fps scope during planning. Other architectural choices remain proposals to validate through milestone evidence. Estimates and numerical budgets are engineering proposals, not source-derived guarantees.

## Owner decisions and open questions

The owner confirmed the native Apple infrastructure preference, physical green screen, Teams web workflow, existing developer membership and project folder. The owner also accepted the proposed BRIO, Chrome, still-image and 1080p 30 fps first-release scope.

The signing team, exact bundle identifiers, Developer ID credential route, camera-specific Apple effect support and runtime extension reliability remain open. These do not block the PRD; they must be settled in M0 before claiming a functioning installation.

The real-glasses acceptance judgment remains with the owner. No sample images were requested or captured during planning.

## Document validation record

Planning validation completed on 2 October 2026:

- Eight Markdown documents were checked for local links, complete table rows, balanced code fences, trailing whitespace and final newlines.
- All 31 requirement definitions are unique and have matching validation rows; the development plan references every requirement.
- All five milestones are present, and the owner-confirmed BRIO, Chrome, still-image and 1080p 30 fps scope is reflected across the documents.
- Twenty ignore-rule probes confirmed private signing and fixture paths are excluded while source, entitlements and synthetic fixtures remain eligible for version control. The probes ran in an isolated temporary repository, not by initializing AppleCam.
- A narrow sensitive-content check found no supplied account login, private-key block or API-key token in the documents.
- The corrected compile-only framework probe passed against the installed macOS 27 SDK.

The checks above describe the original planning task. Subsequent implementation added automated tests, a native app/extension build and a verified synthetic local preview; see the README and current verification record. No extension installation or physical-camera/Teams acceptance run has completed.
