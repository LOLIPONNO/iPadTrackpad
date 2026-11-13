import Foundation

/// Stateful sender-side delta compressor that suppresses static touch frames (zero bytes sent)
/// and optionally emits compact delta frames when only a subset of fingers move.
public struct TouchDeltaCompressor: Sendable {
    public let positionEpsilon: Float32
    public let keyframeInterval: UInt32

    private var lastPoints: [UInt32: TouchPoint] = [:]
    private var framesSinceKeyframe: UInt32 = 0
    private var nextFrameIndex: UInt32 = 1

    public private(set) var totalFramesEvaluated: UInt64 = 0
    public private(set) var suppressedFrames: UInt64 = 0

    public init(positionEpsilon: Float32 = 0.00012, keyframeInterval: UInt32 = 30) {
        self.positionEpsilon = positionEpsilon
        self.keyframeInterval = keyframeInterval
    }

    public mutating func reset() {
        lastPoints.removeAll(keepingCapacity: true)
        framesSinceKeyframe = 0
        nextFrameIndex = 1
        totalFramesEvaluated = 0
        suppressedFrames = 0
    }

    /// Evaluates a raw snapshot of current touches and returns either:
    /// - `nil` when all contacts are static (zero payload sent over the wire), or
    /// - a `TouchPacket` ready for binary encoding.
    public mutating func compress(
        points: [TouchPoint],
        timestampNs: UInt64
    ) -> TouchPacket? {
        totalFramesEvaluated &+= 1

        // If no touches are active and we already sent an empty state, send nothing.
        if points.isEmpty && lastPoints.isEmpty {
            suppressedFrames &+= 1
            return nil
        }

        var hasLifecycleEvent = false
        var changedPoints: [TouchPoint] = []
        changedPoints.reserveCapacity(points.count)

        var nextActiveMap: [UInt32: TouchPoint] = [:]
        nextActiveMap.reserveCapacity(points.count)

        for point in points {
            let isTerminal = (point.phase == .ended || point.phase == .cancelled)
            if point.phase == .began || isTerminal {
                hasLifecycleEvent = true
                changedPoints.append(point)
            } else if let prev = lastPoints[point.touchID] {
                let dx = abs(point.x - prev.x)
                let dy = abs(point.y - prev.y)
                if dx >= positionEpsilon || dy >= positionEpsilon || point.flags != prev.flags {
                    changedPoints.append(point)
                }
            } else {
                // Unknown touchID without `.began` (e.g. after packet loss); treat as new.
                hasLifecycleEvent = true
                changedPoints.append(point)
            }

            if !isTerminal {
                nextActiveMap[point.touchID] = point
            }
        }

        // Detect vanished touch IDs that disappeared without `.ended`/`.cancelled`.
        let disappearedCount = lastPoints.keys.reduce(into: 0) { count, oldID in
            if nextActiveMap[oldID] == nil && !points.contains(where: { $0.touchID == oldID }) {
                count += 1
            }
        }
        if disappearedCount > 0 {
            hasLifecycleEvent = true
        }

        // Static frame -> suppress completely!
        if changedPoints.isEmpty && !hasLifecycleEvent {
            suppressedFrames &+= 1
            return nil
        }

        let frameIndex = nextFrameIndex
        nextFrameIndex &+= 1

        let needsKeyframe = hasLifecycleEvent
            || framesSinceKeyframe >= keyframeInterval
            || changedPoints.count == points.count

        lastPoints = nextActiveMap

        if needsKeyframe {
            framesSinceKeyframe = 0
            return TouchPacket(
                frameIndex: frameIndex,
                timestampNs: timestampNs,
                flags: .isKeyframe,
                points: points
            )
        } else {
            framesSinceKeyframe &+= 1
            return TouchPacket(
                frameIndex: frameIndex,
                timestampNs: timestampNs,
                flags: .isDelta,
                points: changedPoints
            )
        }
    }
}

/// Receiver-side state reconstructor that turns both `.isKeyframe` and `.isDelta` packets
/// into a complete, ordered list of active `TouchPoint`s (discarding out-of-order stale UDP frames).
public struct TouchDeltaReconstructor: Sendable {
    private var activePoints: [UInt32: TouchPoint] = [:]
    private var lastFrameIndex: UInt32 = 0
    public private(set) var droppedOutOfOrderCount: UInt64 = 0

    public init() {}

    public mutating func reset() {
        activePoints.removeAll(keepingCapacity: true)
        lastFrameIndex = 0
        droppedOutOfOrderCount = 0
    }

    /// Applies an incoming `TouchPacket`. Returns `nil` if the frame arrived out of order.
    public mutating func apply(_ packet: TouchPacket) -> [TouchPoint]? {
        // Wrap-safe sequence check: ignore stale UDP datagrams, while allowing fresh session resets (`frameIndex == 1` keyframe).
        let isFreshReset = packet.frameIndex == 1 && packet.flags.contains(.isKeyframe)
        if lastFrameIndex != 0 && !isFreshReset {
            let delta = Int32(bitPattern: packet.frameIndex &- lastFrameIndex)
            if delta <= 0 && !packet.flags.contains(.isKeyframe) {
                droppedOutOfOrderCount &+= 1
                return nil
            }
            if delta <= 0 && delta > -100 {
                droppedOutOfOrderCount &+= 1
                return nil
            }
        }
        lastFrameIndex = packet.frameIndex

        if packet.flags.contains(.isKeyframe) {
            var rebuilt: [UInt32: TouchPoint] = [:]
            rebuilt.reserveCapacity(packet.points.count)
            for p in packet.points {
                rebuilt[p.touchID] = p
            }
            activePoints = rebuilt
            // Return points including terminal phases for this frame, then prune ended/cancelled.
            let output = packet.points.sorted { $0.touchID < $1.touchID }
            for p in packet.points where p.phase == .ended || p.phase == .cancelled {
                activePoints.removeValue(forKey: p.touchID)
            }
            return output
        } else {
            // Delta frame: merge updated points into activePoints, marking untouched ones as `.stationary`.
            var merged = activePoints.mapValues { existing -> TouchPoint in
                var copy = existing
                copy.phase = .stationary
                return copy
            }
            for p in packet.points {
                merged[p.touchID] = p
            }
            let output = merged.values.sorted { $0.touchID < $1.touchID }
            activePoints = merged.filter { $0.value.phase != .ended && $0.value.phase != .cancelled }
            return output
        }
    }
}
