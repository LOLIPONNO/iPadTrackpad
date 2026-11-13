# iPadTrackpad

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![iPadOS 17+](https://img.shields.io/badge/iPadOS-17.0%2B-blue.svg)](https://developer.apple.com/ipados/)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-black.svg)](https://developer.apple.com/macos/)

Turn your iPad into an ultra-low-latency multi-touch trackpad for macOS over **Wi-Fi (Bonjour)** or **USB**, built natively with Swift 6, SwiftUI, `Network.framework`, and CoreGraphics (`CGEvent`).

---

## Features

- **Low-Latency Binary Touch Pipeline**
  - Custom fixed-width binary framing (`0x5450` `"TP"` magic: 8-byte header + 14-byte frame subheader + 16-byte `TouchPoint`) with zero `JSON`/`Codable` overhead.
  - Dual-transport architecture: reliable `TCP` (`TCP_NODELAY`) for handshakes, heartbeats, and system gestures; low-latency `UDP` for continuous touch streams.
  - 120Hz ProMotion `CADisplayLink` frame synchronization with `coalescedTouches` and static-touch delta compression (`DeltaCompressor`).
  - Sequence-number (`frameIndex`) tracking to drop stale or out-of-order UDP frames.
- **Selectable Wi-Fi & USB Wired Modes**
  - **iPad (`TrackpadClient`)**: Switch between **Auto (USB Preferred)**, **Wi-Fi**, and **USB Wired** directly from the floating HUD or settings sheet.
  - **Mac (`TrackpadServer`)**: Filter incoming connections by **All Interfaces**, **USB Only**, or **Wi-Fi Only** from the menu bar extra.
- **Native-Style Multi-Touch Gestures**
  - **1-Finger**: Accelerated cursor tracking, tap-to-click (single/double/triple click state).
  - **2-Finger**: Smooth 120Hz inertial scrolling (horizontal & vertical), pinch-to-zoom, two-finger tap for secondary click.
  - **3-Finger**: Mission Control, App Exposé, and Space switching — or **3-finger drag** when toggled on in the menu bar.
  - **4-Finger**: Fallback system swipe gestures when 3-finger drag is enabled.
- **OLED-Friendly Canvas & Live Telemetry**
  - Pure `#000000` full-screen touch surface with auto-hiding HUD and optional haptic feedback.
  - Real-time diagnostics on both devices: RTT / one-way latency, display FPS (`Hz`), packet rate (`PPS`), delta compression savings, dropped packets, and throughput.

---

## Architecture

```text
┌──────────────────────────────┐        Bonjour (_virtualtrackpad._tcp)        ┌──────────────────────────────┐
│        TrackpadClient        │ ─────── TCP (Control / Gestures) ────────────▶ │        TrackpadServer        │
│          (iPadOS 17+)        │ ─────── UDP (120Hz Touch Stream) ────────────▶ │     (macOS 14+ Menu Bar)     │
│                              │ ◀────── TCP/UDP (Ping / Haptic Cues) ───────── │                              │
└──────────────────────────────┘                                                └──────────────────────────────┘
               │                                                                               │
               ▼                                                                               ▼
   UIView + CADisplayLink                                                        DeltaReconstructor + CGEvent
   (Coalesced Multitouch)                                                        (Cursor / Scroll / Shortcuts)
```

### Targets & Packages

| Component | Platform | Description |
| --- | --- | --- |
| `SharedKit` | iOS 17+ / macOS 14+ | Shared Swift 6 package containing `PacketProtocol`, `DeltaCompressor`, `GestureEngine`, and `NetworkTransport`. |
| `TrackpadClient` | iPadOS 17+ | Full-screen SwiftUI/UIKit multitouch capture app (`com.ipadtrackpad.client`). |
| `TrackpadServer` | macOS 14+ | `LSUIElement` menu bar daemon (`com.ipadtrackpad.server`) injecting `CGEvent` cursor, scroll, and shortcut events. |

---

## Supported Gestures

| Gesture | Action | Notes |
| --- | --- | --- |
| 1-finger move | Move cursor | macOS-style acceleration curve |
| 1-finger tap | Left click | Supports single, double, and triple click |
| 2-finger drag | Scroll | 120Hz momentum inertia & Natural Scrolling toggle |
| 2-finger pinch | Zoom | Pinch in / out |
| 2-finger tap | Right click | Secondary click |
| 3-finger swipe up / down | Mission Control / App Exposé | Sent over reliable TCP; toggleable to 3-finger drag |
| 3-finger swipe left / right | Switch Spaces | Follows macOS natural trackpad swipe direction |
| 4-finger swipe | System gestures fallback | Active when 3-finger drag mode is enabled |

---

## Requirements

- **macOS** 14.0+ (for `TrackpadServer`)
- **iPadOS** 17.0+ (for `TrackpadClient`, iPad-only target)
- **Xcode** with Swift 6.0 toolchain (`SWIFT_STRICT_CONCURRENCY = complete`)

---

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/LOLIPONNO/iPadTrackpad.git
cd iPadTrackpad
```

### 2. Configure Code Signing

Update `DEVELOPMENT_TEAM` in [`project.yml`](project.yml) (or set your Apple Development Team in Xcode's **Signing & Capabilities** tab for both `TrackpadClient` and `TrackpadServer`).

If you modify `project.yml`, regenerate the Xcode project using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

### 3. Run Unit Tests (`SharedKit`)

```bash
cd SharedKit
swift test
```

### 4. Build & Run

Open `iPadTrackpad.xcworkspace` in Xcode to run `TrackpadServer` on your Mac and `TrackpadClient` on your iPad, or build from the command line:

```bash
# Build macOS Menu Bar server
xcodebuild -workspace iPadTrackpad.xcworkspace -scheme TrackpadServer -destination 'platform=macOS' -allowProvisioningUpdates build

# Build iPadOS client for a connected iPad (replace <IPAD_UDID>)
xcodebuild -workspace iPadTrackpad.xcworkspace -scheme TrackpadClient -destination 'id=<IPAD_UDID>' -allowProvisioningUpdates build
```

---

## Permissions

1. **macOS Accessibility (`TrackpadServer`)**
   - `TrackpadServer` posts synthetic mouse, scroll, and keyboard events via `CGEvent`.
   - Grant access in **System Settings → Privacy & Security → Accessibility** on first launch. *(If re-signing during development invalidates trust, remove and re-add `TrackpadServer` in the Accessibility list.)*
2. **Local Network (`TrackpadClient` & `TrackpadServer`)**
   - Allow local network access when prompted so Bonjour (`_virtualtrackpad._tcp`) can discover peers over Wi-Fi and USB interfaces.

---

## Project Structure

```text
iPadTrackpad/
├── project.yml
├── iPadTrackpad.xcworkspace
├── iPadTrackpad.xcodeproj
├── SharedKit/
│   ├── Package.swift
│   ├── Sources/SharedKit/
│   │   ├── PacketProtocol.swift
│   │   ├── DeltaCompressor.swift
│   │   ├── GestureEngine.swift
│   │   └── NetworkTransport.swift
│   └── Tests/SharedKitTests/
│       └── SharedKitTests.swift
├── TrackpadClient/
│   ├── Info.plist
│   └── Sources/
│       ├── TrackpadClientApp.swift
│       ├── ContentView.swift
│       ├── ClientSessionManager.swift
│       └── TrackpadTouchView.swift
└── TrackpadServer/
    ├── Info.plist
    ├── TrackpadServer.entitlements
    └── Sources/
        ├── TrackpadServerApp.swift
        ├── MenuBarView.swift
        ├── ServerManager.swift
        ├── AccessibilityHelper.swift
        └── SyntheticEventDriver.swift
```
