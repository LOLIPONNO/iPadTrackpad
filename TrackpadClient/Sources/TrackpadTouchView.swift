import QuartzCore
import SharedKit
import SwiftUI
import UIKit

/// High-frequency multitouch capture surface wrapped for SwiftUI.
/// Bypasses standard single/two-finger gesture recognizers so raw `UITouch` events flow directly
/// into the binary network pipeline while supporting a non-blocking 3-finger `UIPanGestureRecognizer`
/// for reliable macOS Mission Control / App Exposé / Space switching.
struct TrackpadTouchView: UIViewRepresentable {
    var showTouchIndicators: Bool
    var hapticFeedbackEnabled: Bool
    var threeFingerSwipesEnabled: Bool
    var onTouchFrame: @Sendable ([TouchPoint], UInt64) -> Void
    var onSystemGesture: @MainActor (SystemGestureAction) -> Void
    var onActiveTouchCountChanged: @MainActor (Int) -> Void
    var onDisplayRefreshMetrics: @MainActor (_ displayFPS: Double) -> Void

    func makeUIView(context: Context) -> RawTouchCaptureView {
        let view = RawTouchCaptureView()
        view.showTouchIndicators = showTouchIndicators
        view.hapticFeedbackEnabled = hapticFeedbackEnabled
        view.threeFingerSwipesEnabled = threeFingerSwipesEnabled
        view.onTouchFrame = onTouchFrame
        view.onSystemGesture = onSystemGesture
        view.onActiveTouchCountChanged = onActiveTouchCountChanged
        view.onDisplayRefreshMetrics = onDisplayRefreshMetrics
        return view
    }

    func updateUIView(_ uiView: RawTouchCaptureView, context: Context) {
        uiView.showTouchIndicators = showTouchIndicators
        uiView.hapticFeedbackEnabled = hapticFeedbackEnabled
        uiView.threeFingerSwipesEnabled = threeFingerSwipesEnabled
        uiView.onTouchFrame = onTouchFrame
        uiView.onSystemGesture = onSystemGesture
        uiView.onActiveTouchCountChanged = onActiveTouchCountChanged
        uiView.onDisplayRefreshMetrics = onDisplayRefreshMetrics
    }
}

/// Low-level `UIView` that captures multitouch events using `event.coalescedTouches(for:)`
/// and paces continuous motion emissions to the display's native `CADisplayLink` refresh cadence (60Hz/120Hz)
/// to eliminate bursty socket flooding while dispatching touch-down and touch-up transitions immediately.
final class RawTouchCaptureView: UIView, UIGestureRecognizerDelegate {
    var showTouchIndicators: Bool = false {
        didSet {
            if !showTouchIndicators {
                clearTouchLayers()
            }
        }
    }
    var hapticFeedbackEnabled: Bool = true
    var threeFingerSwipesEnabled: Bool = true {
        didSet {
            threeFingerPanRecognizer?.isEnabled = threeFingerSwipesEnabled
        }
    }

    var onTouchFrame: (@Sendable ([TouchPoint], UInt64) -> Void)?
    var onSystemGesture: (@MainActor (SystemGestureAction) -> Void)?
    var onActiveTouchCountChanged: (@MainActor (Int) -> Void)?
    var onDisplayRefreshMetrics: (@MainActor (_ displayFPS: Double) -> Void)?

    private var touchIDMap: [ObjectIdentifier: UInt32] = [:]
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]
    private var latestCoalescedLocations: [ObjectIdentifier: CGPoint] = [:]
    private var nextTouchID: UInt32 = 1
    private var lastNotifiedTouchCount: Int = -1

    private var indicatorLayers: [UInt32: CAShapeLayer] = [:]
    private let clickHaptic = UIImpactFeedbackGenerator(style: .light)
    private let gestureHaptic = UIImpactFeedbackGenerator(style: .medium)

    // DisplayLink coalescing: holds the freshest moved snapshot until the next vsync tick.
    private var pendingMovedSnapshot: (points: [TouchPoint], timestampNs: UInt64)?

    // 3-finger system swipe recognizer (Mission Control / App Exposé / Spaces)
    private var threeFingerPanRecognizer: UIPanGestureRecognizer?
    private var hasTriggeredThreeFingerSwipe = false

    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: RawTouchCaptureView?
        init(owner: RawTouchCaptureView) { self.owner = owner }
        @objc func step(_ link: CADisplayLink) {
            if let owner {
                owner.handleDisplayLink(link)
            } else {
                link.invalidate()
            }
        }
    }

    private var displayLink: CADisplayLink?
    private var displayFrameCounter: Int = 0
    private var displayWindowStart: CFTimeInterval = 0

    // Used for lightweight local tap haptic feedback when tap-to-click occurs.
    private var touchDownTimestamps: [ObjectIdentifier: UInt64] = [:]
    private var touchDownLocations: [ObjectIdentifier: CGPoint] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
        isUserInteractionEnabled = true
        backgroundColor = .black

        clickHaptic.prepare()
        gestureHaptic.prepare()

        // Non-blocking 3-finger pan recognizer for discrete macOS system gestures.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        pan.minimumNumberOfTouches = 3
        pan.maximumNumberOfTouches = 3
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        pan.isEnabled = threeFingerSwipesEnabled
        addGestureRecognizer(pan)
        threeFingerPanRecognizer = pan
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startProMotionDisplayLink()
        } else {
            stopProMotionDisplayLink()
        }
    }

    func triggerHaptic(style: HapticCuePayload.Style = .click) {
        guard hapticFeedbackEnabled else { return }
        switch style {
        case .click:
            clickHaptic.impactOccurred(intensity: 0.7)
            clickHaptic.prepare()
        case .secondaryClick, .gestureThreshold:
            gestureHaptic.impactOccurred(intensity: 0.85)
            gestureHaptic.prepare()
        }
    }

    // MARK: - UIGestureRecognizerDelegate & 3-Finger System Swipes

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard threeFingerSwipesEnabled else { return }

        switch recognizer.state {
        case .began:
            hasTriggeredThreeFingerSwipe = false
            gestureHaptic.prepare()

        case .changed:
            guard !hasTriggeredThreeFingerSwipe else { return }
            let t = recognizer.translation(in: self)
            let v = recognizer.velocity(in: self)
            let absX = abs(t.x)
            let absY = abs(t.y)

            let distanceThreshold: CGFloat = 46
            let flickMinDistance: CGFloat = 26
            let flickVelocityThreshold: CGFloat = 450

            let isVerticalDominant = absY > absX * 1.35
            let isHorizontalDominant = absX > absY * 1.35

            if isVerticalDominant && (absY >= distanceThreshold || (absY >= flickMinDistance && abs(v.y) >= flickVelocityThreshold)) {
                hasTriggeredThreeFingerSwipe = true
                let action: SystemGestureAction = t.y < 0 ? .missionControl : .appExpose
                triggerHaptic(style: .gestureThreshold)
                onSystemGesture?(action)
            } else if isHorizontalDominant && (absX >= distanceThreshold || (absX >= flickMinDistance && abs(v.x) >= flickVelocityThreshold)) {
                hasTriggeredThreeFingerSwipe = true
                // Natural macOS trackpad direction: swiping fingers left reveals the Space on the right, and vice versa.
                let action: SystemGestureAction = t.x < 0 ? .spaceRight : .spaceLeft
                triggerHaptic(style: .gestureThreshold)
                onSystemGesture?(action)
            }

        case .ended, .cancelled, .failed:
            hasTriggeredThreeFingerSwipe = false

        default:
            break
        }
    }

    // MARK: - DisplayLink (60Hz/120Hz Coalesced Flush + FPS Measurement)

    private func startProMotionDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        displayWindowStart = CACurrentMediaTime()
    }

    private func stopProMotionDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        // Flush at most one coalesced motion snapshot per display refresh tick.
        if let pending = pendingMovedSnapshot {
            pendingMovedSnapshot = nil
            onTouchFrame?(pending.points, pending.timestampNs)
        }

        displayFrameCounter += 1
        let now = link.timestamp
        if displayWindowStart == 0 {
            displayWindowStart = now
        }
        let elapsed = now - displayWindowStart
        if elapsed >= 0.5 {
            let fps = Double(displayFrameCounter) / elapsed
            displayFrameCounter = 0
            displayWindowStart = now
            onDisplayRefreshMetrics?(fps)
        }
    }

    // MARK: - Raw Multitouch Overrides

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if touchIDMap[key] == nil {
                touchIDMap[key] = allocateTouchID()
            }
            activeTouches[key] = touch
            let loc = touch.location(in: self)
            latestCoalescedLocations[key] = loc
            touchDownTimestamps[key] = nowNs
            touchDownLocations[key] = loc
        }
        clickHaptic.prepare()
        pendingMovedSnapshot = nil
        let snapshot = buildSnapshot(changedTouches: touches, overridePhase: nil)
        onTouchFrame?(snapshot.points, nowNs)
        notifyTouchCountIfChanged(snapshot.activeCount)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if touchIDMap[key] == nil {
                touchIDMap[key] = allocateTouchID()
            }
            activeTouches[key] = touch
            // Use the freshest coalesced touch sample for maximum precision without duplicate bursts.
            let freshest = event?.coalescedTouches(for: touch)?.last ?? touch
            latestCoalescedLocations[key] = freshest.location(in: self)
        }
        let snapshot = buildSnapshot(changedTouches: touches, overridePhase: nil)
        // Stage for next DisplayLink vsync so rapid UIKit touch bursts coalesce cleanly to 60Hz/120Hz.
        pendingMovedSnapshot = (snapshot.points, nowNs)
        notifyTouchCountIfChanged(snapshot.activeCount)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let freshest = event?.coalescedTouches(for: touch)?.last ?? touch
            latestCoalescedLocations[key] = freshest.location(in: self)
        }

        if hapticFeedbackEnabled && touches.count == activeTouches.count && touches.count <= 2 {
            let isQuickTap = touches.allSatisfy { touch in
                let key = ObjectIdentifier(touch)
                guard let downNs = touchDownTimestamps[key],
                      let downPt = touchDownLocations[key] else { return false }
                let loc = touch.location(in: self)
                let dist = hypot(loc.x - downPt.x, loc.y - downPt.y)
                return (nowNs &- downNs) <= 220_000_000 && dist <= 18
            }
            if isQuickTap {
                triggerHaptic(style: touches.count == 2 ? .secondaryClick : .click)
            }
        }

        pendingMovedSnapshot = nil
        let snapshot = buildSnapshot(changedTouches: touches, overridePhase: .ended)
        onTouchFrame?(snapshot.points, nowNs)

        for touch in touches {
            let key = ObjectIdentifier(touch)
            if let tid = touchIDMap.removeValue(forKey: key) {
                removeIndicatorLayer(for: tid)
            }
            activeTouches.removeValue(forKey: key)
            latestCoalescedLocations.removeValue(forKey: key)
            touchDownTimestamps.removeValue(forKey: key)
            touchDownLocations.removeValue(forKey: key)
        }
        notifyTouchCountIfChanged(activeTouches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        pendingMovedSnapshot = nil
        let snapshot = buildSnapshot(changedTouches: touches, overridePhase: .cancelled)
        onTouchFrame?(snapshot.points, nowNs)

        for touch in touches {
            let key = ObjectIdentifier(touch)
            if let tid = touchIDMap.removeValue(forKey: key) {
                removeIndicatorLayer(for: tid)
            }
            activeTouches.removeValue(forKey: key)
            latestCoalescedLocations.removeValue(forKey: key)
            touchDownTimestamps.removeValue(forKey: key)
            touchDownLocations.removeValue(forKey: key)
        }
        notifyTouchCountIfChanged(activeTouches.count)
    }

    // MARK: - Snapshot Packing & Optional Indicators

    private func buildSnapshot(
        changedTouches: Set<UITouch>,
        overridePhase: TouchPhase?
    ) -> (points: [TouchPoint], activeCount: Int) {
        let width = max(bounds.width, 1.0)
        let height = max(bounds.height, 1.0)

        var points: [TouchPoint] = []
        points.reserveCapacity(activeTouches.count)

        let changedSet = Set(changedTouches.map(ObjectIdentifier.init))
        var activeCount = 0

        for (key, touch) in activeTouches {
            guard let touchID = touchIDMap[key] else { continue }
            let location = latestCoalescedLocations[key] ?? touch.location(in: self)
            let normX = Float32(min(max(location.x / width, 0.0), 1.0))
            let normY = Float32(min(max(location.y / height, 0.0), 1.0))

            let phase: TouchPhase
            if changedSet.contains(key), let overridePhase {
                phase = overridePhase
            } else {
                phase = mapPhase(touch.phase)
            }

            if phase != .ended && phase != .cancelled {
                activeCount += 1
            }

            var flags: TouchPointFlags = []
            if touch.type == .pencil {
                flags.insert(.isStylus)
            }
            if touch.majorRadius > 55 {
                flags.insert(.isPalmCandidate)
            }

            let radiusScaled = UInt16(clamping: Int((touch.majorRadius * 100.0).rounded()))
            points.append(TouchPoint(
                touchID: touchID,
                x: normX,
                y: normY,
                phase: phase,
                flags: flags,
                majorRadius: radiusScaled
            ))

            if showTouchIndicators && phase != .ended && phase != .cancelled {
                updateIndicatorLayer(for: touchID, at: location, radius: max(touch.majorRadius, 22))
            }
        }

        points.sort { $0.touchID < $1.touchID }
        return (points, activeCount)
    }

    private func notifyTouchCountIfChanged(_ count: Int) {
        guard count != lastNotifiedTouchCount else { return }
        lastNotifiedTouchCount = count
        onActiveTouchCountChanged?(count)
    }

    private func mapPhase(_ uiPhase: UITouch.Phase) -> TouchPhase {
        switch uiPhase {
        case .began: return .began
        case .moved: return .moved
        case .stationary: return .stationary
        case .ended: return .ended
        case .cancelled: return .cancelled
        case .regionEntered, .regionMoved, .regionExited: return .moved
        @unknown default: return .moved
        }
    }

    private func allocateTouchID() -> UInt32 {
        let id = nextTouchID
        nextTouchID = nextTouchID == UInt32.max ? 1 : nextTouchID + 1
        return id
    }

    private func updateIndicatorLayer(for touchID: UInt32, at point: CGPoint, radius: CGFloat) {
        let layer: CAShapeLayer
        if let existing = indicatorLayers[touchID] {
            layer = existing
        } else {
            let created = CAShapeLayer()
            created.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
            created.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            created.lineWidth = 1.5
            self.layer.addSublayer(created)
            indicatorLayers[touchID] = created
            layer = created
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = min(max(radius, 20), 42)
        layer.path = UIBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)).cgPath
        CATransaction.commit()
    }

    private func removeIndicatorLayer(for touchID: UInt32) {
        indicatorLayers.removeValue(forKey: touchID)?.removeFromSuperlayer()
    }

    private func clearTouchLayers() {
        for layer in indicatorLayers.values {
            layer.removeFromSuperlayer()
        }
        indicatorLayers.removeAll()
    }
}
