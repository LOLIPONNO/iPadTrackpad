import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SharedKit

/// Translates high-level `GestureAction`s and `SystemGestureAction`s into native macOS HID events via CoreGraphics (`CGEvent`).
///
/// ## Low-Level macOS HID Injection Architecture
/// 1. **Immediate Synchronous `.userInteractive` Execution**:
///    Incoming motion deltas execute directly on the transport's `.userInteractive` queue (protected by a
///    low-contention `NSLock`) rather than paying an extra cross-queue `async` hop. Only the 120Hz scroll
///    inertia decay timer and keyboard `keyUp` release run asynchronously.
///
/// 2. **Drift-Free Sub-Pixel Cursor Tracking & Display Caching**:
///    `virtualCursor` maintains an authoritative floating-point cursor accumulator during active tracking
///    and only re-syncs from `CGEvent(source: nil)?.location` after an idle gap (`> 250ms`), preventing
///    WindowServer query lag from snapping the cursor backward mid-swipe. Active display bounds are cached
///    for 2 seconds rather than calling `CGGetActiveDisplayList` on every delta frame.
///
/// 3. **Continuous Pixel Scrolling & 120Hz Inertia**:
///    Two-finger scroll events use `CGEvent(scrollWheelEvent2Source:units:.pixel:...)` with
///    `scrollWheelEventIsContinuous = 1`, `scrollWheelEventScrollPhase`, and `scrollWheelEventMomentumPhase`.
///
/// 4. **System Hotkeys & NSWorkspace Fallback**:
///    3-finger and 4-finger system swipes (`missionControl`, `appExpose`, `spaceLeft`, `spaceRight`) resolve
///    `com.apple.symbolichotkeys` (or default `Control + Arrow`: `0x7E`, `0x7D`, `0x7B`, `0x7C`), post
///    paired `keyDown` and delayed `keyUp` `CGEvent`s to `.cghidEventTap`, and fall back to launching
///    `/System/Applications/Mission Control.app` via `NSWorkspace` when hotkeys are disabled or fail.
final class SyntheticEventDriver: @unchecked Sendable {
    struct Configuration: Sendable {
        var sensitivity: Double = 1.65
        var scrollSpeed: Double = 1.25
        var accelerationExponent: Double = 0.72
        var inertiaDecayPerFrame: Double = 0.942
    }

    private let lock = NSLock()
    private let inertiaQueue = DispatchQueue(label: "com.ipadtrackpad.server.inertia", qos: .userInteractive)
    private let eventSource: CGEventSource?
    /// Isolated private event source for keyboard shortcuts so modifier flags never stick in `.hidSystemState`.
    private let shortcutEventSource: CGEventSource?

    private var config = Configuration()
    private var virtualCursor: CGPoint = .zero
    private var hasSyncedCursor = false
    private var lastMouseEventNs: UInt64 = 0

    // Cached active display rectangles (refreshed every 2 seconds to avoid CoreGraphics IPC per delta)
    private var cachedDisplayBounds: [CGRect] = []
    private var lastDisplayRefreshNs: UInt64 = 0

    // Click-state tracking (single / double / triple click)
    private var lastClickTimestampNs: UInt64 = 0
    private var lastClickLocation: CGPoint = .zero
    private var currentClickState: Int64 = 1

    // 3-finger drag state
    private var isDragging = false

    // 2-finger pinch accumulator
    private var pinchAccumulator: Float32 = 0

    // 120Hz scroll inertia state
    private var inertiaTimer: DispatchSourceTimer?
    private var momentumVelX: Double = 0
    private var momentumVelY: Double = 0
    private var momentumPhaseStarted = false

    init() {
        self.eventSource = CGEventSource(stateID: .hidSystemState)
        self.shortcutEventSource = CGEventSource(stateID: .privateState)
        // Clear any leftover stuck Control modifier in global HID state on startup.
        if CGEventSource.flagsState(.hidSystemState).contains(.maskControl),
           let clearEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x3B, keyDown: false) {
            clearEvent.flags = []
            clearEvent.post(tap: .cghidEventTap)
        }
    }

    deinit {
        lock.lock()
        inertiaTimer?.cancel()
        inertiaTimer = nil
        lock.unlock()
    }

    func updateConfiguration(_ block: @escaping @Sendable (inout Configuration) -> Void) {
        lock.lock()
        block(&config)
        lock.unlock()
    }

    func apply(_ actions: [GestureAction]) {
        guard !actions.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for action in actions {
            executeLocked(action)
        }
    }

    func executeSystemGesture(_ action: SystemGestureAction) {
        lock.lock()
        cancelInertiaLocked()
        lock.unlock()

        switch action {
        case .missionControl:
            triggerSystemHotkey(hotkeyID: "32", defaultKeyCode: 0x7E, fallbackApp: .missionControl)
        case .appExpose:
            triggerSystemHotkey(hotkeyID: "33", defaultKeyCode: 0x7D, fallbackApp: .appExpose)
        case .spaceLeft:
            triggerSystemHotkey(hotkeyID: "79", defaultKeyCode: 0x7B, fallbackApp: nil)
        case .spaceRight:
            triggerSystemHotkey(hotkeyID: "81", defaultKeyCode: 0x7C, fallbackApp: nil)
        }
    }

    // MARK: - Action Execution (Lock Held)

    private func executeLocked(_ action: GestureAction) {
        switch action {
        case .moveCursor(let dx, let dy):
            cancelInertiaLocked()
            moveCursorLocked(dx: dx, dy: dy, dragging: isDragging)

        case .leftClick:
            cancelInertiaLocked()
            performClickLocked(button: .left)

        case .rightClick:
            cancelInertiaLocked()
            performClickLocked(button: .right)

        case .scrollBegan:
            cancelInertiaLocked()
            postScrollEvent(dx: 0, dy: 0, scrollPhase: 1, momentumPhase: 0)

        case .scrollChanged(let dx, let dy, _, _):
            let scale = 1200.0 * config.scrollSpeed
            let pxX = Double(dx) * scale
            let pxY = Double(dy) * scale
            postScrollEvent(dx: pxX, dy: pxY, scrollPhase: 2, momentumPhase: 0)

        case .scrollEnded(let velocityX, let velocityY):
            postScrollEvent(dx: 0, dy: 0, scrollPhase: 4, momentumPhase: 0)
            startInertiaLocked(velocityX: Double(velocityX), velocityY: Double(velocityY))

        case .pinchZoom(let deltaScale):
            handlePinchZoomLocked(deltaScale: deltaScale)

        case .threeFingerDragBegan:
            cancelInertiaLocked()
            beginThreeFingerDragLocked()

        case .threeFingerDragMoved(let dx, let dy):
            moveCursorLocked(dx: dx, dy: dy, dragging: true)

        case .threeFingerDragEnded:
            endThreeFingerDragLocked()

        case .fourFingerSwipe(let direction):
            cancelInertiaLocked()
            let mapped: SystemGestureAction = switch direction {
            case .up: .missionControl
            case .down: .appExpose
            case .left: .spaceRight
            case .right: .spaceLeft
            }
            lock.unlock()
            executeSystemGesture(mapped)
            lock.lock()
        }
    }

    // MARK: - Cursor Movement & Acceleration

    private func syncCursorAfterIdleIfNeededLocked(nowNs: UInt64) {
        // Only query WindowServer cursor on first move or after >250ms idle (external physical mouse/trackpad move).
        let idleThresholdNs: UInt64 = 250_000_000
        if !hasSyncedCursor || (nowNs &- lastMouseEventNs) > idleThresholdNs {
            if let liveLocation = CGEvent(source: nil)?.location {
                virtualCursor = liveLocation
                hasSyncedCursor = true
            }
        }
        lastMouseEventNs = nowNs
    }

    private func moveCursorLocked(dx: Float32, dy: Float32, dragging: Bool) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        syncCursorAfterIdleIfNeededLocked(nowNs: nowNs)

        // Scale normalized [0, 1] trackpad coordinates into base display points.
        let baseScale = 1150.0 * config.sensitivity
        let rawDx = Double(dx) * baseScale
        let rawDy = Double(dy) * baseScale

        // Non-linear macOS-style acceleration curve based on instantaneous step magnitude.
        let stepMag = hypot(rawDx, rawDy)
        let accelGain = 0.55 + 1.55 * pow(min(stepMag / 14.0, 2.8), config.accelerationExponent)

        let scaledDx = rawDx * accelGain
        let scaledDy = rawDy * accelGain

        let clamped = clampToDisplayBoundsLocked(
            CGPoint(x: virtualCursor.x + scaledDx, y: virtualCursor.y + scaledDy),
            nowNs: nowNs
        )
        virtualCursor = clamped

        let eventType: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: clamped,
            mouseButton: .left
        ) else { return }

        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(scaledDx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(scaledDy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    private func clampToDisplayBoundsLocked(_ point: CGPoint, nowNs: UInt64) -> CGPoint {
        if cachedDisplayBounds.isEmpty || (nowNs &- lastDisplayRefreshNs) > 2_000_000_000 {
            lastDisplayRefreshNs = nowNs
            var displayCount: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &displayCount)
            if displayCount > 0 {
                var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
                CGGetActiveDisplayList(displayCount, &displays, &displayCount)
                cachedDisplayBounds = displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
            }
        }

        guard !cachedDisplayBounds.isEmpty else { return point }

        for bounds in cachedDisplayBounds where bounds.contains(point) {
            return point
        }

        var bestPoint = point
        var bestDist = Double.greatestFiniteMagnitude
        for b in cachedDisplayBounds {
            let cx = min(max(point.x, b.minX), b.maxX - 1)
            let cy = min(max(point.y, b.minY), b.maxY - 1)
            let dist = hypot(point.x - cx, point.y - cy)
            if dist < bestDist {
                bestDist = dist
                bestPoint = CGPoint(x: cx, y: cy)
            }
        }
        return bestPoint
    }

    // MARK: - Clicks & 3-Finger Drag

    private func performClickLocked(button: CGMouseButton) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        syncCursorAfterIdleIfNeededLocked(nowNs: nowNs)
        let pos = virtualCursor

        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

        if button == .left {
            let withinDoubleClickWindow = (nowNs &- lastClickTimestampNs) <= 450_000_000
                && hypot(pos.x - lastClickLocation.x, pos.y - lastClickLocation.y) <= 8.0
            currentClickState = withinDoubleClickWindow ? min(currentClickState + 1, 3) : 1
            lastClickTimestampNs = nowNs
            lastClickLocation = pos
        } else {
            currentClickState = 1
        }

        let allowControlModifier = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)

        if let down = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: pos, mouseButton: button) {
            if !allowControlModifier {
                down.flags.remove([.maskControl, .maskSecondaryFn])
            }
            down.setIntegerValueField(.mouseEventClickState, value: currentClickState)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: pos, mouseButton: button) {
            if !allowControlModifier {
                up.flags.remove([.maskControl, .maskSecondaryFn])
            }
            up.setIntegerValueField(.mouseEventClickState, value: currentClickState)
            up.post(tap: .cghidEventTap)
        }
    }

    private func beginThreeFingerDragLocked() {
        guard !isDragging else { return }
        syncCursorAfterIdleIfNeededLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        isDragging = true
        if let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: virtualCursor,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
    }

    private func endThreeFingerDragLocked() {
        guard isDragging else { return }
        isDragging = false
        if let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: virtualCursor,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Smooth Pixel Scroll & 120Hz Inertia

    private func postScrollEvent(
        dx: Double,
        dy: Double,
        scrollPhase: Int64,
        momentumPhase: Int64
    ) {
        let wheel1 = Int32(clamping: Int(dy.rounded()))
        let wheel2 = Int32(clamping: Int(dx.rounded()))
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else { return }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }

    private func startInertiaLocked(velocityX: Double, velocityY: Double) {
        let scale = (1200.0 * config.scrollSpeed) / 120.0
        momentumVelX = velocityX * scale
        momentumVelY = velocityY * scale

        guard hypot(momentumVelX, momentumVelY) >= 1.2 else { return }

        momentumPhaseStarted = false
        let timer = DispatchSource.makeTimerSource(queue: inertiaQueue)
        timer.schedule(deadline: .now() + .microseconds(8333), repeating: .microseconds(8333), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            self?.stepInertia()
        }
        inertiaTimer = timer
        timer.resume()
    }

    private func stepInertia() {
        lock.lock()
        let mag = hypot(momentumVelX, momentumVelY)
        if mag < 0.35 {
            postScrollEvent(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)
            inertiaTimer?.cancel()
            inertiaTimer = nil
            momentumPhaseStarted = false
            lock.unlock()
            return
        }

        let phase: Int64 = momentumPhaseStarted ? 2 : 1
        momentumPhaseStarted = true
        let vx = momentumVelX
        let vy = momentumVelY
        momentumVelX *= config.inertiaDecayPerFrame
        momentumVelY *= config.inertiaDecayPerFrame
        lock.unlock()

        postScrollEvent(dx: vx, dy: vy, scrollPhase: 0, momentumPhase: phase)
    }

    private func cancelInertiaLocked() {
        guard let timer = inertiaTimer else { return }
        timer.cancel()
        inertiaTimer = nil
        if momentumPhaseStarted {
            postScrollEvent(dx: 0, dy: 0, scrollPhase: 0, momentumPhase: 3)
        }
        momentumPhaseStarted = false
        momentumVelX = 0
        momentumVelY = 0
    }

    // MARK: - Pinch-to-Zoom & System Gestures (Mission Control / App Exposé / Spaces)

    private func handlePinchZoomLocked(deltaScale: Float32) {
        pinchAccumulator += deltaScale
        let stepThreshold: Float32 = 0.055
        while abs(pinchAccumulator) >= stepThreshold {
            let zoomIn = pinchAccumulator > 0
            pinchAccumulator += zoomIn ? -stepThreshold : stepThreshold
            postKeyComboPulse(keyCode: zoomIn ? 24 : 27, flags: .maskCommand)
        }
    }

    private enum FallbackSystemApp {
        case missionControl
        case appExpose
    }

    private func triggerSystemHotkey(
        hotkeyID: String,
        defaultKeyCode: CGKeyCode,
        fallbackApp: FallbackSystemApp?
    ) {
        let resolution = resolveSymbolicHotkey(id: hotkeyID)

        // If the user explicitly disabled the Mission Control shortcut or Accessibility isn't trusted,
        // use the NSWorkspace fallback to launch Mission Control.app.
        if !AXIsProcessTrusted() || resolution == .disabled {
            if let fallbackApp {
                launchSystemFallback(fallbackApp)
            }
            return
        }

        let (keyCode, flags): (CGKeyCode, CGEventFlags) = switch resolution {
        case .enabled(let kc, let fl):
            (kc, fl)
        case .missing, .disabled:
            // Default macOS shortcuts: Control + Arrow (with Fn flag for arrow navigation keys).
            (defaultKeyCode, [.maskControl, .maskSecondaryFn])
        }

        let posted = postKeyComboPulse(keyCode: keyCode, flags: flags)
        if !posted, let fallbackApp {
            launchSystemFallback(fallbackApp)
        }
    }

    private enum HotkeyLookupResult: Equatable {
        case enabled(keyCode: CGKeyCode, flags: CGEventFlags)
        case disabled
        case missing
    }

    private func resolveSymbolicHotkey(id: String) -> HotkeyLookupResult {
        guard let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = dict[id] as? [String: Any] else {
            return .missing
        }
        if let enabled = entry["enabled"] as? Bool, !enabled {
            return .disabled
        }
        guard let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count >= 3 else {
            return .missing
        }
        let keyCodeInt = params[1]
        let modifierMask = params[2]
        guard keyCodeInt >= 0, keyCodeInt < 65535 else {
            return .missing
        }
        return .enabled(keyCode: CGKeyCode(keyCodeInt), flags: CGEventFlags(rawValue: UInt64(modifierMask)))
    }

    @discardableResult
    private func postKeyComboPulse(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        // Use an isolated private CGEventSource so shortcut modifier flags never leak into HID mouse click state.
        let source = shortcutEventSource ?? eventSource
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return false
        }
        down.flags = flags
        down.post(tap: .cghidEventTap)

        // Dispatch keyUp cleanly 14ms later with empty flags so Control never sticks after Mission Control / Spaces.
        inertiaQueue.asyncAfter(deadline: .now() + .milliseconds(14)) { [weak self] in
            guard let self else { return }
            let upSource = self.shortcutEventSource ?? self.eventSource
            guard let up = CGEvent(keyboardEventSource: upSource, virtualKey: keyCode, keyDown: false) else {
                return
            }
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private func launchSystemFallback(_ app: FallbackSystemApp) {
        let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if app == .appExpose {
            // If App Exposé is requested via fallback, launch Mission Control as safe fallback.
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        }
    }
}
