# AppleCam development plan

Prepared on 2 October 2026. This plan turns the [product requirements](PRD.md) into a small personal-use macOS release. M0 source implementation has started; local synthetic preview works and the unsigned app/extension build passes. Development signing and a Release archive now pass after agreement acceptance and device registration; notarization is being checked separately. M0 remains incomplete. Estimates are engineering estimates, not completion dates or commitments.

## Delivery approach

First prove signing, camera-extension startup, frame transport and Teams web enumeration on the owner's Mac. Then build the colour key and small native interface. Final quality and release checks must use the actual BRIO, glasses and conference-call environment.

Use the owner's existing Apple Developer membership. Select the correct team in Xcode when implementation begins; the account email supplied in chat does not identify the signing team or prove a usable Developer ID identity. Signing setup must stay in Apple tooling and local secure storage.

## Milestones and effort

| Milestone | Deliverable | Estimated focused effort | Exit condition |
| --- | --- | --- | --- |
| M0 | Signed camera transport and Apple controls feasibility | 1 to 3 working days | Real extension output in Teams web with SIP enabled; initial install and replacement evidence |
| M1 | Tested green-screen processing | 2 to 4 working days | Colour sampling, soft matte, spill controls and still-image composite pass automated checks |
| M2 | Native app and settings | 2 to 3 working days | Complete setup and call flow, saved settings and correct capture states |
| M3 | BRIO quality and performance qualification | 2 to 5 working days | Glasses comparison accepted; 30-minute performance and fault tests pass |
| M4 | Signed personal-use release | 1 to 3 working days | Clean install, upgrade, removal and release evidence pass |

Total estimate: 8 to 18 focused engineering days, approximately 2 to 4 weeks. Apple account setup, certificate availability, OS defects and owner review can add elapsed time. A minimal visible prototype may arrive within the first several days after signing works; it will not constitute a release.

## M0 Camera transport and Apple controls feasibility

### Implementation

1. Select the owner's signing team and verify the app and extension entitlements. Establish a signed, notarized installation route that keeps SIP enabled.
2. Create an Xcode project with a native app, an embedded Camera Extension target and test targets. Use explicit distinct bundle identifiers; determine the exact identifiers after selecting the team.
3. Publish a visibly labelled development test pattern to verify activation, enumeration, frame timing and output format. This is an explicit diagnostic mode, never a runtime substitute after failure.
4. Add AVFoundation capture of the selected BRIO in the app and a Core Media I/O sink-to-source transport in the extension. Verify an explicitly selected unprocessed development feed only in local receivers and the Teams pre-join preview. This diagnostic mode must not ship in the normal product.
5. Check orientation, colour range, 1080p at 30 fps, timestamps, consumer counts and bounded queues. Capture and publication must stop when explicitly disabled.
6. Verify Apple effects can remain enabled alongside the keyer. The owner removed the unreliable Open Apple Video Effects action in build 12; effects are controlled through macOS.
7. Install an incremented extension version and verify an actual running process and delivered frames. Record any deferred reboot requirement; do not try to overcome it by modifying macOS services.

### Required evidence

- Correct app and extension signatures, matching team and expected entitlements.
- SIP enabled throughout the installation and runtime checks.
- Camera extension registration, process startup and device enumeration checked separately.
- BRIO frame delivery in Chrome and the actual Teams web pre-join preview.
- A separate receiver displays the same development source correctly.
- Start and stop, preview plus consumer, camera disconnect, process exit and one version replacement behave correctly.
- Apple controls open for the capture app; chosen Apple effects do not block keying.

M0 passes only when the selected architecture works under normal protections. If it does not, record the exact failing layer and pause dependent transport work. Algorithm unit work can continue independently, but no alternate driver, private service patch or hidden output path is introduced.

Requirements addressed: AC-APL-01, AC-APL-02, AC-CAP-01, AC-CAP-02, AC-CAP-03, AC-CAP-04, AC-VIR-01, AC-VIR-02, AC-VIR-03, AC-VIR-04, AC-OPS-01, AC-OPS-02, AC-OPS-03, AC-TST-02.

## M1 Green-screen processing

Implement the processing module independently of the UI. Define a CPU reference for colour distance, alpha generation and spill removal, then compare the GPU implementation against it using fixed inputs and documented working colour space.

Implement a key colour picker, independent tolerance and soft-edge parameters, conservative spill suppression and an opaque composite over JPEG or PNG. Preserve buffer metadata and clear colour-space assumptions. A hard green-channel threshold alone is insufficient for the glasses requirement.

Include synthetic known-alpha fixtures for foreground patches, glass-like partial transparency, fine lines and soft edges. Prove that neutral patches remain neutral and that all output values are finite and bounded. Surface unsupported images and invalid parameters explicitly.

Exit condition: automated processing tests pass and processed output is visible in the development receiver with no raw automatic substitute. Update the measured processing baseline before ratifying performance targets.

Requirements addressed: AC-KEY-01, AC-KEY-02, AC-KEY-03, AC-KEY-04, AC-KEY-05, AC-TST-01, AC-VIR-04, AC-PER-02.

### M1 progress — 2 October 2026

The first processor and native controls are implemented. CPU/GPU parity, calibrated partial transparency, neutral patches, soft transitions, spill suppression, background crop/orientation, coordinate sampling, rejected inputs and full-cadence processed preview have automated coverage. Short live BRIO preview checks show approximately 30 fps with processing enabled. The signed app includes system image import and session-only settings.

M1 is not marked complete: processed output in the independent camera receiver has not been validated, and broader fine-line/motion quality fixtures and real glasses review remain. M0 extension activation and browser delivery are still open. No transport alternative or raw processing fallback has been introduced.

## M2 Native application and settings

Build the menu-bar panel, preview, labelled controls and onboarding steps. Settings should be versioned and validated; background images are imported through the system file picker and retained in the user's app storage. No foreground image or video recording is persisted. Sampled RGB key colours are saved as calibration values with the owner-requested automatic settings.

Implement an explicit state model for disabled, ready, previewing, streaming and unavailable states. Track preview demand separately from external consumers. A disabled output cannot reopen the source in response to a browser request. Closing a configuration window does not stop an enabled call.

Allow Apple effects to coexist with keying without effect-conflict warnings or publication gates. Keep the Apple controls button available when useful and document which camera-specific effects have been verified. Avoid duplicating unsupported Apple controls inside the app.

Exit condition: a first setup and subsequent call can be completed from the native interface, and settings, accessibility, idle behavior and injected failures pass their tests.

Requirements addressed: AC-UX-01, AC-UX-02, AC-UX-03, AC-UX-04, AC-APL-03, AC-APL-04, AC-PRV-01, AC-PRV-02, AC-CAP-03, AC-VIR-03, AC-VIR-04, AC-PER-03, AC-TST-01.

## M3 Quality and performance qualification

Use the actual BRIO and backdrop under recorded lighting conditions. Compare Apple background replacement and AppleCam on matched scenes, with only one background processor active in each case. Inspect transparent lens areas, reflected green, eye detail, frame edges, hair, hands and motion separately.

Tune the key while keeping the automated fixture suite stable. Record frame rate, drops, frame age, processing time and app-plus-extension memory over a 30-minute call. Measure local pipeline behavior separately from Teams' encoding and network adaptation.

Test long calls, camera disconnect, browser refresh, permission denial, background image failure, unexpected host exit, effect changes and multiple consumers. Include a 100-cycle start and stop exercise; do not claim broad hardware support from this one-machine run.

Exit condition: all quantitative budgets are met or revised with rationale before acceptance, no raw substitute frames are emitted, and the owner accepts the real glasses result.

Requirements addressed: AC-KEY-05, AC-CAP-04, AC-VIR-02, AC-VIR-03, AC-VIR-04, AC-APL-04, AC-PER-01, AC-PER-02, AC-PER-03, AC-PRV-01, AC-TST-02.

## M4 Personal-use release

Produce a signed and notarized app bundle with the extension embedded. Verify the exact release binary, signatures, entitlements and notarization result. Record a clean installation, update from a prior build and removal using standard macOS mechanisms. Check the behavior of pending extension replacement and uninstall states.

Provide a short installation and troubleshooting guide, known limitations, tested camera and browser versions, and a release manifest containing the source revision and artifact hash. Do not publish to the App Store or GitHub releases as part of a local personal-use build unless separately requested.

Exit condition: all P0 requirement evidence is linked, conditional Apple effects are accurately described, and the owner can use the camera for a call without a development diagnostic mode.

Requirements addressed: AC-OPS-01, AC-OPS-02, AC-OPS-03, AC-PRV-01, AC-PRV-02, AC-UX-04, AC-TST-01, AC-TST-02.

## Dependencies before implementation

| Dependency | Current state | Needed action |
| --- | --- | --- |
| Xcode and macOS SDK | Verified installed | No installation needed |
| Developer membership | Owner confirms existing membership | Select the intended team in Xcode |
| Apple Development identity | One valid identity found locally | Team confirmed from certificate organizational unit; development provisioning and signing passed |
| Developer ID Application signing | Xcode signed both submitted bundles with Developer ID | Await notarization and verify the exported artifact |
| Camera and physical screen | BRIO found; physical screen reported by owner | Validate actual camera formats and test lighting |
| Primary browser and scope | Owner confirmed BRIO, Chrome, 1080p 30 fps and still image | Validate this scope in M0 |
| Real quality fixtures | Not captured | Capture only when needed with the owner's consent; keep them local |
| Teams preview and remote verification | Not tested for AppleCam | Local pre-join proof in M0; coordinated call evidence before release |

## Unit testing and implementation order

Add tests alongside each module rather than deferring them to the end. The settings schema, state reducer, queue behavior and reference keyer are suitable for deterministic unit tests. GPU output requires a Metal-capable host and a comparison against reference results. OS activation, TCC prompts and browser delivery require integration checks; the reasons are documented in the [Validation plan](VALIDATION_PLAN.md).

The owner subsequently requested implementation. M0 now has native app and extension targets, a development transport, diagnostic capture and synthetic tests. Development signing is now verified. Complete notarization, then actual extension, BRIO and browser validation. No OS service changes or permission exceptions are required by this implementation.
