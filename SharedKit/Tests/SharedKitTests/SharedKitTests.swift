import Foundation
import Testing
@testable import SharedKit

@Suite("SharedKit Protocol, Compression & Gesture Tests")
struct SharedKitTests {
    @Test("Binary PacketCodec roundtrips TouchPacket with zero Codable overhead")
    func touchPacketRoundTrip() throws {
        let points = [
            TouchPoint(touchID: 1, x: 0.25, y: 0.75, phase: .began, flags: [.isPredicted], majorRadius: 1450),
            TouchPoint(touchID: 2, x: 0.55, y: 0.35, phase: .moved, flags: [], majorRadius: 1200)
        ]
        let original = TouchPacket(
            frameIndex: 42,
            timestampNs: 987_654_321_123,
            flags: [.isKeyframe],
            points: points
        )

        let encoded = PacketCodec.encode(.touchFrame(original))
        #expect(encoded.count == TrackpadProtocol.headerSize + TrackpadProtocol.touchFrameSubheaderSize + 2 * TrackpadProtocol.touchPointByteSize)

        let decoded = try PacketCodec.decode(encoded)
        #expect(decoded == .touchFrame(original))
    }

    @Test("Binary PacketCodec roundtrips Handshake, Heartbeat, and HapticCue")
    func controlPacketsRoundTrip() throws {
        let handshake = HandshakePayload(udpPort: 51234, aspectRatio: 1.333, deviceName: "Hyun's iPad Pro")
        let decodedHandshake = try PacketCodec.decode(PacketCodec.encode(.handshakeAck(handshake)))
        #expect(decodedHandshake == .handshakeAck(handshake))

        let ping = HeartbeatPayload(sequence: 9, clientTimestampNs: 111_222_333, serverTimestampNs: 444_555_666)
        let decodedPong = try PacketCodec.decode(PacketCodec.encode(.pong(ping)))
        #expect(decodedPong == .pong(ping))

        let cue = HapticCuePayload(style: .gestureThreshold, intensity: 0.75)
        let decodedCue = try PacketCodec.decode(PacketCodec.encode(.hapticCue(cue)))
        #expect(decodedCue == .hapticCue(cue))

        for action in [SystemGestureAction.missionControl, .appExpose, .spaceLeft, .spaceRight] {
            let encoded = PacketCodec.encode(.systemGesture(action))
            #expect(encoded.count == TrackpadProtocol.headerSize + 1)
            let decoded = try PacketCodec.decode(encoded)
            #expect(decoded == .systemGesture(action))
        }
    }

    @Test("PacketCodec rejects invalid magic and truncated frames")
    func invalidPacketRejection() {
        let badMagic = Data([0x00, 0x00, 1, 3, 0, 0, 0, 0])
        #expect(throws: PacketCodecError.invalidMagic) {
            _ = try PacketCodec.decode(badMagic)
        }

        let truncated = Data([0x50, 0x54, 1])
        #expect(throws: PacketCodecError.truncatedData) {
            _ = try PacketCodec.decode(truncated)
        }
    }

    @Test("DeltaCompressor suppresses static touches and reconstructs delta frames")
    func deltaCompressionAndReconstruction() {
        var compressor = TouchDeltaCompressor(positionEpsilon: 0.001, keyframeInterval: 10)
        var reconstructor = TouchDeltaReconstructor()

        // 1. Touch down -> emits keyframe
        let p1Began = TouchPoint(touchID: 1, x: 0.5, y: 0.5, phase: .began)
        let p2Began = TouchPoint(touchID: 2, x: 0.6, y: 0.5, phase: .began)
        let pkt1 = compressor.compress(points: [p1Began, p2Began], timestampNs: 1_000)
        #expect(pkt1 != nil)
        #expect(pkt1?.flags.contains(.isKeyframe) == true)
        #expect(reconstructor.apply(pkt1!)?.count == 2)

        // 2. Sub-epsilon static frame -> suppressed completely (nil)
        let p1Static = TouchPoint(touchID: 1, x: 0.5001, y: 0.5001, phase: .moved)
        let p2Static = TouchPoint(touchID: 2, x: 0.6, y: 0.5, phase: .stationary)
        let pkt2 = compressor.compress(points: [p1Static, p2Static], timestampNs: 2_000)
        #expect(pkt2 == nil)
        #expect(compressor.suppressedFrames == 1)

        // 3. Only finger 1 moves -> emits delta with 1 point, reconstructor outputs both points
        let p1Moved = TouchPoint(touchID: 1, x: 0.52, y: 0.5, phase: .moved)
        let pkt3 = compressor.compress(points: [p1Moved, p2Static], timestampNs: 3_000)
        #expect(pkt3 != nil)
        #expect(pkt3?.flags.contains(.isDelta) == true)
        #expect(pkt3?.points.count == 1)
        let reconstructed = reconstructor.apply(pkt3!)
        #expect(reconstructed?.count == 2)
        #expect(reconstructed?.first(where: { $0.touchID == 1 })?.x == 0.52)
        #expect(reconstructed?.first(where: { $0.touchID == 2 })?.phase == .stationary)

        // 4. Out-of-order stale UDP frame is dropped
        let stale = TouchPacket(frameIndex: 1, timestampNs: 500, flags: .isDelta, points: [p1Moved])
        #expect(reconstructor.apply(stale) == nil)
        #expect(reconstructor.droppedOutOfOrderCount == 1)

        // 5. Fresh reconnect keyframe with frameIndex == 1 is accepted
        let reconnect = TouchPacket(frameIndex: 1, timestampNs: 5000, flags: .isKeyframe, points: [p1Began])
        #expect(reconstructor.apply(reconnect)?.count == 1)
    }

    @Test("GestureStateMachine recognizes 1F tap, 2F right-click, 3F suppression/drag, and 4F Mission Control")
    func gestureStateMachine() {
        // Default config suppresses 3-finger touch stream (handled as system gestures via TCP)
        let defaultEngine = GestureStateMachine()
        _ = defaultEngine.process(points: [
            TouchPoint(touchID: 1, x: 0.3, y: 0.5, phase: .began),
            TouchPoint(touchID: 2, x: 0.4, y: 0.5, phase: .began),
            TouchPoint(touchID: 3, x: 0.5, y: 0.5, phase: .began)
        ], timestampNs: 10_000_000)
        let suppressed3F = defaultEngine.process(points: [
            TouchPoint(touchID: 1, x: 0.3, y: 0.4, phase: .moved),
            TouchPoint(touchID: 2, x: 0.4, y: 0.4, phase: .moved),
            TouchPoint(touchID: 3, x: 0.5, y: 0.4, phase: .moved)
        ], timestampNs: 26_000_000)
        #expect(suppressed3F.isEmpty)

        // Explicit 3-finger drag enabled
        let engine = GestureStateMachine(config: GestureConfig(threeFingerDragEnabled: true))

        // 1-finger tap
        _ = engine.process(points: [TouchPoint(touchID: 1, x: 0.5, y: 0.5, phase: .began)], timestampNs: 10_000_000)
        let tapActions = engine.process(points: [TouchPoint(touchID: 1, x: 0.502, y: 0.501, phase: .ended)], timestampNs: 60_000_000)
        #expect(tapActions.contains(.leftClick))

        // 2-finger tap -> right click
        _ = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.4, y: 0.5, phase: .began),
            TouchPoint(touchID: 2, x: 0.6, y: 0.5, phase: .began)
        ], timestampNs: 200_000_000)
        let rightTap = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.4, y: 0.5, phase: .ended),
            TouchPoint(touchID: 2, x: 0.6, y: 0.5, phase: .ended)
        ], timestampNs: 280_000_000)
        #expect(rightTap.contains(.rightClick))

        // 3-finger drag
        _ = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.3, y: 0.5, phase: .began),
            TouchPoint(touchID: 2, x: 0.4, y: 0.5, phase: .began),
            TouchPoint(touchID: 3, x: 0.5, y: 0.5, phase: .began)
        ], timestampNs: 400_000_000)
        let dragMove = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.35, y: 0.52, phase: .moved),
            TouchPoint(touchID: 2, x: 0.45, y: 0.52, phase: .moved),
            TouchPoint(touchID: 3, x: 0.55, y: 0.52, phase: .moved)
        ], timestampNs: 416_000_000)
        #expect(dragMove.contains(.threeFingerDragBegan))
        #expect(dragMove.contains(where: { if case .threeFingerDragMoved = $0 { return true }; return false }))
        let dragEnd = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.35, y: 0.52, phase: .ended),
            TouchPoint(touchID: 2, x: 0.45, y: 0.52, phase: .ended),
            TouchPoint(touchID: 3, x: 0.55, y: 0.52, phase: .ended)
        ], timestampNs: 450_000_000)
        #expect(dragEnd.contains(.threeFingerDragEnded))

        // 4-finger swipe up -> Mission Control
        _ = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.2, y: 0.6, phase: .began),
            TouchPoint(touchID: 2, x: 0.35, y: 0.6, phase: .began),
            TouchPoint(touchID: 3, x: 0.5, y: 0.6, phase: .began),
            TouchPoint(touchID: 4, x: 0.65, y: 0.6, phase: .began)
        ], timestampNs: 600_000_000)
        let swipeUp = engine.process(points: [
            TouchPoint(touchID: 1, x: 0.2, y: 0.45, phase: .moved),
            TouchPoint(touchID: 2, x: 0.35, y: 0.45, phase: .moved),
            TouchPoint(touchID: 3, x: 0.5, y: 0.45, phase: .moved),
            TouchPoint(touchID: 4, x: 0.65, y: 0.45, phase: .moved)
        ], timestampNs: 630_000_000)
        #expect(swipeUp == [.fourFingerSwipe(.up)])
    }
}
