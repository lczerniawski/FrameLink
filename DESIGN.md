# Frame Link design and architecture

Frame Link connects one camera phone to one nearby viewing phone. The camera phone captures and saves photos; the viewing phone receives a live preview. There is no server, account system, or captured-photo transfer.

See [README.md](README.md) for setup, use, and test commands.

## Project and source map

`FrameLink.xcodeproj` contains the build settings. It uses native Xcode synchronized folders: `FrameLink/` belongs to the app target and `Tests/UI/` belongs to `FrameLinkUITests`. The other `Tests/*.swift` files are standalone checks compiled by `scripts/check.sh`. Keep them outside both targets.

The app requires iOS 26.0 or later. Swift uses language mode 5 with targeted concurrency checking. Keep the existing language mode, deployment target, signing identity, and bundle identifier unless a task explicitly changes them. No project generator or third-party runtime dependency is required.

| Path | Responsibility |
| --- | --- |
| `FrameLink/FrameLinkApp.swift` | App entry point, mode selection, native navigation, shared error alert |
| `FrameLink/AppCoordinator.swift` | Selected role, foreground lifecycle, starting and stopping services |
| `FrameLink/Camera/CameraManager.swift` | Capture session, preview attachment, hardware controls, countdown, capture, Photos saves |
| `FrameLink/Camera/CameraControls.swift` | Flash/timer choices and camera-control math |
| `FrameLink/Camera/CameraLevel.swift` | Foreground motion updates for the horizon guide |
| `FrameLink/Camera/RecentPhotoStore.swift` | Cached previews, exact Photos asset links, deletion, thumbnail updates |
| `FrameLink/Connectivity/PeerConnectionManager.swift` | Discovery, invitations, session lifecycle, receive state |
| `FrameLink/Streaming/VideoCodec.swift` | JPEG encoding/decoding and bounded work |
| `FrameLink/Streaming/Packet.swift` | Wire format and single-frame acknowledgement gate |
| `FrameLink/Views/` | Camera, preview, settings, nearby-device selection, Recent photos |
| `FrameLink/Info.plist` | Privacy descriptions, Bonjour service, supported orientations |
| `FrameLink/FrameLinkIcon.icon` | Icon Composer package and source SVG artwork |
| `Tests/`, `scripts/` | Repeatable checks and Simulator UI tests |

## Capture and streaming pipeline

```text
AVCaptureSession (.photo)
  ├─ AVCaptureVideoPreviewLayer → camera phone's local preview
  ├─ AVCapturePhotoOutput → full-resolution JPEG → local Photos
  │                                            → cached Recent photos preview
  └─ AVCaptureVideoDataOutput → JPEG encoder → Packet → encrypted MCSession
                                                        ↓
                           viewing phone: decoder → displayed image
                                                        ↓
                           matching acknowledgement → sender's frame gate
```

The session preserves still-photo capture quality and requests preview-sized video buffers separately. Local preview is aspect fill; the received image and Recent photos are aspect fit. Front-camera local preview is mirrored. The transmitted feed is unmirrored; the viewing phone's Mirror toggle changes only its display.

### Thread and preview ownership

- Run capture-session changes, device configuration, preview attachment/detachment, rotation, and mirroring on `CameraManager.sessionQueue`. Assigning `AVCaptureVideoPreviewLayer.session` can block while rebuilding the capture graph; keep it off the main thread, including in SwiftUI view creation and updates.
- Preview surfaces can overlap during navigation and rotation. Each surface attaches its own layer and detaches only that layer. Tracking a single "current preview layer" could disconnect a surface that is still visible.
- Attach and detach inside capture-session configuration transactions. Install rotation observations after attachment completes. Use `AVCaptureDevice.RotationCoordinator` and preview-layer coordinate conversion for taps; do not calculate focus points from raw view dimensions.
- Publish UI state on the main actor. Read device properties on the capture queue and publish snapshots for the UI. `CameraManager` uses `@unchecked Sendable` to cross AVFoundation callbacks, so callers must preserve these queue boundaries.
- Encoding runs synchronously on the serial video-output queue. Late capture buffers are discarded. Decoding runs off main on a serial queue and admits one frame at a time. The encoder protects its destination and frame gate with a lock.

### Work limits

| Limit | Current behavior |
| --- | --- |
| Capture/encode rate | Request 24 FPS where the camera format supports it; reserve at most 24 frames per second |
| Sender image size | Long edge at most 1280 px, short edge at most 720 px; preserve aspect ratio and do not upscale |
| JPEG quality | 0.58 normally; 0.38 when smoothed acknowledgement round-trip exceeds 120 ms |
| Frames in flight | One; drop new input until the matching acknowledgement arrives |
| Stalled sender | Reset the connection after an acknowledgement is missing for more than 4 seconds, checked once per second |
| Stale receiver image | Clear after more than 3 seconds without a frame and restore normal sleep behavior |
| Packet payload | At most 900,000 bytes |
| Decoder image bounds | Positive dimensions, each edge at most 1280 px, checked before decompression |

The receiver acknowledges a frame when its decoded image reaches the display model. Screen presentation may happen later. The FPS label counts received image updates. Neither value measures end-to-end latency. Radio loss can stall reliable delivery; keep queues bounded rather than buffering more frames.

### Wire format, version 1

Each reliable `MCSession` data message contains one packet. Multi-byte integers are unsigned, big endian.

| Bytes | Meaning |
| --- | --- |
| 0–3 | Magic `FLNK` (`46 4C 4E 4B`) |
| 4 | Version: `1` |
| 5 | Kind: `1` JPEG, `2` acknowledgement, `3` UTF-8 notice |
| 6–9 | Frame sequence number |
| 10–13 | Payload byte count |
| 14 onward | Payload |

Reject invalid magic, version, kind, length, or size. JPEG payloads must be nonempty; acknowledgements must be empty; notices are limited to 512 bytes. Stale or unrelated acknowledgements must not release the frame gate. Invalid packets, decode failures, and send errors reset the connection with visible feedback. There is no photo-transfer packet.

## Connection and app lifecycle

Camera Mode browses; Preview Mode advertises. Discovery uses service type `framelink` and Bonjour `_framelink._tcp`. Advertisements identify role `preview` and version `1`; invitations carry `FrameLink/1/camera`. Keep these protocol values unchanged when editing app branding.

The camera phone selects a peer and the viewing phone must explicitly accept it. Invitations expire after 25 seconds on the receiver; the browser uses a 30-second invitation timeout and the app guards connection attempts with a 32-second timeout. A busy receiver declines additional requests.

`AppCoordinator` tracks the selected mode and foreground state. Returning to the main menu or entering the background stops services, disconnects, clears the received image, and cancels a pending countdown. Permission dialogs can make the app inactive without backgrounding it; keep the connection during those prompts. Returning to the foreground restarts the selected role, but reconnection still requires selection and approval.

Sessions require encryption. Peer names use `iPhone-` plus four characters from a random UUID, created when the peer manager initializes. They are neither persistent IDs nor verified identities. Do not describe name-based approval as authenticated pairing. iOS chooses the local transport; the app cannot guarantee or report a specific peer-to-peer Wi-Fi route. Local Network denial may produce an empty list without a useful error.

## Camera controls

Use hardware-reported capabilities and ranges. Zoom stops come from the system display multiplier, lens-switch points, and native crop factors; do not invent lenses or force a physical lens from a displayed zoom value. Camera switching resets zoom to the available equivalent of 1×.

A preview tap requests focus and exposure where supported. Continuous autofocus is preferred, with single autofocus as a fallback. `supportsMetering` is true if the device supports focus-point adjustment, exposure-point adjustment, or both. The yellow box marks the tap and fades on a timer. It does not confirm focus or indicate AE/AF lock.

Resolve Photos add permission before a countdown. Disable conflicting controls during capture/save, and cancel pending countdowns on departure, backgrounding, or camera interruption. Once capture begins, let its save complete. Flash choices must match hardware support; unavailable flash reports an error rather than silently changing the setting. There is no simulated front-screen flash.

Request the largest still-photo dimensions exposed by the active camera format. Available resolutions and processing modes may differ from Apple's Camera app. Never reduce still-photo resolution to improve preview throughput. Report failed captures; the app does not retain them for another save attempt.

## Photo storage and deletion

Originals are JPEG assets in the camera phone's Photos library. After a successful save, `RecentPhotoArchive` creates an app-private preview under Application Support:

- At most 20 previews, each with a maximum edge of 2048 px; the camera thumbnail uses 160 px.
- Normalize image orientation and strip location metadata.
- Store the exact opaque Photos asset identifier in the preview JPEG's IPTC caption, prefixed with `Frame Link Photos asset: `. Keep this persisted format compatible with existing previews.
- If no asset identifier is available, report that Photos saved the original but do not create an unlinked gallery entry. Never infer asset identity from dates, filenames, or image similarity.
- Cache pruning must remove only app-owned previews, never Photos originals. External edits or deletions in Photos do not automatically update the cache.

Capture requests add-only Photos access; cached browsing needs no additional library access. Read/write authorization is requested only for deletion. Limited access is sufficient only when it includes the linked asset. Motion access supports the optional level; Local Network access supports discovery. No microphone access is requested.

### Deletion contract

There is one **Delete Photo** action, covering the linked original and its cached preview:

1. Before requesting deletion access, explain that deletion removes the original from Photos and its preview from Frame Link, and may sync through iCloud Photos.
2. Fetch only the exact saved asset identifier. If unavailable, keep the preview. A missing fetch does not prove deletion: limited access and locked hidden assets can also hide it.
3. Ask PhotoKit to delete the original. On denial, cancellation, or error, keep the preview and report the failure.
4. Only after PhotoKit confirms success, remove the cached preview and update selection, count, and thumbnail. Deleting the final entry must show the empty state.

Photos deletion and cache cleanup are separate operations. If Photos succeeds but cache cleanup fails, report both outcomes. The store keeps confirmed deletions in memory so retrying Delete Photo can finish cleanup without another Photos deletion. App termination clears that record. If the original is unavailable after relaunch, keep its preview.

Do not add a silent gallery-only fallback, claim permanent erasure, or hide the iCloud warning. The app has no undo; iOS controls Recently Deleted and library synchronization.

Archive I/O and preview decoding stay off main. Decode one selected gallery image at a time; cancelled or obsolete loads must not replace the current selection. Keep capture/save work bounded and preserve visible errors when the original saves but preview storage fails. Browsing or deleting should not intentionally stop live streaming; actual backgrounding still disconnects.

## Interface rules

Keep the camera image visible and the connection state readable. Use black working surfaces, system type with Dynamic Type, SF Symbols, native navigation, sheets, lists, and alerts. Primary text and shutter are white, actions use system yellow, and connected indicators use system green. Pair status colors with text. Give icon-only controls VoiceOver labels and standard iOS tap-target sizes.

| Surface | Layout and behavior to preserve |
| --- | --- |
| Mode selection | Two explicit modes, short connection instructions, native back button and edge-swipe navigation. No app-wide horizontal drag gesture. |
| Camera | Connection status and flash/timer above the preview; zoom stops at its bottom left. Recent photos, shutter, and camera switch form a three-control row below in portrait or a column beside it in landscape. Nearby devices and settings stay in the toolbar. |
| Camera settings | Exposure compensation, Grid, and Level. Keep flash, timer, and zoom directly accessible rather than moving them into settings. |
| Preview Mode | Aspect-fit image, black letterboxing, connection state, Mirror, received FPS, and Disconnect. Clear stale images; never substitute a synthetic camera feed. |
| Recent photos | Newest-first, aspect-fit pager with date/count, newer/older buttons, one trash action, and Done. Keep loading, error, and empty states visible. |

Allow top controls to wrap and zoom stops to scroll for large text. Compact landscape content may scroll instead of clipping the shutter column. Keep controls inside safe areas. VoiceOver supports center-point metering, adjustable preview zoom, exposure values, countdown announcements, and native navigation escape.

Grid, focus target, and level are local overlays only. The level is a thin three-part horizon guide, yellow when aligned, with no badge or on-scene instruction text. Hide it when the phone is nearly flat or motion data is unavailable. Stop motion updates when the level view is inactive. Show a saved-photo confirmation only after Photos succeeds.

Name the action, failure, or next step in user-facing text. Use `Frame Link` as the display name and `FrameLink` as the project/module name. Keep destructive-action warnings, permission explanations, and unsupported-hardware states when shortening text.

### App icon

`FrameLink/FrameLinkIcon.icon` is the sole icon source, selected as `FrameLinkIcon` in both build configurations. Edit it with Icon Composer.

Preserve the three SVG layers (`CameraFrame.svg`, `LensRing.svg`, `Indicator.svg`), native `system-light`/`system-dark` backgrounds, and contrasting outline variants. Icon Composer supplies glass, lighting, specular effects, translucency, and shadows. Do not replace the package with flattened PNGs or add runtime glass code for the icon. Home Screen appearance is controlled by iOS independently of the app's dark interface.

## Tests and release checks

Run the commands in [README.md](README.md#tests). Add regression coverage to the existing suite when changing behavior:

| Test | Scope |
| --- | --- |
| `Tests/ProtocolChecks.swift` | Packet parsing, malformed input, pacing, stale acknowledgements, stall/reset behavior |
| `Tests/RecentPhotoChecks.swift` | Real JPEG archive operations, retention, exact asset links, deletion ordering with a fake Photos operation, cleanup failures |
| `Tests/CameraControlChecks.swift` | Timer/flash cycling, zoom math, finite/range checks, level calculations |
| `Tests/NavigationChecks.swift` | Real coordinator lifecycle with camera/network service doubles |
| `Tests/PreviewConnectionChecks.swift` | Production preview-queue methods with native empty AVFoundation sessions/layers on macOS |
| `Tests/UI/FrameLinkUITests.swift` | Native navigation and largest-text camera layout against the Simulator app |
| `scripts/check.sh` | Runs standalone checks and validates privacy, icon, source wiring, and test-target configuration |

UI tests run through the shared `FrameLink` scheme. `scripts/check-ui.sh` disables parallel testing so orientation changes stay on one simulator. Commit test sources and scripts. Keep generated apps, test results, screenshots, and local experiments under ignored `build/`. Builds and tests must work without existing files there.

Physical autofocus, real Photos deletion, router-free discovery, sustained streaming, and complete VoiceOver behavior need device testing. The developer has confirmed basic two-iPhone operation. Record device-test results separately from automated checks and performance measurements.

### Device release checklist

Use disposable photos for deletion tests. Record device models, iOS versions, build, network conditions, and results. Before releasing changes to the relevant flows:

- **Offline discovery:** unplug USB, disable cellular/hotspot and saved-network auto-join, leave Wi-Fi and Bluetooth on, and connect without a router. Test accept, decline, timeout, and a busy receiver.
- **Camera and orientation:** switch front/rear repeatedly; rotate each phone independently through portrait and both landscapes. Check live images, framing, mirroring, near/far tap focus, exposure, zoom, and supported flash choices.
- **Capture and countdown:** save photos while streaming; inspect dimensions/orientation in Photos. Test both timer values, cancellation, interruption, Photos denial, and low storage. Verify no stuck shutter or delayed capture after cancellation.
- **Recent photos:** capture 21 photos, check retention of 20 previews without deleting originals, relaunch, page rapidly, delete first/middle/last/final entries, and confirm selection/thumbnail updates while streaming continues.
- **Deletion safety:** test app/system cancellation, denied/limited access, hidden or externally deleted originals, unrelated assets, and cache failure after confirmed Photos deletion. Retry cleanup in the same launch and check safe behavior after relaunch. Use disposable assets if testing iCloud synchronization.
- **Recovery:** repeat disconnect/reconnect, background/foreground, lock/unlock, camera interruption, app termination, and radio loss on either phone. Verify stale images clear, pending countdowns cancel, and reconnection works without restarting both apps.
- **Accessibility:** use large text, VoiceOver, native back/edge-swipe/escape, and gallery gestures in portrait and landscape. Check that controls remain reachable and a cancelled back swipe does not stop services.
- **Sustained use:** stream for 15–30 minutes with captures and increasing distance. Record received FPS, memory, temperature, and battery behavior. For end-to-end latency, film a source timer and the received image together; do not substitute acknowledgement round-trip for that measurement.

For a change limited to one area, run its automated checks and the relevant device cases. Record which checks ran and which device cases remain untested.
