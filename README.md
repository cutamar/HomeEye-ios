<div align="center">

# HomeEye

**A clean, local-only iPhone app for your IP cameras.**
Live video, pan/tilt and saved positions, with no cloud, no account and no trackers.

[![License: MIT](https://img.shields.io/badge/license-MIT-14b8a6.svg)](LICENSE)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000.svg)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138.svg)
![ONVIF](https://img.shields.io/badge/protocol-ONVIF%20%2B%20RTSP-0e1116.svg)

</div>

---

## Why

Most camera apps send your video through the manufacturer's cloud, need an account and come packed with tracking. Most open-source viewers work, but they're clunky.

HomeEye talks **directly to your camera on your own Wi-Fi** using the open ONVIF and RTSP standards. You can even block your camera's internet access completely and everything keeps working.

## Features

| | |
|---|---|
| 🔍 **Find cameras automatically** | Scans your Wi-Fi subnet directly for ONVIF cameras. If your network is larger than a /24, enter the camera's IP instead |
| ✅ **Test before you save** | Shows model, firmware, stream resolutions and pan/tilt support, with clear errors like *"Wrong username or password"* |
| 📺 **Low-latency live view** | Small buffers for a near-live picture, automatic reconnect when Wi-Fi blips |
| 🕹️ **Joystick pan/tilt** | Drag to move, let go to stop. Reverse axes for ceiling mounts |
| 📍 **Saved positions** | Jump to, save and remove camera presets |
| 🔎 **Pinch to zoom** | Digital zoom and pan, double-tap to reset |
| 🖥️ **Fullscreen** | Landscape view with controls that fade away |
| 🎚️ **SD / HD switch** | Use the lighter stream on weak Wi-Fi |
| 🔊 **Sound** | Muted by default. Plays G.711 (PCMA/PCMU) camera audio; the mute button is hidden for other audio codecs |
| 📸 **Snapshots** | Saved to Photos |

## Privacy

- **Only talks to your cameras.** HomeEye makes no other network connections: no analytics, no crash reporting, no update checks.
- **Encrypted logins.** Camera passwords are stored in the iOS Keychain, set to "this device only", so they can't be read out of the device.
- **Never backed up.** App data is excluded from backup. Keychain items marked this-device-only are never synced to iCloud and can't be restored onto another device.
- **Local network permission.** iOS asks for "Local Network" access the first time HomeEye looks for or connects to a camera. This is how iOS protects your home network, and HomeEye only uses it to reach the cameras you add.
- **No third-party code at all.** No SDKs, no packages, no dependencies. The RTSP and ONVIF clients are written in Swift, on top of Apple's own frameworks.

## Compatible cameras

Any camera with **ONVIF Profile S** (live streaming) should work. Pan/tilt needs ONVIF PTZ support. Video must be H.264 or H.265; HomeEye streams RTSP over TCP.

| Camera | Status |
|---|---|
| TP-Link Tapo C200 | ✅ Tested on Android: stream, pan/tilt, presets, discovery (iOS testing pending) |
| Other Tapo, Reolink, Hikvision, Dahua, Amcrest, … | Should work. Please [report](../../issues) how it goes |

### Tapo setup

1. In the Tapo app, open the camera → **Settings → Advanced Settings → Camera Account**.
2. Create a username and password. This is the camera's own login, not your TP-Link account.
3. In HomeEye, tap **Find Cameras on Wi-Fi** (or enter the IP), then use that login. Tapo's ONVIF port is `2020`.

**Keep the camera offline:** block its internet access in your router. HomeEye keeps working; only the Tapo cloud features stop.

## Install

HomeEye isn't on the App Store. You sideload it with [Sideloadly](https://sideloadly.io) from Windows (macOS works too).

1. Download `HomeEye.ipa` from [**Releases**](../../releases), or from the latest green Actions run under **Artifacts** (this needs a GitHub login; unzip the download).
2. Install **iTunes** or **Apple Devices** from Apple (not the Microsoft Store version, per Sideloadly's guidance), and install Sideloadly.
3. Connect your iPhone and tap **Trust** on the phone when asked to trust the computer.
4. Drag the IPA into Sideloadly, enter your Apple ID and click **Start**.
5. On the iPhone, go to **Settings → General → VPN & Device Management** and trust your Apple ID. Then enable **Settings → Privacy & Security → Developer Mode** (iOS 16+) and restart the phone.
6. Free Apple IDs expire the app after **7 days**. Re-sideload, or use Sideloadly's auto-refresh. A free Apple ID is limited to 3 sideloaded apps.
7. Allow **Local Network** when HomeEye first asks.

Requires iOS 17 or newer, iPhone only.

## Build from source

CI builds the IPA on every push to main, so you usually don't need to. To build it yourself you need a Mac with Xcode:

```sh
git clone https://github.com/cutamar/HomeEye-ios.git
cd HomeEye-ios
brew install xcodegen && xcodegen generate && open HomeEye.xcodeproj
```

The Xcode project is generated from `project.yml` and isn't checked in. To run on a phone from Xcode, select a team under Signing & Capabilities first.

### Project layout

```
HomeEyeCore/   Pure Swift package: ONVIF client, RTSP/RTP, discovery. No UI or
               Apple-only dependencies, so it's tested on Linux, including
               against a real camera.
HomeEye/       The iOS app: SwiftUI UI, VideoToolbox decoding and audio playback.
```

### Tests

```sh
docker run --rm -v "$PWD":/w -v homeeye-build:/build -w /w/HomeEyeCore swift:6.0 swift test --scratch-path /build
```

To also run the tests against your own camera:

```sh
# Host networking works with Docker on Linux (not Docker Desktop).
# Non-Tapo cameras: add -e HOMEEYE_CAM_PORT=80
docker run --rm --network host -v "$PWD":/w -v homeeye-build:/build -w /w/HomeEyeCore \
  -e HOMEEYE_CAM_HOST=<camera-ip> -e HOMEEYE_CAM_USER=<user> -e HOMEEYE_CAM_PASS=<password> \
  swift:6.0 swift test --scratch-path /build
# Add -e HOMEEYE_CAM_MOVE=1 to also nudge the camera right and back.
```

## Roadmap

- [ ] Multi-camera grid view
- [ ] Two-way talk
- [ ] Motion alerts (ONVIF events)
- [ ] Recording to phone storage

Ideas and pull requests welcome.

## License

[MIT](LICENSE)
