# AppleCam environment and prerequisites

Snapshot date: 2 October 2026, using the owner's Europe Zurich date context. These are observations from planning and the first implementation session, not certification of a working AppleCam camera.

## Local environment verified

| Item | Observed value |
| --- | --- |
| Machine | Mac Studio, model Mac13,2 |
| Chip and memory | Apple M1 Ultra, 64 GB |
| macOS | 27.0.1, build 26A434, observed earlier in this session |
| System Integrity Protection | Enabled, rechecked during planning |
| Active Xcode path | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | 27.0, build 27A266a |
| macOS SDK | 27.0 |
| Swift | Apple Swift 6.4 |
| Primary connected webcam | Logitech BRIO |
| Other camera discovered | iPhone Continuity Camera; not selected or tested |
| Chrome | 154.0.8037.95 |
| AppleCam destination | `/Users/ugubser/Documents/GitHub/AppleCam/` |
| Initial folder state | Empty; not a Git repository |

No ancestor `AGENTS.md` was found in the checked parent chain. The owner-supplied contributor principles are preserved in the project's [contributor instructions](../AGENTS.md).

## Signing readiness

The owner confirms an existing Apple Developer membership. A read-only local keychain identity query found one valid **Apple Development** signing identity and no **Developer ID Application** identity in the returned results. The later implementation check read the public certificate organizational unit and confirmed team `M8QBZK948M`. The parenthesized suffix in an Apple Development certificate display name is a member identifier and must not be used as the signing team. Private keys were not exported.

For the intended signed and notarized app route, M0 must select the owner's team and establish the appropriate Developer ID signing and notarization configuration. The certificate may already exist in the developer account even though it was not found locally. No new certificate, profile or account setting was created during planning.

Keep account passwords, two-factor codes, certificate private keys and notarization credentials in Apple tooling or the keychain. Do not put them in project documents, a committed build configuration or test fixtures. The membership login supplied in chat is deliberately omitted from versionable project files.

## API availability check

The installed macOS SDK contains declarations for the system Video Effects UI action, Background Replacement state, Portrait state, Studio Light state and Core Media I/O source and sink streams. A compile-only Swift probe imported AVFoundation, CoreMediaIO, CoreImage and CoreImage.CIFilterBuiltins and successfully type-checked references to these APIs, including source-over compositing.

The probe was supplied on standard input; no application was built or run. It did not open the camera, display system controls, request TCC permissions or install an extension. Its result establishes declarations and Swift compatibility only.

SDK inspection also confirmed that the Background Replacement enabled and active properties are read-only. Public UI presentation is available on macOS; app-side status inspection is distinct from changing system effect settings.

## Prior camera failure in this session

Earlier diagnostics found OBS 33's extension registered as active and enabled while its process was absent. An older OBS version was waiting for removal at reboot, and logs showed removal of the previous service around extension replacement. The owner attempted to restart the camera-registration daemon, and SIP refused the action.

This is evidence of an unresolved local extension activation or lifecycle problem; it does not establish a general macOS defect or the exact cause. AppleCam uses the same broad system-extension infrastructure, so M0 must test startup and a version replacement on this machine. The plan contains no OS service restart, SIP change or cleanup of OBS.

## Setup still required

| Action | When | Status |
| --- | --- | --- |
| Select the intended Apple development team | M0 | Team `M8QBZK948M` configured; development signing verified |
| Establish Developer ID signing and notarization | M0 | Xcode distribution signing verified; upload succeeded; Apple processing |
| Choose app and extension bundle identifiers | M0 | `com.vanguardsignals.AppleCam` and `.CameraExtension` configured; development provisioning passed |
| Verify BRIO formats and active Apple effect capabilities | M0 | Not done |
| Activate and approve an AppleCam extension | M0 | Not done |
| Verify Chrome and Teams web receive AppleCam frames | M0 | Not done |
| Capture private glasses fixtures with consent | M3 preparation | Not done |

The owner subsequently requested implementation. The unsigned app and extension build and local test-pattern preview have passed. Provisioning with the correct team returns “Unable to process request - PLA Update available” and instructs the account holder to accept the updated Program License Agreement. No extension installation or camera-service mutation has occurred. Agreement acceptance remains the account holder’s action. Developer ID and notarization setup follow that gate.

## Subsequent signing verification

The owner reported agreement acceptance. Development provisioning then succeeded after Xcode registered this Mac. Both development-signed bundles pass strict signature verification with matching team `M8QBZK948M`, sandbox entitlements and application groups. The extension Mach service has the correct team prefix. A Release archive succeeds. The initial distribution submission reached Apple’s notary service but returned HTTP 403 with a missing-or-expired agreement error. The retry then uploaded successfully; Apple is processing the app. Propagation delay is a possible explanation for the transient first failure, not a verified cause. See `artifacts/verification/m0-signing.json` for the latest result.
