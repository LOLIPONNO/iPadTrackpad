import Foundation

/// High-level trackpad gestures emitted by `GestureStateMachine` and consumed by `SyntheticEventDriver`.
public enum GestureAction: Sendable, Equatable {
    case moveCursor(dx: Float32, dy: Float32)
    case leftClick
    case rightClick
    case scrollBegan
    case scrollChanged(dx: Float32, dy: Float32, velocityX: Float32, velocityY: Float32)
    case scrollEnded(velocityX: Float32, velocityY: Float32)
    case pinchZoom(deltaScale: Float32)
    case threeFingerDragBegan
    case threeFingerDragMoved(dx: Float32, dy: Float32)
    case threeFingerDragEnded
    case fourFingerSwipe(SwipeDirection)
}

public enum SwipeDirection: Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public struct GestureConfig: Sendable, Equatable {
    public var tapToClickEnabled: Bool
    public var threeFingerDragEnabled: Bool
    public var naturalScrolling: Bool
    public var tapMaxDurationNs: UInt64
    public var tapMaxTravel: Float32
    public var fourFingerSwipeThreshold: Float32
    public var pinchActivationDelta: Float32

    public init(
        tapToClickEnabled: Bool = true,
        threeFingerDragEnabled: Bool = false,
        naturalScrolling: Bool = true,
        tapMaxDurationNs: UInt64 = 280_000_000,
        tapMaxTravel: Float32 = 0.024,
        fourFingerSwipeThreshold: Float32 = 0.085,
        pinchActivationDelta: Float32 = 0.012
    ) {
        self.tapToClickEnabled = tapToClickEnabled
        self.threeFingerDragEnabled = threeFingerDragEnabled
        self.naturalScrolling = naturalScrolling
        self.tapMaxDurationNs = tapMaxDurationNs
        self.tapMaxTravel = tapMaxTravel
        self.fourFingerSwipeThreshold = fourFingerSwipeThreshold
        self.pinchActivationDelta = pinchActivationDelta
    }
}

/// Deterministic, platform-independent multitouch gesture state machine.
/// Processes normalized `[0, 1]` `TouchPoint` snapshots and emits discrete `GestureAction`s.
public final class GestureStateMachine: @unchecked Sendable {
    public var config: GestureConfig

    private enum Mode {
        case idle
        case oneFinger
        case twoFingerUndecided
        case twoFingerScroll
        case twoFingerPinch
        case threeFingerDrag
        case threeFingerSuppress
        case fourFingerSwipe
        case liftCooldown(untilNs: UInt64)
    }

    private var mode: Mode = .idle
    private var previousFingerCount: Int = 0
    private var peakFingerCountInContact: Int = 0
    private var contactStartNs: UInt64 = 0
    private var lastTimestampNs: UInt64 = 0

    private var previousCentroid: (x: Float32, y: Float32) = (0, 0)
    private var initialCentroid: (x: Float32, y: Float32) = (0, 0)
    private var previousSpan: Float32 = 0
    private var cumulativePinchDelta: Float32 = 0
    private var cumulativeTravel: Float32 = 0
    private var fourFingerTriggered = false
    private var threeFingerDragActive = false

    private var smoothedVelX: Float32 = 0
    private var smoothedVelY: Float32 = 0

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    public func reset() {
        mode = .idle
        previousFingerCount = 0
        peakFingerCountInContact = 0
        contactStartNs = 0
        lastTimestampNs = 0
        previousCentroid = (0, 0)
        initialCentroid = (0, 0)
        previousSpan = 0
        cumulativePinchDelta = 0
        cumulativeTravel = 0
        fourFingerTriggered = false
        threeFingerDragActive = false
        smoothedVelX = 0
        smoothedVelY = 0
    }

    /// Consumes a complete, ordered snapshot of active + just-ended `TouchPoint`s for a frame.
    public func process(points: [TouchPoint], timestampNs: UInt64) -> [GestureAction] {
        var actions: [GestureAction] = []

        let rawActive = points.filter { $0.phase != .ended && $0.phase != .cancelled }
        let nonPalmActive = rawActive.filter { !$0.flags.contains(.isPalmCandidate) }
        let active = nonPalmActive.isEmpty ? rawActive : nonPalmActive
        let activeCount = active.count

        defer {
            previousFingerCount = activeCount
            lastTimestampNs = timestampNs
        }

        // All fingers lifted -> finalize any active gesture or tap.
        if activeCount == 0 {
            finalizeOnAllLifted(timestampNs: timestampNs, actions: &actions)
            return actions
        }

        let centroid = computeCentroid(active)
        let span = computeSpan(active, centroid: centroid)

        // Transition from 0 fingers -> new touch session.
        if previousFingerCount == 0 {
            contactStartNs = timestampNs
            lastTimestampNs = timestampNs
            peakFingerCountInContact = activeCount
            previousCentroid = centroid
            initialCentroid = centroid
            previousSpan = span
            cumulativePinchDelta = 0
            cumulativeTravel = 0
            fourFingerTriggered = false
            threeFingerDragActive = false
            smoothedVelX = 0
            smoothedVelY = 0
            mode = initialMode(for: activeCount)
            if case .twoFingerScroll = mode {
                actions.append(.scrollBegan)
            }
            return actions
        }

        peakFingerCountInContact = max(peakFingerCountInContact, activeCount)

        // Finger count changed mid-session: rebase centroid/span to prevent cursor jumps.
        if activeCount != previousFingerCount {
            handleFingerCountTransition(
                from: previousFingerCount,
                to: activeCount,
                centroid: centroid,
                span: span,
                timestampNs: timestampNs,
                actions: &actions
            )
            previousCentroid = centroid
            previousSpan = span
            return actions
        }

        // Same finger count -> evaluate deltas.
        let dx = centroid.x - previousCentroid.x
        let dy = centroid.y - previousCentroid.y
        let stepTravel = hypot(dx, dy)
        cumulativeTravel += stepTravel

        let dtSec = max(Float32(timestampNs &- lastTimestampNs) / 1_000_000_000.0, 0.001)

        switch mode {
        case .idle:
            mode = initialMode(for: activeCount)

        case .liftCooldown(let untilNs):
            if timestampNs >= untilNs && activeCount == 1 {
                mode = .oneFinger
            }

        case .oneFinger:
            if dx != 0 || dy != 0 {
                actions.append(.moveCursor(dx: dx, dy: dy))
            }

        case .twoFingerUndecided:
            let spanDelta = span - previousSpan
            cumulativePinchDelta += abs(spanDelta)

            if cumulativePinchDelta >= config.pinchActivationDelta && abs(spanDelta) > stepTravel * 0.65 {
                mode = .twoFingerPinch
                actions.append(.pinchZoom(deltaScale: spanDelta))
            } else if cumulativeTravel >= 0.004 {
                mode = .twoFingerScroll
                actions.append(.scrollBegan)
                emitScrollDelta(dx: dx, dy: dy, dtSec: dtSec, actions: &actions)
            }

        case .twoFingerScroll:
            if dx != 0 || dy != 0 {
                emitScrollDelta(dx: dx, dy: dy, dtSec: dtSec, actions: &actions)
            }

        case .twoFingerPinch:
            let spanDelta = span - previousSpan
            if abs(spanDelta) > 0.0001 {
                actions.append(.pinchZoom(deltaScale: spanDelta))
            }

        case .threeFingerDrag:
            if config.threeFingerDragEnabled && (dx != 0 || dy != 0) {
                if !threeFingerDragActive {
                    threeFingerDragActive = true
                    actions.append(.threeFingerDragBegan)
                }
                actions.append(.threeFingerDragMoved(dx: dx, dy: dy))
            }

        case .threeFingerSuppress:
            // Suppress cursor movement and scrolling while 3-finger system swipe is handled via reliable TCP.
            break

        case .fourFingerSwipe:
            if !fourFingerTriggered {
                let totalDx = centroid.x - initialCentroid.x
                let totalDy = centroid.y - initialCentroid.y
                let threshold = config.fourFingerSwipeThreshold
                if abs(totalDy) >= threshold && abs(totalDy) > abs(totalDx) * 1.25 {
                    fourFingerTriggered = true
                    actions.append(.fourFingerSwipe(totalDy < 0 ? .up : .down))
                } else if abs(totalDx) >= threshold && abs(totalDx) > abs(totalDy) * 1.25 {
                    fourFingerTriggered = true
                    actions.append(.fourFingerSwipe(totalDx < 0 ? .left : .right))
                }
            }
        }

        previousCentroid = centroid
        previousSpan = span
        return actions
    }

    // MARK: - Helpers

    private func initialMode(for count: Int) -> Mode {
        switch count {
        case 1: return .oneFinger
        case 2: return .twoFingerUndecided
        case 3: return config.threeFingerDragEnabled ? .threeFingerDrag : .threeFingerSuppress
        default: return .fourFingerSwipe
        }
    }

    private func handleFingerCountTransition(
        from oldCount: Int,
        to newCount: Int,
        centroid: (x: Float32, y: Float32),
        span: Float32,
        timestampNs: UInt64,
        actions: inout [GestureAction]
    ) {
        // Close out modes that only apply to `oldCount`.
        if case .twoFingerScroll = mode, newCount != 2 {
            actions.append(.scrollEnded(velocityX: smoothedVelX, velocityY: smoothedVelY))
        }
        if threeFingerDragActive && newCount < 3 {
            threeFingerDragActive = false
            actions.append(.threeFingerDragEnded)
        }

        // Adding fingers early in a contact resets anchor for multi-finger gestures.
        if newCount > oldCount {
            initialCentroid = centroid
            cumulativePinchDelta = 0
            fourFingerTriggered = false
            switch newCount {
            case 2:
                mode = .twoFingerUndecided
            case 3:
                mode = config.threeFingerDragEnabled ? .threeFingerDrag : .threeFingerSuppress
            default:
                mode = .fourFingerSwipe
            }
        } else {
            // Reducing fingers (e.g. 2->1 or 4->2 during lift-off): enter brief cooldown
            // so asymmetric finger lift doesn't cause cursor jitter.
            if newCount == 1 && peakFingerCountInContact >= 2 {
                mode = .liftCooldown(untilNs: timestampNs &+ 95_000_000)
            } else {
                mode = initialMode(for: newCount)
            }
        }
    }

    private func finalizeOnAllLifted(timestampNs: UInt64, actions: inout [GestureAction]) {
        if case .twoFingerScroll = mode {
            actions.append(.scrollEnded(velocityX: smoothedVelX, velocityY: smoothedVelY))
        }
        if threeFingerDragActive {
            threeFingerDragActive = false
            actions.append(.threeFingerDragEnded)
        }

        let durationNs = timestampNs &- contactStartNs
        let isTap = config.tapToClickEnabled
            && durationNs <= config.tapMaxDurationNs
            && cumulativeTravel <= config.tapMaxTravel

        if isTap {
            if peakFingerCountInContact == 1 {
                actions.append(.leftClick)
            } else if peakFingerCountInContact == 2 {
                actions.append(.rightClick)
            }
        }

        reset()
    }

    private func emitScrollDelta(
        dx: Float32,
        dy: Float32,
        dtSec: Float32,
        actions: inout [GestureAction]
    ) {
        let sign: Float32 = config.naturalScrolling ? 1.0 : -1.0
        let sdx = dx * sign
        let sdy = dy * sign

        let instVelX = sdx / dtSec
        let instVelY = sdy / dtSec
        smoothedVelX = smoothedVelX * 0.6 + instVelX * 0.4
        smoothedVelY = smoothedVelY * 0.6 + instVelY * 0.4

        actions.append(.scrollChanged(dx: sdx, dy: sdy, velocityX: smoothedVelX, velocityY: smoothedVelY))
    }

    private func computeCentroid(_ points: [TouchPoint]) -> (x: Float32, y: Float32) {
        var sx: Float32 = 0
        var sy: Float32 = 0
        for p in points {
            sx += p.x
            sy += p.y
        }
        let inv = 1.0 / Float32(points.count)
        return (sx * inv, sy * inv)
    }

    private func computeSpan(_ points: [TouchPoint], centroid: (x: Float32, y: Float32)) -> Float32 {
        guard points.count >= 2 else { return 0 }
        var total: Float32 = 0
        for p in points {
            total += hypot(p.x - centroid.x, p.y - centroid.y)
        }
        return total / Float32(points.count)
    }
}
