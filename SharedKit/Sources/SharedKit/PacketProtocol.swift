import Foundation
import Network

/// Constants shared across the wired (USB) and wireless (Wi-Fi) virtual trackpad protocol.
public enum TrackpadProtocol {
    public static let bonjourServiceType = "_virtualtrackpad._tcp"
    public static let magic: UInt16 = 0x5450 // "TP"
    public static let version: UInt8 = 1
    public static let headerSize = 8
    public static let touchPointByteSize = 16
    public static let touchFrameSubheaderSize = 14 // frameIndex (4) + timestampNs (8) + flags (1) + touchCount (1)
    public static let maxTouchesPerFrame = 16
    public static let maxPacketBodyLength = 4096
}

/// Discriminator byte identifying each binary frame on the wire.
public enum PacketType: UInt8, Sendable, Equatable {
    case handshake = 0x01
    case handshakeAck = 0x02
    case touchFrame = 0x03
    case ping = 0x04
    case pong = 0x05
    case hapticCue = 0x06
    case systemGesture = 0x07
}

/// System-level macOS shortcut action triggered by 3-finger or 4-finger swipes.
public enum SystemGestureAction: UInt8, Codable, Sendable, Equatable {
    case missionControl = 0x01
    case appExpose      = 0x02
    case spaceLeft      = 0x03
    case spaceRight     = 0x04
}

/// Compact touch phase mirroring `UITouch.Phase` without UIKit coupling.
public enum TouchPhase: UInt8, Sendable, Equatable {
    case began = 0
    case moved = 1
    case stationary = 2
    case ended = 3
    case cancelled = 4
}

/// Bitflags carried on each individual `TouchPoint`.
public struct TouchPointFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let isPredicted = TouchPointFlags(rawValue: 1 << 0)
    public static let isPalmCandidate = TouchPointFlags(rawValue: 1 << 1)
    public static let isStylus = TouchPointFlags(rawValue: 1 << 2)
}

/// Bitflags carried on each `TouchPacket` frame.
public struct TouchFrameFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Frame contains only changed/updated points rather than the full active touch set.
    public static let isDelta = TouchFrameFlags(rawValue: 1 << 0)
    /// Frame contains the complete snapshot of all currently active touches.
    public static let isKeyframe = TouchFrameFlags(rawValue: 1 << 1)
}

/// Fixed 16-byte wire representation of a single finger contact.
/// Coordinates are normalized to `[0.0, 1.0]` across the iPad trackpad surface.
public struct TouchPoint: Sendable, Equatable {
    public var touchID: UInt32
    public var x: Float32
    public var y: Float32
    public var phase: TouchPhase
    public var flags: TouchPointFlags
    /// Quantized touch contact radius in hundredths of a millimeter (`radiusPt * 100`, clamped to `UInt16`).
    public var majorRadius: UInt16

    public init(
        touchID: UInt32,
        x: Float32,
        y: Float32,
        phase: TouchPhase,
        flags: TouchPointFlags = [],
        majorRadius: UInt16 = 0
    ) {
        self.touchID = touchID
        self.x = x
        self.y = y
        self.phase = phase
        self.flags = flags
        self.majorRadius = majorRadius
    }
}

/// A complete multitouch frame transmitted from `TrackpadClient` to `TrackpadServer`.
public struct TouchPacket: Sendable, Equatable {
    public var frameIndex: UInt32
    public var timestampNs: UInt64
    public var flags: TouchFrameFlags
    public var points: [TouchPoint]

    public init(
        frameIndex: UInt32,
        timestampNs: UInt64,
        flags: TouchFrameFlags = .isKeyframe,
        points: [TouchPoint]
    ) {
        self.frameIndex = frameIndex
        self.timestampNs = timestampNs
        self.flags = flags
        self.points = points
    }
}

/// Control-channel handshake exchanged immediately after TCP connection establishment.
public struct HandshakePayload: Sendable, Equatable {
    public struct Capabilities: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let udpTouchStream = Capabilities(rawValue: 1 << 0)
        public static let deltaCompression = Capabilities(rawValue: 1 << 1)
        public static let hapticFeedback = Capabilities(rawValue: 1 << 2)
        public static let proMotion120Hz = Capabilities(rawValue: 1 << 3)
    }

    public var protocolVersion: UInt8
    public var capabilities: Capabilities
    /// For `handshakeAck` (server -> client): the UDP port listening for touch datagrams (`0` if TCP-only).
    public var udpPort: UInt16
    /// Aspect ratio (`width / height`) of the sender's trackpad surface or host screen.
    public var aspectRatio: Float32
    public var deviceName: String

    public init(
        protocolVersion: UInt8 = TrackpadProtocol.version,
        capabilities: Capabilities = [.udpTouchStream, .deltaCompression, .hapticFeedback, .proMotion120Hz],
        udpPort: UInt16 = 0,
        aspectRatio: Float32 = 4.0 / 3.0,
        deviceName: String
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.udpPort = udpPort
        self.aspectRatio = aspectRatio
        self.deviceName = deviceName
    }
}

/// Ping / Pong packet used to measure RTT and one-way latency across the active transport.
public struct HeartbeatPayload: Sendable, Equatable {
    public var sequence: UInt32
    public var clientTimestampNs: UInt64
    public var serverTimestampNs: UInt64

    public init(sequence: UInt32, clientTimestampNs: UInt64, serverTimestampNs: UInt64 = 0) {
        self.sequence = sequence
        self.clientTimestampNs = clientTimestampNs
        self.serverTimestampNs = serverTimestampNs
    }
}

/// Optional server -> client haptic feedback trigger.
public struct HapticCuePayload: Sendable, Equatable {
    public enum Style: UInt8, Sendable, Equatable {
        case click = 0
        case gestureThreshold = 1
        case secondaryClick = 2
    }

    public var style: Style
    public var intensity: Float32

    public init(style: Style, intensity: Float32 = 0.8) {
        self.style = style
        self.intensity = intensity
    }
}

/// Decoded wire packet.
public enum DecodedPacket: Sendable, Equatable {
    case handshake(HandshakePayload)
    case handshakeAck(HandshakePayload)
    case touchFrame(TouchPacket)
    case ping(HeartbeatPayload)
    case pong(HeartbeatPayload)
    case hapticCue(HapticCuePayload)
    case systemGesture(SystemGestureAction)
}

public enum PacketCodecError: Error, Sendable, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownPacketType(UInt8)
    case truncatedData
    case invalidPayloadLength
    case invalidUTF8
}

/// Zero-Codable, endian-safe binary encoder and decoder operating directly on byte buffers.
///
/// Common 8-byte wire header layout (little-endian):
/// ```
/// [0..1] magic: UInt16 (0x5450)
/// [2]    version: UInt8 (1)
/// [3]    type: UInt8 (PacketType)
/// [4..5] bodyLength: UInt16
/// [6..7] reserved: UInt16 (0)
/// ```
public enum PacketCodec {
    public static func encode(_ packet: DecodedPacket) -> Data {
        switch packet {
        case .handshake(let payload):
            return encodeHandshake(payload, type: .handshake)
        case .handshakeAck(let payload):
            return encodeHandshake(payload, type: .handshakeAck)
        case .touchFrame(let frame):
            return encodeTouchFrame(frame)
        case .ping(let heartbeat):
            return encodeHeartbeat(heartbeat, type: .ping)
        case .pong(let heartbeat):
            return encodeHeartbeat(heartbeat, type: .pong)
        case .hapticCue(let cue):
            return encodeHapticCue(cue)
        case .systemGesture(let action):
            return encodeSystemGesture(action)
        }
    }

    /// Encodes a `TouchPacket` directly into a caller-owned `Data` capacity to minimize allocations.
    public static func encodeTouchFrame(_ frame: TouchPacket) -> Data {
        let count = min(frame.points.count, TrackpadProtocol.maxTouchesPerFrame)
        let bodyLength = TrackpadProtocol.touchFrameSubheaderSize + count * TrackpadProtocol.touchPointByteSize
        let totalLength = TrackpadProtocol.headerSize + bodyLength

        var data = Data(count: totalLength)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            writeHeader(to: base, type: .touchFrame, bodyLength: UInt16(bodyLength))

            let body = base.advanced(by: TrackpadProtocol.headerSize)
            storeUInt32(frame.frameIndex, at: body, offset: 0)
            storeUInt64(frame.timestampNs, at: body, offset: 4)
            body.storeBytes(of: frame.flags.rawValue, toByteOffset: 12, as: UInt8.self)
            body.storeBytes(of: UInt8(count), toByteOffset: 13, as: UInt8.self)

            for idx in 0..<count {
                let point = frame.points[idx]
                let pointBase = body.advanced(by: TrackpadProtocol.touchFrameSubheaderSize + idx * TrackpadProtocol.touchPointByteSize)
                storeUInt32(point.touchID, at: pointBase, offset: 0)
                storeUInt32(point.x.bitPattern, at: pointBase, offset: 4)
                storeUInt32(point.y.bitPattern, at: pointBase, offset: 8)
                pointBase.storeBytes(of: point.phase.rawValue, toByteOffset: 12, as: UInt8.self)
                pointBase.storeBytes(of: point.flags.rawValue, toByteOffset: 13, as: UInt8.self)
                storeUInt16(point.majorRadius, at: pointBase, offset: 14)
            }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> DecodedPacket {
        try data.withUnsafeBytes { rawBuffer in
            try decode(rawBuffer)
        }
    }

    public static func decode(_ rawBuffer: UnsafeRawBufferPointer) throws -> DecodedPacket {
        guard rawBuffer.count >= TrackpadProtocol.headerSize, let base = rawBuffer.baseAddress else {
            throw PacketCodecError.truncatedData
        }

        let magic = loadUInt16(from: base, offset: 0)
        guard magic == TrackpadProtocol.magic else {
            throw PacketCodecError.invalidMagic
        }

        let version = base.load(fromByteOffset: 2, as: UInt8.self)
        guard version == TrackpadProtocol.version else {
            throw PacketCodecError.unsupportedVersion(version)
        }

        let rawType = base.load(fromByteOffset: 3, as: UInt8.self)
        guard let packetType = PacketType(rawValue: rawType) else {
            throw PacketCodecError.unknownPacketType(rawType)
        }

        let bodyLength = Int(loadUInt16(from: base, offset: 4))
        guard bodyLength <= TrackpadProtocol.maxPacketBodyLength else {
            throw PacketCodecError.invalidPayloadLength
        }
        guard rawBuffer.count >= TrackpadProtocol.headerSize + bodyLength else {
            throw PacketCodecError.truncatedData
        }

        let body = UnsafeRawBufferPointer(
            start: base.advanced(by: TrackpadProtocol.headerSize),
            count: bodyLength
        )

        switch packetType {
        case .handshake:
            return .handshake(try decodeHandshake(body))
        case .handshakeAck:
            return .handshakeAck(try decodeHandshake(body))
        case .touchFrame:
            return .touchFrame(try decodeTouchFrame(body))
        case .ping:
            return .ping(try decodeHeartbeat(body))
        case .pong:
            return .pong(try decodeHeartbeat(body))
        case .hapticCue:
            return .hapticCue(try decodeHapticCue(body))
        case .systemGesture:
            return .systemGesture(try decodeSystemGesture(body))
        }
    }

    // MARK: - Private Encoders

    private static func encodeHandshake(_ payload: HandshakePayload, type: PacketType) -> Data {
        let nameBytes = Data(payload.deviceName.utf8.prefix(255))
        // version(1) + capabilities(2) + udpPort(2) + aspectRatio(4) + nameLen(1) + nameBytes
        let bodyLength = 10 + nameBytes.count
        var data = Data(count: TrackpadProtocol.headerSize + bodyLength)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            writeHeader(to: base, type: type, bodyLength: UInt16(bodyLength))
            let body = base.advanced(by: TrackpadProtocol.headerSize)
            body.storeBytes(of: payload.protocolVersion, toByteOffset: 0, as: UInt8.self)
            storeUInt16(payload.capabilities.rawValue, at: body, offset: 1)
            storeUInt16(payload.udpPort, at: body, offset: 3)
            storeUInt32(payload.aspectRatio.bitPattern, at: body, offset: 5)
            body.storeBytes(of: UInt8(nameBytes.count), toByteOffset: 9, as: UInt8.self)
            if !nameBytes.isEmpty {
                nameBytes.withUnsafeBytes { nameRaw in
                    if let nameSrc = nameRaw.baseAddress {
                        body.advanced(by: 10).copyMemory(from: nameSrc, byteCount: nameBytes.count)
                    }
                }
            }
        }
        return data
    }

    private static func encodeHeartbeat(_ payload: HeartbeatPayload, type: PacketType) -> Data {
        let bodyLength = 20 // sequence(4) + clientTs(8) + serverTs(8)
        var data = Data(count: TrackpadProtocol.headerSize + bodyLength)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            writeHeader(to: base, type: type, bodyLength: UInt16(bodyLength))
            let body = base.advanced(by: TrackpadProtocol.headerSize)
            storeUInt32(payload.sequence, at: body, offset: 0)
            storeUInt64(payload.clientTimestampNs, at: body, offset: 4)
            storeUInt64(payload.serverTimestampNs, at: body, offset: 12)
        }
        return data
    }

    private static func encodeHapticCue(_ payload: HapticCuePayload) -> Data {
        let bodyLength = 5 // style(1) + intensity(4)
        var data = Data(count: TrackpadProtocol.headerSize + bodyLength)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            writeHeader(to: base, type: .hapticCue, bodyLength: UInt16(bodyLength))
            let body = base.advanced(by: TrackpadProtocol.headerSize)
            body.storeBytes(of: payload.style.rawValue, toByteOffset: 0, as: UInt8.self)
            storeUInt32(payload.intensity.bitPattern, at: body, offset: 1)
        }
        return data
    }

    private static func encodeSystemGesture(_ action: SystemGestureAction) -> Data {
        let bodyLength = 1
        var data = Data(count: TrackpadProtocol.headerSize + bodyLength)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            writeHeader(to: base, type: .systemGesture, bodyLength: UInt16(bodyLength))
            let body = base.advanced(by: TrackpadProtocol.headerSize)
            body.storeBytes(of: action.rawValue, toByteOffset: 0, as: UInt8.self)
        }
        return data
    }

    // MARK: - Private Decoders

    private static func decodeHandshake(_ body: UnsafeRawBufferPointer) throws -> HandshakePayload {
        guard body.count >= 10, let base = body.baseAddress else {
            throw PacketCodecError.truncatedData
        }
        let protocolVersion = base.load(fromByteOffset: 0, as: UInt8.self)
        let capabilities = HandshakePayload.Capabilities(rawValue: loadUInt16(from: base, offset: 1))
        let udpPort = loadUInt16(from: base, offset: 3)
        let aspectRatio = Float32(bitPattern: loadUInt32(from: base, offset: 5))
        let nameLen = Int(base.load(fromByteOffset: 9, as: UInt8.self))
        guard body.count >= 10 + nameLen else {
            throw PacketCodecError.truncatedData
        }
        let nameData = Data(bytes: base.advanced(by: 10), count: nameLen)
        guard let deviceName = String(data: nameData, encoding: .utf8) else {
            throw PacketCodecError.invalidUTF8
        }
        return HandshakePayload(
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            udpPort: udpPort,
            aspectRatio: aspectRatio,
            deviceName: deviceName
        )
    }

    private static func decodeTouchFrame(_ body: UnsafeRawBufferPointer) throws -> TouchPacket {
        guard body.count >= TrackpadProtocol.touchFrameSubheaderSize, let base = body.baseAddress else {
            throw PacketCodecError.truncatedData
        }
        let frameIndex = loadUInt32(from: base, offset: 0)
        let timestampNs = loadUInt64(from: base, offset: 4)
        let flags = TouchFrameFlags(rawValue: base.load(fromByteOffset: 12, as: UInt8.self))
        let touchCount = Int(base.load(fromByteOffset: 13, as: UInt8.self))

        guard touchCount <= TrackpadProtocol.maxTouchesPerFrame else {
            throw PacketCodecError.invalidPayloadLength
        }
        let expectedBytes = TrackpadProtocol.touchFrameSubheaderSize + touchCount * TrackpadProtocol.touchPointByteSize
        guard body.count >= expectedBytes else {
            throw PacketCodecError.truncatedData
        }

        var points: [TouchPoint] = []
        points.reserveCapacity(touchCount)
        for idx in 0..<touchCount {
            let pointBase = base.advanced(by: TrackpadProtocol.touchFrameSubheaderSize + idx * TrackpadProtocol.touchPointByteSize)
            let touchID = loadUInt32(from: pointBase, offset: 0)
            let x = Float32(bitPattern: loadUInt32(from: pointBase, offset: 4))
            let y = Float32(bitPattern: loadUInt32(from: pointBase, offset: 8))
            let rawPhase = pointBase.load(fromByteOffset: 12, as: UInt8.self)
            let phase = TouchPhase(rawValue: rawPhase) ?? .moved
            let pFlags = TouchPointFlags(rawValue: pointBase.load(fromByteOffset: 13, as: UInt8.self))
            let radius = loadUInt16(from: pointBase, offset: 14)

            points.append(TouchPoint(
                touchID: touchID,
                x: x,
                y: y,
                phase: phase,
                flags: pFlags,
                majorRadius: radius
            ))
        }

        return TouchPacket(
            frameIndex: frameIndex,
            timestampNs: timestampNs,
            flags: flags,
            points: points
        )
    }

    private static func decodeHeartbeat(_ body: UnsafeRawBufferPointer) throws -> HeartbeatPayload {
        guard body.count >= 20, let base = body.baseAddress else {
            throw PacketCodecError.truncatedData
        }
        return HeartbeatPayload(
            sequence: loadUInt32(from: base, offset: 0),
            clientTimestampNs: loadUInt64(from: base, offset: 4),
            serverTimestampNs: loadUInt64(from: base, offset: 12)
        )
    }

    private static func decodeHapticCue(_ body: UnsafeRawBufferPointer) throws -> HapticCuePayload {
        guard body.count >= 5, let base = body.baseAddress else {
            throw PacketCodecError.truncatedData
        }
        let style = HapticCuePayload.Style(rawValue: base.load(fromByteOffset: 0, as: UInt8.self)) ?? .click
        let intensity = Float32(bitPattern: loadUInt32(from: base, offset: 1))
        return HapticCuePayload(style: style, intensity: intensity)
    }

    private static func decodeSystemGesture(_ body: UnsafeRawBufferPointer) throws -> SystemGestureAction {
        guard body.count >= 1, let base = body.baseAddress else {
            throw PacketCodecError.truncatedData
        }
        let raw = base.load(fromByteOffset: 0, as: UInt8.self)
        guard let action = SystemGestureAction(rawValue: raw) else {
            throw PacketCodecError.unknownPacketType(raw)
        }
        return action
    }

    // MARK: - Unaligned Little-Endian Helpers

    @inline(__always)
    private static func writeHeader(to base: UnsafeMutableRawPointer, type: PacketType, bodyLength: UInt16) {
        storeUInt16(TrackpadProtocol.magic, at: base, offset: 0)
        base.storeBytes(of: TrackpadProtocol.version, toByteOffset: 2, as: UInt8.self)
        base.storeBytes(of: type.rawValue, toByteOffset: 3, as: UInt8.self)
        storeUInt16(bodyLength, at: base, offset: 4)
        storeUInt16(0, at: base, offset: 6)
    }

    @inline(__always)
    private static func storeUInt16(_ value: UInt16, at base: UnsafeMutableRawPointer, offset: Int) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            base.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: 2)
        }
    }

    @inline(__always)
    private static func storeUInt32(_ value: UInt32, at base: UnsafeMutableRawPointer, offset: Int) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            base.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: 4)
        }
    }

    @inline(__always)
    private static func storeUInt64(_ value: UInt64, at base: UnsafeMutableRawPointer, offset: Int) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            base.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: 8)
        }
    }

    @inline(__always)
    private static func loadUInt16(from base: UnsafeRawPointer, offset: Int) -> UInt16 {
        var val: UInt16 = 0
        withUnsafeMutableBytes(of: &val) { dst in
            dst.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: 2)
        }
        return UInt16(littleEndian: val)
    }

    @inline(__always)
    private static func loadUInt32(from base: UnsafeRawPointer, offset: Int) -> UInt32 {
        var val: UInt32 = 0
        withUnsafeMutableBytes(of: &val) { dst in
            dst.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: 4)
        }
        return UInt32(littleEndian: val)
    }

    @inline(__always)
    private static func loadUInt64(from base: UnsafeRawPointer, offset: Int) -> UInt64 {
        var val: UInt64 = 0
        withUnsafeMutableBytes(of: &val) { dst in
            dst.baseAddress!.copyMemory(from: base.advanced(by: offset), byteCount: 8)
        }
        return UInt64(littleEndian: val)
    }
}

// MARK: - Network.framework TCP Packet Framer

/// Zero-copy `NWProtocolFramerImplementation` that frames the 8-byte `PacketCodec` header
/// so TCP control and fallback touch messages arrive as exact, atomic datagrams.
public final class TrackpadPacketFramer: NWProtocolFramerImplementation {
    public static let definition = NWProtocolFramer.Definition(implementation: TrackpadPacketFramer.self)
    public static var label: String { "TrackpadPacketFramer" }

    public init(framer: NWProtocolFramer.Instance) {}

    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    public func wakeup(framer: NWProtocolFramer.Instance) {}

    public func stop(framer: NWProtocolFramer.Instance) -> Bool {
        true
    }

    public func cleanup(framer: NWProtocolFramer.Instance) {}

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsedBodyLength: Int = 0
            var parsedValidHeader = false

            let headerParsed = framer.parseInput(
                minimumIncompleteLength: TrackpadProtocol.headerSize,
                maximumLength: TrackpadProtocol.headerSize
            ) { buffer, _ in
                guard let buffer, buffer.count >= TrackpadProtocol.headerSize, let base = buffer.baseAddress else {
                    return 0
                }
                let b0 = UInt16(base.load(fromByteOffset: 0, as: UInt8.self))
                let b1 = UInt16(base.load(fromByteOffset: 1, as: UInt8.self))
                let magic = b0 | (b1 << 8)
                guard magic == TrackpadProtocol.magic else {
                    return 0
                }
                let l0 = Int(base.load(fromByteOffset: 4, as: UInt8.self))
                let l1 = Int(base.load(fromByteOffset: 5, as: UInt8.self))
                parsedBodyLength = l0 | (l1 << 8)
                parsedValidHeader = parsedBodyLength <= TrackpadProtocol.maxPacketBodyLength
                return 0 // Keep the 8-byte header intact for PacketCodec.decode
            }

            if !headerParsed {
                return TrackpadProtocol.headerSize
            }
            if !parsedValidHeader {
                framer.markFailed(error: .posix(.EBADMSG))
                return 0
            }

            let totalLength = TrackpadProtocol.headerSize + parsedBodyLength
            let message = NWProtocolFramer.Message(definition: Self.definition)
            if !framer.deliverInputNoCopy(length: totalLength, message: message, isComplete: true) {
                return totalLength
            }
        }
    }

    public func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
}
