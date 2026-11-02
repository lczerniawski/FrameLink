# Frame Link

Frame Link turns a second iPhone into a live viewfinder for the first. Take photos on the camera phone while checking the composition on the other.

Both phones run the same app and connect through Apple's MultipeerConnectivity framework. No internet connection, router, hotspot, or account is needed. The app has no backend, analytics service, or third-party dependency.

## Requirements

- Two iPhones running **iOS 26.0 or later**.
- Wi-Fi and Bluetooth enabled in **Settings** on both phones.
- Frame Link open in the foreground on both phones.
- To build and install: a Mac with **Xcode 26 or later** and an Apple development signing team. You can use a free Personal Team within Apple's signing limits.

Simulator is useful for UI tests, but cannot verify the camera or a two-iPhone connection.

## Build and install

Run commands from the repository root, which contains `FrameLink.xcodeproj`.

```sh
open FrameLink.xcodeproj
```

1. Select the `FrameLink` app target and open **Signing & Capabilities**.
2. Enable automatic signing, choose your team, and set your own bundle identifier, such as `com.yourname.framelink`. The existing signing defaults belong to the original developer.
3. Connect and trust an iPhone. Enable Developer Mode if iOS requests it.
4. Select the `FrameLink` scheme and the iPhone, then Run. Repeat for the second phone, using the same app version and bundle identifier.

Open the project directly in Xcode; there are no dependencies to install or project files to generate. Installation and signing may require internet access. Free development signatures expire and may need renewing.

To keep existing recent-photo previews, update the app in place with the same bundle identifier. Uninstalling removes those previews, but does not delete originals saved to Photos.

### Command-line build

This compiles an unsigned device app; it does not produce an installable signed app:

```sh
xcodebuild -project FrameLink.xcodeproj -scheme FrameLink \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Use `-configuration Release` for an optimized build. For a signed archive, configure your team and bundle identifier, then use **Product → Archive** in Xcode. App Store distribution and third-party sideloading have not been validated.

## Connect the phones

1. Turn on Wi-Fi and Bluetooth in Settings on both phones. They do not need to join a Wi-Fi network.
2. On the viewing phone, choose **Preview Mode** and allow Local Network access. Note the name shown, such as `iPhone-A1B2`.
3. On the camera phone, choose **Camera Mode** and allow Camera and Local Network access.
4. Tap the nearby-device icon at the top right, then choose the viewing phone.
5. On the viewing phone, accept the request from the camera phone you recognize.
6. Take photos with the shutter on the camera phone. Allow Photos access when asked. Full-resolution JPEGs are saved to Photos on that phone; Frame Link does not transfer captured photos to the viewing phone.

**Mirror** changes only the viewing phone's display. **Disconnect**, returning to the main menu, or backgrounding either app ends the connection. To reconnect, select the viewing phone again in Camera Mode and accept a fresh request.

Peer names are random labels created each app launch, not hardware IDs or verified identities. Connections require encryption, but names can be impersonated. Only connect to devices you recognize; there is no authenticated pairing code.

## Camera controls

| Control | How it works |
| --- | --- |
| Zoom | Pinch the preview or use the buttons at its bottom left. Available stops depend on the camera; iOS chooses the physical lens. |
| Focus and exposure | Tap the preview to request focus and exposure at that point, where supported. The yellow box marks the tap; it does not confirm focus or lock it. |
| Flash | Tap the flash control above the preview to cycle supported settings. Cameras without flash show a disabled control. |
| Timer | Tap the timer control for Off, 3 seconds, or 10 seconds. Tap the shutter again during the countdown to cancel. |
| Camera settings | Adjust exposure compensation or enable Grid and Level. These guides appear only on the camera phone, not in saved photos or the shared preview. |
| Camera switch | Switch between front and rear cameras using the button beside the shutter. |

Use the camera phone for all controls, including the shutter. Leaving Camera Mode or backgrounding cancels a pending countdown; captures already in progress continue.

## Recent photos and deletion

The thumbnail beside the shutter opens **Recent photos**, with up to 20 photos taken by this app on that iPhone. Swipe or use the arrows to browse.

Frame Link keeps smaller previews for this screen; full-resolution originals remain in Photos. The previews stay after you close and reopen the app. When the list reaches 20, adding another photo removes only the oldest cached preview, not its original. Edits or deletions made separately in Photos do not update the cached previews.

**Delete Photo deletes the linked original from Photos and removes its preview from Frame Link.** If iCloud Photos is enabled, deletion can also sync to other devices using that library. The app asks for confirmation and Photos access; iOS may show another confirmation. There is no separate preview-only delete action or in-app undo.

If access is denied, deletion is cancelled, or the original is unavailable, the preview stays. If Photos deletion succeeds but local cleanup fails, retry **Delete Photo** before closing the app. Frame Link keeps this deletion record in memory. If the app terminates before cleanup succeeds, the preview may remain after relaunch. See [photo-storage details](DESIGN.md#photo-storage-and-deletion).

## Troubleshooting

- **No nearby phone:** keep both apps open, check the selected modes, and enable Wi-Fi and Bluetooth in Settings. Check Frame Link's Local Network access on both phones, then use **Search again** or **Try again**. Denied access can look like an empty device list rather than an error.
- **Black or paused preview:** confirm the camera phone is still in Camera Mode and in the foreground. Try **Retry camera** if offered, then reconnect if needed.
- **Photo not saved:** check free storage and Frame Link's Photos access. Failed saves are reported, but the app does not retain the image for another save attempt.
- **Cannot delete a photo:** check Photos access and whether the original is hidden or outside your allowed selection. Frame Link keeps the preview when it cannot safely access the linked original.

## Tests

Hardware-independent checks run on macOS with Xcode installed:

```sh
./scripts/check.sh
```

These cover packet validation, frame pacing, photo-preview storage and deletion ordering, camera-control math, navigation lifecycle, and project configuration. Photo deletion tests use a fake Photos operation; they do not delete real library assets.

For Simulator UI tests, choose an installed iPhone simulator and replace `SIMULATOR_UDID` with its identifier:

```sh
xcrun simctl list devices available
./scripts/check-ui.sh SIMULATOR_UDID
```

You can also select an iPhone simulator in Xcode and press **⌘U**. The `FrameLinkUITests` target checks native back navigation, cancelled edge swipes, mode re-entry, and the camera layout at the largest Accessibility Text size. It uses the camera-unavailable state on Simulator.

Test results and screenshot attachments are under `build/UITests/Logs/Test/`. Git ignores generated files in `build/`. The tests run from a clean checkout.

## Status and limits

The developer has confirmed basic operation on two physical iPhones. Automated checks, Simulator UI tests, and unsigned iPhone Debug/Release builds have passed. Full hardware testing and App Store submission checks are still outstanding.

- One camera/viewing-phone pair per session; both apps must stay in the foreground. Reconnection requires selection and approval.
- Preview performance depends on the devices, radio conditions, and temperature. Capture may briefly pause the stream. Latency, sustained frame rate, battery use, and thermal behavior have not been measured.
- The app requests the largest JPEG dimensions exposed by the active camera format. Available resolutions and processing modes may differ from Apple's Camera app.
- No audio, video recording, captured-photo transfer, RAW/ProRAW, or manual focus lock.
- Photo deletion follows iOS Photos behavior, including iCloud synchronization and Recently Deleted. Frame Link does not promise permanent erasure.

## Contributing

See [DESIGN.md](DESIGN.md) for the source map, architecture, UI rules, and safety constraints. Human contributors and coding agents should run the relevant checks in the [device release checklist](DESIGN.md#device-release-checklist) before releasing changes.
