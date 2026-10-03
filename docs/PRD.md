# AppleCam product requirements draft

Version 0.1. Prepared on 2 October 2026. Product owner: the requesting user. Implementation status: M0 prototype in progress; no product acceptance milestone has passed. See the README and verification record for current evidence.

AppleCam will provide physical green-screen keying for conference calls through a small native Mac app and a camera extension. It should retain the convenience of Apple's camera infrastructure while adding colour-based background removal and control over green spill, particularly around glasses and fine edges. The first release targets the owner's existing Mac and Teams web workflow.

## Problem and intended outcome

Apple's automatic background replacement leaves visible green through the owner's glasses. Teams on the web supports ordinary backgrounds but does not expose the desktop client's physical green-screen feature. OBS's camera extension was approved but did not have a running process during this session; a service restart attempt was blocked by SIP. The underlying cause of that extension failure has not been established.

The desired experience is to choose a webcam and a background, adjust a few keying controls in a preview, then select **AppleCam** as the camera in Teams web. Future calls should reuse the saved settings. Installation and errors should be understandable without root commands or manipulating system services.

## Confirmed requirements and proposed defaults

| Item | Basis | Status |
| --- | --- | --- |
| Physical green-screen support, with attention to glasses | Owner's request and observed problem | Confirmed |
| Native macOS app using Apple camera infrastructure | Owner's stated preference | Confirmed |
| Microsoft Teams web as the meeting client | Owner's current workflow | Confirmed |
| Existing Apple Developer membership | Owner's statement | Confirmed by owner; account access not checked |
| All project artifacts and eventual source in AppleCam | Owner's named destination | Confirmed |
| Logitech BRIO as the primary camera | Connected device found locally; owner confirmed scope | Confirmed |
| Chrome as the primary browser | Owner confirmed scope | Confirmed |
| Apple silicon and macOS 27 as the first supported platform | Current machine and OS | Proposed release boundary |
| 1920 by 1080 pixels at 30 fps | Owner confirmed scope | Confirmed target; M0 must validate delivery |
| Still backgrounds | Owner confirmed scope | Confirmed |
| JPEG and PNG as the initial image formats | Bounded first release | Proposed format support |
| Menu-bar app with a separate preview window | Desired small native interface | Proposed design |

The owner confirmed the BRIO, Chrome, 1080p 30 fps and still-background scope during planning. Other proposals remain explicitly labelled engineering choices.

## Product boundaries

The release uses AVFoundation for capture, Core Image backed by Metal for processing, and Core Media I/O for a camera extension. Apple manages the camera permission and extension infrastructure. AppleCam supplies the keying algorithm and its controls.

AppleCam can open Apple's Video Effects interface through a public API. There is no verified public API for inserting AppleCam controls into that interface. Access to specific Apple effects depends on the camera, capture format and runtime path; opening the interface is not evidence that every effect works.

The first release excludes animated backgrounds, audio processing, recording, streaming to broadcast services, account login, cloud processing, telemetry, automatic AI segmentation, multiple-camera compositing, older macOS certification and Intel certification. Continuity Camera is an exploratory compatibility check, not a release requirement. Custom effects embedded in Apple's own camera panel are outside scope.

## Main user flows

### First setup

1. Install AppleCam in Applications and open it.
2. Activate its camera extension and follow the macOS approval prompt.
3. Grant camera access, select the BRIO and select a background image.
4. Open the local preview and sample the physical backdrop colour.
5. Adjust tolerance, edge softness and green-spill removal while inspecting glasses, hair and hands.
6. Open Apple's controls from AppleCam if needed; choose any effects to combine with green-screen processing.
7. Enable AppleCam, select it in the Teams web camera picker and inspect the pre-join preview with Teams background effects set to None.

The interface must explain extension approval separately from camera permission. It must report when activation requires a later restart, rather than implying that the camera is ready.

### A subsequent call

Open AppleCam, confirm the saved camera and background, and enable it. Teams should retain the selected camera when its own settings permit. AppleCam starts capture for an enabled output consumer or an explicitly opened preview; closing the preview does not interrupt an active call.

### Stop or fix an error

Stop disables capture and frame publication. If the source disconnects, an image cannot be read, or processing fails, AppleCam stops output and explains what needs correction. It does not send the raw feed, choose another camera or change to a different background-removal method.

A receiving browser may retain its last received frame after output stops. AppleCam must not promise that stopping deletes pictures already received or displayed by the meeting client.

## Functional requirements

P0 requirements are required for the first personal-use release. P1 requirements are included only where supported and verified; their absence must be explicit.

### Camera input and framing

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-CAP-01 | P0 | Use the explicitly selected physical camera and retain its stable device identifier. Exclude AppleCam itself from selectable inputs. | Select the BRIO, relaunch and retain it. An absent BRIO produces an unavailable state; another camera is never selected automatically. |
| AC-CAP-02 | P0 | Provide a verified 1080p 30 fps output mode with an explicit capture format. | Negotiate and inspect the actual camera format and extension output. If unsupported, report it; changing the requirement requires a recorded scope decision. |
| AC-CAP-03 | P0 | Capture only when enabled output has a consumer or the user explicitly requests preview. | Closing the last consumer and preview releases the capture session within a proposed two-second target. Disabled output rejects new consumer capture requests. |
| AC-CAP-04 | P0 | Preserve proportions and correct orientation. Keep preview mirroring separate from outgoing mirroring. | A labelled chart appears without stretching or double mirroring in a separate receiver. Any crop is visible in the preview. |

### Green-screen processing

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-KEY-01 | P0 | Sample a key colour from the local preview and show that colour. | Sampling known fixture patches selects their displayed colour within the declared colour conversion tolerance. Sampling operates locally. |
| AC-KEY-02 | P0 | Provide independent tolerance and edge-softness controls. | Unit fixtures show a stable opaque foreground, transparent keyed background and a smooth, bounded alpha transition. Changing one control does not silently change the other. |
| AC-KEY-03 | P0 | Reduce green colour spill with an adjustable strength. | Recorded fixture metrics show lower excess green in designated spill regions without changing neutral reference patches beyond the agreed tolerance. |
| AC-KEY-04 | P0 | Composite onto an explicitly selected JPEG or PNG background. | Output is a complete opaque image, with a documented aspect-fill crop. Unsupported or missing images produce a clear error and stop output. |
| AC-KEY-05 | P0 | Preserve useful detail around glasses, hair, fingers and motion. | Pass the quality protocol in the validation plan using synthetic known-alpha fixtures and owner-reviewed real frames. Replacing green through lenses and correcting green reflections are assessed separately. |

### Native interface and settings

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-UX-01 | P0 | Provide a menu-bar control and an accessible preview window. | The owner can configure the camera and key without opening a production-style scene editor. Controls have labels, keyboard access and visible focus. |
| AC-UX-02 | P0 | Show enabled state, camera use, connected consumer count and errors; provide an explicit Stop action. | State matches the capture and publication counters through preview, call, disconnect and failure tests. |
| AC-UX-03 | P0 | Save camera choice, background and key settings locally with a versioned settings format. | Relaunch reproduces settings. Invalid values are identified; active streaming is not automatically restored on launch. |
| AC-UX-04 | P0 | Explain activation, permissions and the Teams web camera selection in plain language. | A fresh installation reaches a correct pre-join preview using the documented flow without a root command. |

### Integration with Apple controls

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-APL-01 | P0 | Use public Apple capture, processing and extension APIs, with SIP enabled. | Dependency and package review finds no private API hooks, system modifications or legacy DAL plug-in. |
| AC-APL-02 | P0 | Include an Open Apple Video Effects control using the system UI API. | With AppleCam capturing, the button opens the relevant Apple controls. Check actual process attribution, not just that a panel appears. |
| AC-APL-03 | P0 | Allow Apple Background Replacement and Portrait alongside green-screen processing (owner revision, 2026-10-02). | Neither effect pauses preview, sampling or publication, and no effect-conflict warning appears. AppleCam does not change the user’s Apple settings. |
| AC-APL-04 | P1 | Document and test coexistence with supported Apple effects, including Studio Light or Center Stage where available. | Record per-camera capability and output results. Unsupported effects are not advertised as AppleCam features. |

### Virtual camera and lifecycle

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-VIR-01 | P0 | Publish one camera named AppleCam with stable device and stream identifiers. | Chrome and Teams web enumerate it; reopening the app does not create duplicate devices. |
| AC-VIR-02 | P0 | Deliver correctly timed frames through a bounded queue. | Timestamps are monotonic, buffers retain valid lifetimes and a slow consumer cannot cause unbounded queue growth. No expired input is published. |
| AC-VIR-03 | P0 | Support a call and preview at the same time, with correct consumer accounting. | Closing one receiver does not stop another; input capture is shared rather than duplicated. |
| AC-VIR-04 | P0 | Stop camera frame output when source, processing or configuration is invalid. | Fault injection detects no raw substitute frames, stale-frame replay loop, automatic source switch or automatic quality reduction. |

### Installation and privacy

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-OPS-01 | P0 | Provide a signed app and camera extension that install under normal macOS protections. | Verify signatures, entitlements, notarization and actual activation with SIP enabled. Both targets use the chosen development team. |
| AC-OPS-02 | P0 | Handle installation, replacement and removal with clear lifecycle state. | Test an initial installation and a version upgrade. An active and enabled registration is not marked ready until the device can deliver frames. A deferred restart is reported accurately. |
| AC-OPS-03 | P0 | Diagnose errors without automatically changing OS services or other extensions. | Approval pending, permission denied, source missing and activation failure each produce a specific action. No automatic daemon restart or root helper exists. |
| AC-PRV-01 | P0 | Process camera frames locally without recording, uploading or adding network requests. | No media files or network connections are created by a normal AppleCam session. Teams' own networking is outside this boundary. |
| AC-PRV-02 | P0 | Keep signing material, credentials and private camera fixtures out of version control. | Ignore rules and a pre-commit review cover private exports and fixture paths. Diagnostics omit account details, full personal file paths and image contents. |

### Performance and verification

| ID | Priority | Requirement | Acceptance |
| --- | --- | --- | --- |
| AC-PER-01 | P0 | Sustain the selected 30 fps mode in a representative 30-minute call. | Under controlled lighting, local publication averages at least 29.5 fps and pipeline drops remain below one percent. Teams transmission resolution and remote network drops are reported separately. |
| AC-PER-02 | P0 | Keep local processing latency and memory bounded. | Proposed target: capture callback to extension publication p95 at most 33 ms; queue capacity at most two pending frames. Memory has no continuing growth after warm-up. Record the measurement boundary. |
| AC-PER-03 | P0 | Avoid background camera or GPU work when idle. | With preview closed and no enabled consumer, capture is stopped and frame-processing submissions cease. Registered extension presence alone is not an idle failure. |
| AC-TST-01 | P0 | Unit-test independent behavior, including the key, settings and lifecycle rules. | The automated cases in the validation plan pass; CPU reference and GPU output agree within declared tolerances. |
| AC-TST-02 | P0 | Verify activation and real browser output separately from unit tests. | M0 and release evidence include actual extension startup and Teams web preview. Owner acceptance is recorded for the glasses case. |

Performance figures above are proposed acceptance budgets, not measured AppleCam results. M0 must establish measurement feasibility and baseline cost before those budgets are ratified or changed.

## Quality limits and acceptance

Transparent lens areas and reflected green light are different phenomena. A colour key can remove backdrop colours visible through lenses, while spill suppression adjusts residual green tint. Neither implies perfect reconstruction of reflections, tinted lenses, motion blur or naturally green foreground objects.

The first release must provide a visibly useful improvement over the owner's current Apple background result in the designated lens regions, without unacceptable loss of eyes, frames or skin. Record a matched comparison using the same camera, lighting, backdrop and output size. The owner must judge the remaining tradeoff on real glasses. Numeric fixture thresholds and privacy-preserving capture procedures are defined in the validation plan.

## Risks and open decisions

| Risk or decision | Impact | Resolution |
| --- | --- | --- |
| Extension startup and replacement on this Mac | Could prevent any camera output | Prove activation and an upgrade during M0 before calling the transport feasible. |
| Developer ID Application certificate is not currently found locally | Normal notarized installation may need signing setup | Choose the owner's team and create or import appropriate credentials through Apple tooling. Never export a private key into the project. |
| Apple effects on BRIO and a host-app capture path | Limits promised integration | Test the system UI and observable active flags. Treat hardware-specific effects as conditional. |
| Glasses, reflections and green clothing | Keying may remove wanted detail | Tune with real frames and synthetic alpha references. Defer advanced masks until evidence shows they are needed. |
| Browser or tenant restrictions | Camera picker or effects may differ | Make Chrome and the actual Teams web environment the primary verification case. |
| Other webcams, animated images and older OS versions | Increases delivery scope | Keep them outside first-release acceptance unless the owner requests a scope change. |

## Release decision

Release requires all P0 requirements to pass, no unresolved raw-frame disclosure defect, and a usable glasses result accepted by the owner. Conditional Apple features must be accurately described. A compile-only check or local preview is insufficient to claim Teams compatibility.

Implementation must follow the contributor instructions: meaningful unit tests wherever possible, no automatic fallback solutions and no committed secrets. This document introduces no exception to those rules.

Primary evidence and its limits are recorded in [Sources and decisions](SOURCES_AND_DECISIONS.md). The implementation sequence is in the [Development plan](DEVELOPMENT_PLAN.md).

## Owner revision — automatic saving (2026-10-02, build 11)

Automatically retain selected camera, imported background, primary and additional screen samples, calibration sliders, green-screen enablement and local preview mode across quit/relaunch. Keep a private local copy of the imported background. Restore settings without starting capture or publication. Surface saving/loading errors and never silently replace an unavailable source, background or unreadable configuration. This supersedes earlier session-only behavior.
