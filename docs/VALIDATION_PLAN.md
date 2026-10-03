# AppleCam validation plan

Prepared on 2 October 2026. The checks below remain the full acceptance plan. Initial automated core/media tests and the local synthetic preview have now run; see `artifacts/verification/m0-first-build.json`. Extension, camera and browser acceptance checks remain unexecuted. The planning package has a separate document consistency check; that check is not application acceptance.

## Test environment and evidence

The owner-confirmed target is the current Mac Studio with Apple M1 Ultra, Logitech BRIO and Teams web in Chrome, using 1080p 30 fps and a still background. The observed OS is macOS 27.0.1. Record the exact OS build, camera format, app build, browser version, extension version and lighting for each run. Installed versions can change; the [environment snapshot](ENVIRONMENT.md) is not a permanent support statement.

Use a local Teams pre-join preview for M0. A pre-join preview does not prove what a remote participant sees. A release call check requires an explicitly coordinated participant and their confirmation of the outgoing image. Do not send meeting invitations, images or messages automatically.

Save public-safe summaries, counters and build hashes under `artifacts/verification/` or `artifacts/benchmarks/`. Real camera fixtures belong in ignored private paths and require consent before recording. Do not store real participant recordings, account details or signing material in source control.

## Automated behavior tests

| Test | Behavior covered | Test method |
| --- | --- | --- |
| UT01 Colour sampling | Sampling through crop, scale and preview mirror transforms | Known colour patches and coordinate transforms |
| UT02 Matte generation | Key range, opaque foreground and fractional alpha | CPU reference with analytic fixtures and boundary values |
| UT03 Soft edges | Smooth transitions without invalid alpha or parameter coupling | Ordered distance samples and thin-line fixtures |
| UT04 Spill removal | Lower excess green, preserve neutral patches and valid values | Reference pixels at zero, partial and maximum strength |
| UT05 Compositing | Correct alpha, crop, colour contract and opaque output | Known foreground and background pairs; invalid assets |
| UT06 Settings | Round trip, schema version, valid ranges and missing assets | Temporary local settings store and explicit error assertions |
| UT07 Lifecycle | Enable, disable, preview, consumers, disconnect and host exit | Pure state model with ordered and overlapping event sequences |
| UT08 Transport | Bounded queue, frame expiry, monotonic timing and buffer ownership | Test transport adapter, controlled clocks and stress sequences |
| UT09 Effect handling | No effect-state gate; keying, sampling and publication remain available | Synthetic producer continuity tests; actual Apple effects require live integration checks |
| UT10 Privacy on failure | No raw substitute, automatic source switch or stale replay | Tagged input and expected output; injected faults at each stage |
| GT01 GPU parity | GPU key and composite agree with reference | Metal-capable test runner, fixed fixtures and declared error bounds |

Start with Swift Testing for independent logic and XCTest where OS or UI test facilities require it. Keep tests against observable behavior; do not merely assert the implementation's own constants. GPU cases may need serial execution and an available Metal device. An unavailable GPU test environment must be reported as skipped, not counted as a pass.

## Quality fixtures and proposed thresholds

Use small deterministic generated fixtures with known foreground, background and alpha. Cover neutral skin-like patches, opaque eyeglass frame lines, partial transparency, fine hair-like strands, green backdrop gradients and soft motion edges.

Initial proposed numerical thresholds are alpha mean absolute error at most 0.02 on recoverable synthetic regions, GPU versus reference alpha maximum error at most 0.01 and output RGB maximum error at most 2 out of 255 after agreed conversion. Define working colour space, tolerances and fixture generation before applying these thresholds. Revise them through a documented decision if the intended math or quantization requires different limits; do not select thresholds after looking for a favourable pass.

Naturally green foreground pixels can be indistinguishable from the backdrop in a pure colour key. Keep this ambiguity outside the synthetic recovery threshold and document it. Do not claim that these fixtures prove physical glass reconstruction.

For the owner's glasses, compare matched scenes using Apple Background and AppleCam separately. Use the same image, framing, camera, illumination and output size. Record separate judgments for:

- Green backdrop visible through the lens and loss of detail behind it.
- Green reflections and residual tint on frames, skin and lenses.
- Eye visibility, tinted lenses, fine frames and hair.
- Hands crossing the face, head movement and lighting variation.

The owner must accept a useful reduction in green in the lens region without unacceptable damage to eyes or frames. There is no numeric promise of perfect recovery for real reflections. Review both a local preview and the outgoing picture seen by a separate receiver.

## Integration and release checks

| Test | Check | Acceptance evidence |
| --- | --- | --- |
| IT01 Normal installation | Signed package, entitlements, approval and SIP | Signature and notarization reports; activated extension and real frames |
| IT02 Browser enumeration | Chrome and actual Teams web camera picker | AppleCam selected and its distinct output visible in the pre-join preview |
| IT03 Native controls | Public system UI action and capture attribution | Apple controls apply to the host capture; selected effects coexist with keying |
| IT04 Orientation and colour | Chart, aspect ratio and outgoing mirror behavior | Correct labels and colours in an independent receiver |
| IT05 Consumer lifecycle | Preview, browser and a second local receiver | No duplicated capture, interruption of remaining consumers or demand after disable |
| IT06 Failure handling | Source removal, permission denial, invalid asset and host exit | Specific errors and no substitute or repeated stale frames from AppleCam |
| IT07 Start and stop | 100 cycles, refresh and reconnect | No leaked capture session, growing queue or continuing memory trend |
| IT08 Extension replacement | Install an incremented build and remove prior build | No readiness claim before frames; deferred reboot state identified correctly |
| IT09 Long call | 30 minutes with processing and representative movement | Frame rate, drops, latency, memory and idle checks reported |
| IT10 Outgoing quality | Actual BRIO and glasses; separate participant | Matched comparison and owner acceptance recorded |
| IT11 Local processing | Media storage and network behavior attributable to AppleCam | No unexpected recordings or app-originated network connections |
| IT12 Personal release | Exact signed build, reinstall, upgrade and uninstall | Release manifest, installation guide and all P0 evidence linked |

## Why unit tests are insufficient for some checks

OS extension approval, signing verification, TCC camera prompts and extension process launch are controlled by macOS outside the application's unit-test process. Browser device enumeration and a remote Teams picture cross process and network boundaries. Camera optics, reflections and lighting are physical inputs. Unit adapters can test AppleCam's reaction to these events, but cannot establish that the actual OS, browser and hardware delivered them correctly. These features therefore require the integration and owner review checks above.

This is not an exception to the unit-testing principle: independent behavior still receives unit tests, and the untestable boundary is documented explicitly.

## Performance measurement

For each run, measure the host and extension together, using a monotonic clock and per-frame sequence information. Report average and percentile processing time, observed capture and publication rates, drops by stage and frame age. Measure memory after warm-up and periodically through the full run.

The proposed local p95 budget of 33 ms starts at the input capture callback and ends at extension source publication. It excludes sensor time, browser display and network delivery. Compare independent receiver timing with an unprocessed development baseline to understand additional local delay; do not label it end-to-end call latency.

The 30-minute test targets at least 29.5 locally published fps, fewer than one percent local pipeline drops and no continuing memory growth. Confirm adequate lighting and the BRIO's actual 30 fps input before assessing pipeline performance. Document Teams' received resolution separately because Teams can adapt its stream.

After the last preview and enabled output consumer close, target capture release within two seconds. Verify that GPU processing submissions cease; other system GPU usage is not attributable to AppleCam without evidence.

## Requirement traceability

| Requirement | Planned verification | Primary milestone |
| --- | --- | --- |
| AC-CAP-01 | UT06, UT07, IT05, IT06 | M0 |
| AC-CAP-02 | IT02, IT04, IT09 | M0 |
| AC-CAP-03 | UT07, IT05, IT07, IT09 | M2 |
| AC-CAP-04 | UT01, UT05, IT04 | M0 |
| AC-KEY-01 | UT01, GT01 | M1 |
| AC-KEY-02 | UT02, UT03, GT01 | M1 |
| AC-KEY-03 | UT04, GT01, IT10 | M1 |
| AC-KEY-04 | UT05, UT06, GT01, IT06 | M1 |
| AC-KEY-05 | UT02, UT03, GT01, IT10 | M3 |
| AC-UX-01 | UT07, IT05, accessibility review | M2 |
| AC-UX-02 | UT07, IT05, IT06 | M2 |
| AC-UX-03 | UT06, UT07 | M2 |
| AC-UX-04 | IT01, IT02, IT12 | M2 |
| AC-APL-01 | IT01, dependency and API review | M0 |
| AC-APL-02 | IT03 | M0 |
| AC-APL-03 | UT09, UT10, IT03, IT06 | M2 |
| AC-APL-04 | IT03, IT10, per-camera capability record | M3 |
| AC-VIR-01 | IT01, IT02, IT08 | M0 |
| AC-VIR-02 | UT08, IT07, IT09 | M0 |
| AC-VIR-03 | UT07, UT08, IT05 | M0 |
| AC-VIR-04 | UT07, UT10, IT06 | M0 |
| AC-OPS-01 | IT01, IT12 | M0 |
| AC-OPS-02 | IT08, IT12 | M4 |
| AC-OPS-03 | UT07, IT01, IT06, IT08 | M4 |
| AC-PRV-01 | UT10, IT06, IT11 | M3 |
| AC-PRV-02 | Ignore-rule review and release content review | M4 |
| AC-PER-01 | IT09 | M3 |
| AC-PER-02 | UT08, GT01, IT09 | M3 |
| AC-PER-03 | UT07, IT05, IT09 | M3 |
| AC-TST-01 | Automated suite and coverage review | M4 |
| AC-TST-02 | IT01 through IT12 and owner acceptance | M4 |

## Acceptance record

Each milestone must distinguish planned, attempted, passed, failed and deferred checks. A skipped check is not a pass. Store the tested build and environment beside the result. Do not use app readiness text, extension registration alone or a successful compile as a substitute for actual camera frames.

## First implementation coverage

Fourteen automated tests cover timestamp ordering, expiry and invalid formats; queue backpressure and stall detection; the demand reducer; actual 1080p Core Image test-pattern rendering; stopping output; producer release across repeated start/stop; and missing-camera failure without substituted output. They run without opening a physical camera or installing an extension. The demand reducer tests do not establish that the host is wired to external consumer counts.

SystemExtensions activation, provisioning, TCC prompts, CMIO cross-process ownership and signing authorization are OS-mediated interactions. They cannot be established by an isolated unit test and require the signed integration checks in this plan. The native capture path has since been checked live with the BRIO; transport still needs signed integration validation. M1 now includes GPU/reference and synthetic processing tests (see the progress record below).

## Full-rate preview regression verification

The suite now has 27 tests. Additional coverage verifies that every generated pattern frame reaches the preview callback (comparing exact counts rather than imposing a hardware-speed threshold), a blocked UI retains only the newest image with one delivery pending, replaced frames are released, old-session deliveries cannot consume new-session images, and rate counters use real elapsed time and report zero during stalls.

The BRIO-specific startup ordering cannot be established by a unit test: the hardware session applies its own preset when it starts. A live integration check compared the 24 fps readback before the fix against 30.00003 fps after moving format/timing configuration after session startup. The live capture and preview-update counters were then checked independently. No camera images were recorded.

## Green-screen progress record — 2 October 2026

The suite now has 41 passing tests. Processing checks cover screen removal across brightness levels, neutral foreground preservation, smooth monotonic matte transitions, an explicitly calibrated known-alpha 0.5 fixture, spill reduction, invalid/nonfinite settings, GPU/reference agreement within 2/255, opaque output, centred aspect-fill crop and vertical orientation, source sampling at frame corners, rejection of missing/transparent backgrounds and wrong dimensions, no raw preview after invalid startup settings, and a processed 1080p producer interval at full preview cadence. The producer sampler is also checked against original green pixels after those pixels have become blue in preview.

GPU timing is measured after five warm-up frames over 60 frames, excluding decoding, capture, preview and transport. The measured mean is approximately 0.40 ms on the M1 Ultra. Complete synthetic producer cadence measured 29.9 fps; live BRIO host capture/main-thread preview counters read approximately 30 fps with the sample background and keying enabled. Results are short local measurements, not the IT09 endurance test or extension latency measurements.

The known-alpha test verifies the compositing math after explicitly calibrating the matte midpoint; it does not establish automatic recovery of arbitrary lens transparency. Fine hair/motion, actual lenses and reflections need the planned owner review. File picker interaction, native slider behavior, TCC and live hardware timing require app checks rather than isolated unit tests. The file picker and BRIO preview have been exercised in the signed app; owner-selected real-scene colour picking and visual tuning remain to be assessed. No private camera frames were saved.

The focused producer-sampler regression also passed while the live BRIO app was running. Its startup interval measured 28.85 fps under concurrent load; no sustained throughput claim is inferred from that one-second window. A later live counter sample was capture 29.0 / preview updates 30.0 fps, consistent with one-second scheduling variation.

## Virtual-camera activation and producer authorization — 2 October 2026

The notarized build (2) was installed with SIP enabled and approved by the owner. macOS reported `activated enabled`; AVFoundation discovered exactly one AppleCam device with a 1920 × 1080, 30 fps format. This establishes activation/discovery, not received frames.

The first producer start returned OSStatus -4, with Core Media I/O logging `Refusing streaming request`. Diagnostic build (3) established that `CMIOExtensionClient.signingID` was the literal `unknown` for the notarized host on this Mac. The fix removes that unreliable preliminary comparison while retaining the actual Security.framework requirement: Apple signature anchor, exact host bundle identifier, and exact signing team. No accepting-on-error behavior is added.

`Tests/Integration/verify-producer-signature.sh` exercises this requirement against the signed app: correct identity/team passes, wrong identity fails, wrong team fails, and an unrelated Apple-signed executable fails. These are native code-signing integration checks. The role-account lookup of a live producer and Core Media I/O callbacks cannot be established by isolated unit tests and remain subject to the installed extension's runtime check. Build (4) exposed a second rejection: ordinary live-process signature lookup returned status 100001 because the extension sandbox cannot read the producer app bundle.

The diagnostic app must be reopened after extension replacement on this Mac to refresh its device discovery. Reopening does not preserve the current session's background/key settings. The original tuned process exited during the initial handover; no camera image or sample was recovered from process memory or saved to disk.

Build (5) requests kernel-backed signing information with the public `kSecGuestAttributeDynamicCode` attribute and retains the full identifier/team/anchor requirement. `Tests/Integration/producer-dynamic-signature.swift` reproduces denied bundle reads in a restrictive sandbox: ordinary lookup fails, dynamic lookup succeeds, correct identity/team passes, and incorrect identity or team fails. This is an OS integration regression, not an isolated unit test. All 41 unit/media tests also pass. Installed stream verification is recorded separately.

Build (5) is now installed and enabled. Live restart logs confirm producer signature verification and the AppleCam Input stream starting. Google Chrome opens AppleCam Video; the owner reports black output in Google Meet before and after restarting the producer. Host capture and preview counters read 30 fps. These facts do not establish that the extension forwards usable frames. Build (6) adds bounded metadata-only transport diagnostics (reader count, pending consume, consumed/sent/empty/missing-image/rejected totals, first rejected timestamp). No pixels are logged. These counters require the OS-mediated signed integration check; isolated unit tests cannot verify cross-process delivery.

## BRIO publication timing — 2 October 2026

The owner confirmed that the test pattern becomes visible in Google Meet after disabling Apple's Background replacement. The earlier black/background picture was not proof of failed transport. Build (6) logs show consumed and forwarded frames, with no rejected frames in those pattern sessions.

The subsequent BRIO send stopped with `FrameGate.Rejection error 2`, verified to mean `expired`. The extension session started at 14:29:34 and stopped at 14:29:36 with zero consumed frames: rejection happened in the host before delivery. This proves the age check failed, but does not distinguish capture startup delay from a source-clock difference; the previous build did not log the rejected host timestamp.

Build (7) converts capture PTS from the session synchronization clock into host time using Apple's public clock conversion API. It preserves capture age rather than relabelling delayed frames as current. Host admission drops isolated frames older than 150 ms and stops with a readable error after two continuous seconds of stale frames. Invalid, future, out-of-order and incorrectly formatted frames still fail immediately; the extension's strict freshness gate remains unchanged. No substitute frames or raw-camera fallback are introduced.

All 48 unit/media tests pass. Seven new tests cover a different clock epoch without erasing capture age, missing/invalid timestamps, stale startup recovery, sustained staleness, fresh-frame recovery, other fatal errors and readable error descriptions. The Release archive builds. Actual BRIO-to-Meet recovery requires owner installation and live verification. Build (7)'s host is compatible with the enabled build (6) extension.

Owner follow-up after the build (7) installation/retry instructions: "this works." Record the BRIO/green-screen-to-Google-Meet functional check as owner-confirmed success. This does not establish sustained frame rate, latency, a 30-minute endurance pass, Teams compatibility or final keying-quality acceptance. No camera images were captured for this confirmation.

## Calibration controls — build 8

55 unit/media tests pass. New coverage checks bounded additive/replacement sampling and invalid samples without partial mutation, neutral and weakly green dark-detail protection, preservation of saturated dim green removal, enclosed-hole filling versus open edges, and CPU/GPU agreement for multi-sample selection, protection, refined mask and composite. A producer test injects an in-memory transport and checks actual published sample pixels remain blue composites while the local preview is a black mask, then switches back to Picture; sampling still reads the original green image. This test establishes host routing, not browser delivery.

A separate signed development instance exercised background import with a synthetic fixture, mask selection, replacing a sample from the mask view, adding a second sample, removing it, switching back to Picture and stopping. Native counters were around 30 fps. No physical camera was opened in this test and the owner's existing installed app remained running. UI copy and layout were inspected.

Focused 1080p processing timing after five warm-up frames over 60 frames: default settings approximately 0.53 ms, all six samples/protection/hole filling/mask approximately 0.60 ms. The earlier suite ran alongside a build and measured 3.62 ms; the focused measurement documents the quieter check rather than hiding that load-dependent result. The full synthetic producer interval was 29.8 fps. These are short measurements; live BRIO hair/chair quality and sustained browser frame rate need owner acceptance.

Mask preview has a separate local buffer and never replaces the composite passed into transport. The CMIO contract and signing requirements are unchanged; the existing activated extension remains compatible. No extra permissions or camera-service changes are required.

Build (8) Developer ID export and notarization are accepted. Strict signature verification, stapled ticket validation, Gatekeeper assessment and producer signature requirement checks pass. The final notarized app layout was inspected separately and that stopped test instance was closed. The owner performs the Applications replacement; the original installed app remains running. See `artifacts/verification/calibration-controls-build-8.json`.

### Build 9 — live switching and Apple effects recovery (2026-10-02)

- 60 automated tests passed (40 core, 20 media). New cases exercise actual synthetic producer pixels across raw → green-screen → raw → replacement-background transitions, preserve the publishing transport, switch local/published destinations, pause for injected Apple effects while capture continues, resume keyed output, and stop on invalid live settings or transport startup failure. Synthetic processed cadence: 29.85 fps.
- Release archive compiled successfully. Final build 9 notarization accepted; strict signatures, stapled ticket, Gatekeeper and producer signature requirement checks passed. Artifact: `build/Notarized-Flow-9/AppleCam.app`. No extension transport or authorization contract changed.
- Separate signed test instance: selected real Logitech BRIO, used Start camera & open Apple Video Effects, confirmed unprocessed local capture with Portrait already enabled (~15 fps). Enabling Green screen opened the image picker while capture remained active. Importing the synthetic background paused the processed picture with camera controls still active; explicit Green screen off restored preview without restarting. Stopped and quit only the test instance; installed build 8 and its session remained untouched. No real-camera image was saved or sent to the virtual camera during this check.
- macOS Control Center logs confirmed the effects request targeted AppleCam's active BRIO context with Portrait enabled and no unavailable reasons. The system panel's accessibility inspection timed out, so visible panel presentation and user-operated Portrait/Background toggles remain owner acceptance checks. The public API does not report panel presentation success and does not permit changing these effect switches programmatically.
- Final UI-only adjustment keeps the Capture rate updating while processed output is paused. The producer regression tests are unchanged by this display fix; final archive compilation verifies it.
- Existing live ~15 fps reading remains a separate performance issue; this change does not claim to solve it or qualify a conference call.

Owner acceptance after Finder replacement: select BRIO, use Start camera & open Apple Video Effects, confirm the macOS panel appears, and disable Portrait/Background for keying. Start Preview locally, toggle Green screen repeatedly, change background while running, then Send to AppleCam and repeat the toggles in a meeting preview. Turning Green screen off intentionally sends the unprocessed picture. Confirm the meeting stays selected on AppleCam throughout. Settings/background are session-only and must be reselected after quitting the previous app.

### Build 10 — remove Apple-effects restrictions (2026-10-02)

The owner explicitly requested removal of all Apple-effect restrictions after confirming the combination works. This supersedes build 9's effects gate and its owner acceptance instructions. The producer no longer reads Background/Portrait state, pauses on those effects, or disables preview/sampling. Related UI warnings and paused messages were removed. The public effects button and live green-screen/destination switching remain. Invalid settings, processing failures, disconnected sources and frame transport checks still retain their existing behavior.

Replaced the obsolete pause/resume test with continuous keyed publication, preview and live sampling/calibration coverage. Real Apple effect state is controlled by macOS and cannot be set in unit tests using public APIs; live integration checks and owner observations provide that coverage.

Build 10 validation: 60 tests passed (40 core, 20 media), release archive succeeded, and Developer ID notarization, strict signature verification, stapled ticket, Gatekeeper and producer requirement checks passed. Synthetic processed preview measured 29.93 fps. Artifact: `build/Notarized-Effects-10/AppleCam.app`. The installed build 9 was actively sending video, so it and its session were left unchanged; no additional camera session or meeting test was run. The owner's report establishes their working effects combination, not a general quality certification for every effect configuration. See `artifacts/verification/apple-effects-unrestricted-build-10.json`.

### Build 11 — automatic preference saving (2026-10-02)

- 71 automated tests pass (46 core, 25 media). Eleven new tests cover complete preference round-trip including six samples and every key control, model autosave/restoration, disabled capture/publication after restore, unavailable camera retention, survival of original-background deletion, missing-background refusal to publish unprocessed frames, explicit recovery from unreadable settings, visible save errors, rejected invalid/versioned data, managed image replacement and failed-commit cleanup.
- The persistence tests use isolated temporary directories and the synthetic background fixture. No actual user preferences, camera image, system effects or installed capture session is changed by these tests. Actual CameraModel observers are exercised in tests, rather than only a stand-alone JSON codec.
- Small settings snapshots use atomic writes on each change; imported background bytes are retained in the app's own sandbox storage and are not rewritten for slider changes. Camera frames are never stored. Startup applies preferences without invoking capture or publication.
- Release archive compiled successfully. Existing camera extension protocol and permissions are unchanged. This work does not implement background recording or automatic streaming on app launch.
- Synthetic processed cadence: 29.85 fps; this is not a real-camera or meeting performance qualification.
- Owner acceptance after replacing the app: choose camera/background, adjust samples and sliders, quit AppleCam completely, reopen it, and confirm preferences restore with capture stopped. Select Preview locally or Send to AppleCam explicitly. The first upgrade from build 10 requires setup once, since build 10 never saved these values.

Build 11 distribution: Developer ID notarization accepted; strict signatures, staple, Gatekeeper and producer signature requirements passed. Artifact: `build/Notarized-Autosave-11/AppleCam.app`. The full signed-app quit/relaunch is an owner acceptance check; automated restoration tests exercise fresh CameraModel instances and persistent files. See `artifacts/verification/automatic-settings-build-11.json`.

### Build 12 — per-camera profiles, formats and background shortcuts (2026-10-03)

- 88 automated tests passed: 55 core and 33 media. New coverage includes schema-1 migration, independent per-camera calibration/format/preview/disclosure/background restoration, the application termination notification, four-image retention and cross-profile cleanup, missing-camera format preservation, supported fractional/custom rates and disjoint ranges, selected-size frame admission, jitter-resistant output cadence, 720p24/4K30 processed producer frames, and GPU aspect-fit conversion preserving timestamps. Thumbnail dimensions are bounded to 256 pixels independently of the processing background.
- Unsigned universal Debug build and embedded app/extension layout passed. Release archive succeeded. Settings tests used temporary directories. No user calibration file or camera frame was read, changed or recorded.
- Read-only AVFoundation discovery of the connected Logitech BRIO reported 122 distinct resolution/rate intervals. In its current state it exposes nominal 1080p30 and 720p60, with smaller formats, but no 4K format. This verifies metadata availability, not capture performance or the reason for unavailable 4K. Device discovery does not start capture.
- The selected capture format now reaches the virtual sink; the extension accepts negotiated source formats and converts processed frames for the receiving client. This protocol change requires updating the installed extension. The sink reads back its format/rate and refuses mismatches, including an older extension that ignores format selection. Strict producer signing and frame-age checks remain. Extension camera metadata discovery uses the public camera capability entitlement; no physical capture session runs inside the extension.
- OS extension property negotiation, camera consent/activation, camera-specific live timing, picker presentation and actual meeting delivery cannot be established by in-process unit tests. The installed app and extension were left untouched. No live multi-camera/Meet/Teams acceptance or sustained performance claim is made for build 12.

Owner acceptance after Finder replacement:

1. Quit AppleCam, replace it in Applications with build 12, launch it, and click Install camera extension. Follow macOS's approval/result message.
2. Confirm the old camera profile retains its samples, controls and background (now shortcut 1); capture must remain stopped after launch.
3. Select a camera and supported resolution/rate. Start local preview and check actual capture fps. Stop before changing source/format.
4. Assign all four buttons. Switch images live, collapse the green-screen group, and use the buttons while collapsed. Right-click one to replace or clear it.
5. Configure another camera differently; switch back and confirm independent profiles. Quit/reopen and check both again.
6. Send to AppleCam, reselect it in Meet/Teams, and inspect the image at two supported format choices. Check proportions, motion, glasses and hair. Receiving applications may negotiate a smaller resolution/rate; output must remain processed.

Build 12 distribution: notarized export accepted; strict deep signature verification, stapled ticket, Gatekeeper and producer signature requirement checks passed. Host and embedded extension both report build 12. Artifact: `build/Notarized-Profiles-12/AppleCam.app`. See `artifacts/verification/camera-profiles-build-12.json`.
