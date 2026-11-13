import Foundation
import Network

/// Active physical transport medium detected via `NWPath`.
public enum TransportMedium: String, Sendable, Equatable {
    case usbWired = "USB (유선)"
    case wifi = "Wi-Fi (무선)"
    case other = "네트워크"
    case disconnected = "연결 끊김"
}

/// Selectable client-side connection mode (Wi-Fi vs. USB Wired vs. Auto).
public enum ClientConnectionMode: String, Sendable, CaseIterable, Equatable, Identifiable {
    case auto = "자동 (USB 우선)"
    case wifi = "Wi-Fi (무선)"
    case usbWired = "USB 유선 연결"

    public var id: String { rawValue }
}

/// Selectable server-side interface listening preference.
public enum ServerInterfacePreference: String, Sendable, CaseIterable, Equatable, Identifiable {
    case all = "모든 인터페이스 수신"
    case usbOnly = "USB 유선 전용"
    case wifiOnly = "Wi-Fi 전용"

    public var id: String { rawValue }
}

/// Real-time telemetry shared with both iPad and macOS HUDs.
public struct TransportMetrics: Sendable, Equatable {
    public var rttMs: Double
    public var oneWayMs: Double
    public var packetsPerSecond: Double
    public var touchEventsPerSecond: Double
    public var compressionSavingsPercent: Double
    public var bytesPerSecond: Int
    public var medium: TransportMedium
    public var peerName: String
    public var activeEndpoint: String
    public var isUDPActive: Bool
    public var droppedPackets: UInt64

    public init(
        rttMs: Double = 0,
        oneWayMs: Double = 0,
        packetsPerSecond: Double = 0,
        touchEventsPerSecond: Double = 0,
        compressionSavingsPercent: Double = 0,
        bytesPerSecond: Int = 0,
        medium: TransportMedium = .disconnected,
        peerName: String = "",
        activeEndpoint: String = "",
        isUDPActive: Bool = false,
        droppedPackets: UInt64 = 0
    ) {
        self.rttMs = rttMs
        self.oneWayMs = oneWayMs
        self.packetsPerSecond = packetsPerSecond
        self.touchEventsPerSecond = touchEventsPerSecond
        self.compressionSavingsPercent = compressionSavingsPercent
        self.bytesPerSecond = bytesPerSecond
        self.medium = medium
        self.peerName = peerName
        self.activeEndpoint = activeEndpoint
        self.isUDPActive = isUDPActive
        self.droppedPackets = droppedPackets
    }
}

/// A discovered `TrackpadServer` advertised over Bonjour (`_virtualtrackpad._tcp`).
public struct DiscoveredServer: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public let isWiredCandidate: Bool

    public init(id: String, name: String, endpoint: NWEndpoint, isWiredCandidate: Bool) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isWiredCandidate = isWiredCandidate
    }
}

/// Helper builders for ultra-low-latency `NWParameters`.
public enum TrackpadNetworkParameters {
    public static func makeBrowserParameters(mode: ClientConnectionMode) -> NWParameters {
        let params = NWParameters()
        params.includePeerToPeer = true
        switch mode {
        case .auto:
            break
        case .wifi:
            params.requiredInterfaceType = .wifi
        case .usbWired:
            params.requiredInterfaceType = .wiredEthernet
        }
        return params
    }

    public static func makeControlTCPParameters(
        requiredInterfaceType: NWInterface.InterfaceType? = nil
    ) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle's algorithm (`TCP_NODELAY`)
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 1
        tcpOptions.keepaliveCount = 3

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        if let requiredInterfaceType {
            params.requiredInterfaceType = requiredInterfaceType
        }

        let framer = NWProtocolFramer.Options(definition: TrackpadPacketFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return params
    }

    public static func makeTouchUDPParameters(
        requiredInterface: NWInterface? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil
    ) -> NWParameters {
        let udpOptions = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udpOptions)
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        if let requiredInterface {
            params.requiredInterface = requiredInterface
        } else if let requiredInterfaceType {
            params.requiredInterfaceType = requiredInterfaceType
        }
        return params
    }

    public static func classifyMedium(from path: NWPath?) -> TransportMedium {
        guard let path, path.status == .satisfied else {
            return .disconnected
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return .usbWired
        }
        // On some macOS/iPadOS USB-NCM tethering configurations, the USB interface reports as `.other`
        // with an interface name such as `anpi*` or `en*` carrying link-local IPv6 (`fe80::`).
        if let iface = path.availableInterfaces.first {
            if iface.type == .wiredEthernet {
                return .usbWired
            }
            if iface.type == .other && (iface.name.hasPrefix("anpi") || iface.name.hasPrefix("en")) {
                return .usbWired
            }
            if iface.type == .wifi {
                return .wifi
            }
        }
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        return .other
    }

    public static func formatEndpoint(_ endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "" }
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, _, _, _):
            return name
        default:
            return "\(endpoint)"
        }
    }
}

// MARK: - Client Transport (iPadOS)

public enum ClientConnectionState: Sendable, Equatable {
    case idle
    case discovering
    case connecting(String)
    case connected(peerName: String, medium: TransportMedium)
    case failed(String)
}

/// Manages Bonjour discovery, TCP control (`TCP_NODELAY` + reliable gestures), UDP touch streaming, and RTT pings on iPadOS.
public final class TrackpadClientTransport: @unchecked Sendable {
    public var onServersChanged: (@Sendable ([DiscoveredServer]) -> Void)?
    public var onStateChanged: (@Sendable (ClientConnectionState) -> Void)?
    public var onMetricsUpdated: (@Sendable (TransportMetrics) -> Void)?
    public var onHapticCue: (@Sendable (HapticCuePayload) -> Void)?

    private let queue = DispatchQueue(label: "com.ipadtrackpad.client.network", qos: .userInteractive)
    private let localDeviceName: String

    private var connectionMode: ClientConnectionMode = .auto
    private var browser: NWBrowser?
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var pingTimer: DispatchSourceTimer?
    private var metricsTimer: DispatchSourceTimer?

    private var discoveredServers: [DiscoveredServer] = []
    private var currentMedium: TransportMedium = .disconnected
    private var connectedPeerName: String = ""
    private var activeEndpointString: String = ""
    private var isUDPReady = false

    // UDP congestion / burst guard so stale motion frames never queue-bloat the socket
    private var inFlightUDPSends: Int = 0
    private let maxInFlightUDPSends: Int = 3
    private var pendingMotionEncoded: Data?

    // Telemetry counters (protected by `queue`)
    private var pingSequence: UInt32 = 0
    private var smoothedRttMs: Double = 0
    private var packetsSentWindow: Int = 0
    private var bytesSentWindow: Int = 0
    private var touchEventsWindow: Int = 0
    private var droppedStaleSendWindow: UInt64 = 0
    private var lastTouchFramesEvaluated: UInt64 = 0
    private var lastSuppressedFrames: UInt64 = 0

    public init(localDeviceName: String) {
        self.localDeviceName = localDeviceName
    }

    public func setConnectionMode(_ mode: ClientConnectionMode) {
        queue.async { [weak self] in
            guard let self, self.connectionMode != mode else { return }
            self.connectionMode = mode
            self.disconnectInternal()
            self.startDiscoveryInternal()
        }
    }

    public func startDiscovery() {
        queue.async { [weak self] in
            self?.startDiscoveryInternal()
        }
    }

    public func stopDiscovery() {
        queue.async { [weak self] in
            self?.stopDiscoveryInternal()
        }
    }

    public func connect(to server: DiscoveredServer, aspectRatio: Float32) {
        queue.async { [weak self] in
            self?.connectInternal(to: server, aspectRatio: aspectRatio)
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.disconnectInternal()
            self?.notifyState(.discovering)
        }
    }

    /// Sends a pre-compressed `TouchPacket` immediately on the `.userInteractive` queue.
    /// Pure motion packets coalesce if UDP is temporarily backlogged; lifecycle frames (`began`/`ended`/`cancelled`) always send.
    public func sendTouchPacket(_ packet: TouchPacket, evaluatedFrames: UInt64, suppressedFrames: UInt64) {
        let encoded = PacketCodec.encodeTouchFrame(packet)
        let hasLifecycle = packet.points.contains {
            $0.phase == .began || $0.phase == .ended || $0.phase == .cancelled
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.lastTouchFramesEvaluated = evaluatedFrames
            self.lastSuppressedFrames = suppressedFrames
            self.touchEventsWindow += 1

            if self.isUDPReady, let udp = self.udpConnection {
                if self.inFlightUDPSends >= self.maxInFlightUDPSends && !hasLifecycle {
                    // Replace older queued motion frame so only the freshest cursor delta goes out next.
                    if self.pendingMotionEncoded != nil {
                        self.droppedStaleSendWindow &+= 1
                    }
                    self.pendingMotionEncoded = encoded
                    return
                }
                self.dispatchUDPSend(encoded, on: udp)
            } else if let tcp = self.tcpConnection, tcp.state == .ready {
                self.sendFramedTCP(encoded, on: tcp)
                self.packetsSentWindow += 1
                self.bytesSentWindow += encoded.count
            }
        }
    }

    /// Sends discrete 3-finger / 4-finger system gestures over the reliable TCP control stream (`TCP_NODELAY`).
    public func sendSystemGesture(_ action: SystemGestureAction) {
        let encoded = PacketCodec.encode(.systemGesture(action))
        queue.async { [weak self] in
            guard let self, let tcp = self.tcpConnection, tcp.state == .ready else { return }
            self.sendFramedTCP(encoded, on: tcp)
            self.packetsSentWindow += 1
            self.bytesSentWindow += encoded.count
        }
    }

    public func recordSuppressedFrame(evaluatedFrames: UInt64, suppressedFrames: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastTouchFramesEvaluated = evaluatedFrames
            self.lastSuppressedFrames = suppressedFrames
            self.touchEventsWindow += 1
        }
    }

    // MARK: - Internal Queue Methods

    private func startDiscoveryInternal() {
        stopDiscoveryInternal()

        let params = TrackpadNetworkParameters.makeBrowserParameters(mode: connectionMode)
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: TrackpadProtocol.bonjourServiceType,
            domain: "local."
        )
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.notifyState(.failed("검색 실패: \(error.localizedDescription)"))
            }
        }

        self.browser = browser
        self.notifyState(.discovering)
        browser.start(queue: self.queue)
    }

    private func stopDiscoveryInternal() {
        browser?.cancel()
        browser = nil
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var list: [DiscoveredServer] = []
        list.reserveCapacity(results.count)
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let isWired = result.interfaces.contains {
                $0.type == .wiredEthernet || ($0.type == .other && $0.name.hasPrefix("anpi"))
            }
            if connectionMode == .usbWired && !isWired {
                continue
            }
            list.append(DiscoveredServer(
                id: "\(name)-\(isWired ? "usb" : "net")",
                name: name,
                endpoint: result.endpoint,
                isWiredCandidate: isWired
            ))
        }
        list.sort { lhs, rhs in
            if lhs.isWiredCandidate != rhs.isWiredCandidate {
                return lhs.isWiredCandidate
            }
            return lhs.name < rhs.name
        }
        discoveredServers = list
        let callback = onServersChanged
        DispatchQueue.main.async {
            callback?(list)
        }
    }

    private func connectInternal(to server: DiscoveredServer, aspectRatio: Float32) {
        disconnectInternal()
        connectedPeerName = server.name
        notifyState(.connecting(server.name))

        let requiredType: NWInterface.InterfaceType? = switch connectionMode {
        case .auto: nil
        case .wifi: .wifi
        case .usbWired: .wiredEthernet
        }
        let tcpParams = TrackpadNetworkParameters.makeControlTCPParameters(requiredInterfaceType: requiredType)
        let connection = NWConnection(to: server.endpoint, using: tcpParams)
        tcpConnection = connection

        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let medium = TrackpadNetworkParameters.classifyMedium(from: path)
            let formatted = TrackpadNetworkParameters.formatEndpoint(path.remoteEndpoint)
            if !formatted.isEmpty {
                self.activeEndpointString = formatted
            }
            if medium != self.currentMedium {
                self.currentMedium = medium
                if !self.connectedPeerName.isEmpty && connection.state == .ready {
                    self.notifyState(.connected(peerName: self.connectedPeerName, medium: medium))
                }
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.currentMedium = TrackpadNetworkParameters.classifyMedium(from: connection.currentPath)
                self.activeEndpointString = TrackpadNetworkParameters.formatEndpoint(connection.currentPath?.remoteEndpoint)
                let handshake = HandshakePayload(aspectRatio: aspectRatio, deviceName: self.localDeviceName)
                self.sendFramedTCP(PacketCodec.encode(.handshake(handshake)), on: connection)
                self.receiveNextTCPMessage(on: connection)
                self.startTimers()
            case .failed(let error):
                self.disconnectInternal()
                self.notifyState(.failed(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func disconnectInternal() {
        pingTimer?.cancel()
        pingTimer = nil
        metricsTimer?.cancel()
        metricsTimer = nil

        udpConnection?.cancel()
        udpConnection = nil
        isUDPReady = false
        inFlightUDPSends = 0
        pendingMotionEncoded = nil

        tcpConnection?.cancel()
        tcpConnection = nil
        currentMedium = .disconnected
        connectedPeerName = ""
        activeEndpointString = ""
        smoothedRttMs = 0
    }

    private func dispatchUDPSend(_ data: Data, on udp: NWConnection) {
        inFlightUDPSends += 1
        packetsSentWindow += 1
        bytesSentWindow += data.count

        udp.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.inFlightUDPSends = max(0, self.inFlightUDPSends - 1)
                if let next = self.pendingMotionEncoded, self.isUDPReady, let activeUDP = self.udpConnection {
                    self.pendingMotionEncoded = nil
                    self.dispatchUDPSend(next, on: activeUDP)
                }
            }
        })
    }

    private func sendFramedTCP(_ data: Data, on connection: NWConnection) {
        let message = NWProtocolFramer.Message(definition: TrackpadPacketFramer.definition)
        let context = NWConnection.ContentContext(identifier: "TrackpadControl", metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveNextTCPMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.handleIncomingData(content)
            }
            if error == nil && connection.state == .ready {
                self.receiveNextTCPMessage(on: connection)
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        guard let packet = try? PacketCodec.decode(data) else { return }
        switch packet {
        case .handshakeAck(let ack):
            connectedPeerName = ack.deviceName.isEmpty ? connectedPeerName : ack.deviceName
            currentMedium = TrackpadNetworkParameters.classifyMedium(from: tcpConnection?.currentPath)
            activeEndpointString = TrackpadNetworkParameters.formatEndpoint(tcpConnection?.currentPath?.remoteEndpoint)
            notifyState(.connected(peerName: connectedPeerName, medium: currentMedium))
            if ack.udpPort > 0 {
                setupUDPStream(port: ack.udpPort)
            }
        case .pong(let heartbeat):
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= heartbeat.clientTimestampNs {
                let rttMs = Double(nowNs - heartbeat.clientTimestampNs) / 1_000_000.0
                smoothedRttMs = smoothedRttMs == 0 ? rttMs : (smoothedRttMs * 0.75 + rttMs * 0.25)
            }
        case .hapticCue(let cue):
            let callback = onHapticCue
            DispatchQueue.main.async {
                callback?(cue)
            }
        default:
            break
        }
    }

    private func setupUDPStream(port: UInt16) {
        guard let remoteEndpoint = tcpConnection?.currentPath?.remoteEndpoint,
              case let .hostPort(host, _) = remoteEndpoint,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            return
        }

        let requiredInterfaceType: NWInterface.InterfaceType? = switch connectionMode {
        case .auto: nil
        case .wifi: .wifi
        case .usbWired: .wiredEthernet
        }
        let wiredInterface = tcpConnection?.currentPath?.availableInterfaces.first {
            $0.type == .wiredEthernet || ($0.type == .other && $0.name.hasPrefix("anpi"))
        }
        let udpParams = TrackpadNetworkParameters.makeTouchUDPParameters(
            requiredInterface: wiredInterface,
            requiredInterfaceType: requiredInterfaceType
        )
        let udp = NWConnection(host: host, port: nwPort, using: udpParams)
        udpConnection = udp

        udp.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isUDPReady = true
                self.receiveNextUDP(on: udp)
            case .failed, .cancelled:
                self.isUDPReady = false
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    private func receiveNextUDP(on udp: NWConnection) {
        udp.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.handleIncomingData(content)
            }
            if error == nil && udp.state == .ready {
                self.receiveNextUDP(on: udp)
            }
        }
    }

    private func startTimers() {
        pingTimer?.cancel()
        let pTimer = DispatchSource.makeTimerSource(queue: queue)
        pTimer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
        pTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pingSequence &+= 1
            let ping = HeartbeatPayload(
                sequence: self.pingSequence,
                clientTimestampNs: DispatchTime.now().uptimeNanoseconds
            )
            let data = PacketCodec.encode(.ping(ping))
            if self.isUDPReady, let udp = self.udpConnection {
                udp.send(content: data, completion: .contentProcessed { _ in })
            } else if let tcp = self.tcpConnection, tcp.state == .ready {
                self.sendFramedTCP(data, on: tcp)
            }
        }
        pTimer.resume()
        pingTimer = pTimer

        metricsTimer?.cancel()
        let mTimer = DispatchSource.makeTimerSource(queue: queue)
        mTimer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(50))
        mTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let savings: Double
            if self.lastTouchFramesEvaluated > 0 {
                savings = (Double(self.lastSuppressedFrames) / Double(self.lastTouchFramesEvaluated)) * 100.0
            } else {
                savings = 0
            }
            let metrics = TransportMetrics(
                rttMs: self.smoothedRttMs,
                oneWayMs: self.smoothedRttMs * 0.5,
                packetsPerSecond: Double(self.packetsSentWindow),
                touchEventsPerSecond: Double(self.touchEventsWindow),
                compressionSavingsPercent: savings,
                bytesPerSecond: self.bytesSentWindow,
                medium: self.currentMedium,
                peerName: self.connectedPeerName,
                activeEndpoint: self.activeEndpointString,
                isUDPActive: self.isUDPReady,
                droppedPackets: self.droppedStaleSendWindow
            )
            self.packetsSentWindow = 0
            self.bytesSentWindow = 0
            self.touchEventsWindow = 0

            let callback = self.onMetricsUpdated
            DispatchQueue.main.async {
                callback?(metrics)
            }
        }
        mTimer.resume()
        metricsTimer = mTimer
    }

    private func notifyState(_ state: ClientConnectionState) {
        let callback = onStateChanged
        DispatchQueue.main.async {
            callback?(state)
        }
    }
}

// MARK: - Server Transport (macOS)

public enum ServerListenerState: Sendable, Equatable {
    case stopped
    case listening(port: UInt16, udpPort: UInt16)
    case connected(clientName: String, medium: TransportMedium)
    case failed(String)
}

/// Hosts the Bonjour `_virtualtrackpad._tcp` TCP control listener and an ephemeral UDP touch-stream listener.
public final class TrackpadServerTransport: @unchecked Sendable {
    public var onStateChanged: (@Sendable (ServerListenerState) -> Void)?
    public var onTouchPacket: (@Sendable (TouchPacket) -> Void)?
    public var onSystemGesture: (@Sendable (SystemGestureAction) -> Void)?
    public var onClientHandshake: (@Sendable (HandshakePayload) -> Void)?
    public var onMetricsUpdated: (@Sendable (TransportMetrics) -> Void)?

    private let queue = DispatchQueue(label: "com.ipadtrackpad.server.network", qos: .userInteractive)
    private let serverName: String

    private var interfacePreference: ServerInterfacePreference = .all
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var activeTCPClient: NWConnection?
    private var activeUDPPeer: NWConnection?
    private var metricsTimer: DispatchSourceTimer?

    private var tcpPort: UInt16 = 0
    private var udpPort: UInt16 = 0
    private var clientName: String = ""
    private var activeEndpointString: String = ""
    private var currentMedium: TransportMedium = .disconnected
    private var isUDPPeerConnected = false

    // Telemetry counters
    private var packetsReceivedWindow: Int = 0
    private var bytesReceivedWindow: Int = 0
    private var smoothedOneWayMs: Double = 0
    private var droppedOutOfOrderPackets: UInt64 = 0

    public init(serverName: String) {
        self.serverName = serverName
    }

    public func setInterfacePreference(_ preference: ServerInterfacePreference) {
        queue.async { [weak self] in
            guard let self, self.interfacePreference != preference else { return }
            self.interfacePreference = preference
            self.startInternal()
        }
    }

    public func start() {
        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    public func recordDroppedOutOfOrderPackets(_ count: UInt64) {
        queue.async { [weak self] in
            self?.droppedOutOfOrderPackets = count
        }
    }

    public func sendHapticCue(_ cue: HapticCuePayload) {
        let data = PacketCodec.encode(.hapticCue(cue))
        queue.async { [weak self] in
            guard let self, let tcp = self.activeTCPClient, tcp.state == .ready else { return }
            self.sendFramedTCP(data, on: tcp)
        }
    }

    // MARK: - Internal Queue Methods

    private func startInternal() {
        stopInternal()

        let requiredInterfaceType: NWInterface.InterfaceType? = switch interfacePreference {
        case .all: nil
        case .usbOnly: .wiredEthernet
        case .wifiOnly: .wifi
        }

        do {
            // 1. Start ephemeral UDP touch-stream listener first so we know its bound port.
            let udpParams = TrackpadNetworkParameters.makeTouchUDPParameters(requiredInterfaceType: requiredInterfaceType)
            let uListener = try NWListener(using: udpParams)
            uListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    self.udpPort = uListener.port?.rawValue ?? 0
                    if self.tcpPort > 0 {
                        self.notifyState(.listening(port: self.tcpPort, udpPort: self.udpPort))
                    }
                }
            }
            uListener.newConnectionHandler = { [weak self] udpConn in
                self?.acceptUDPPeer(udpConn)
            }
            udpListener = uListener
            uListener.start(queue: queue)

            // 2. Start TCP control listener advertised via Bonjour.
            let tcpParams = TrackpadNetworkParameters.makeControlTCPParameters(requiredInterfaceType: requiredInterfaceType)
            let tListener = try NWListener(using: tcpParams)
            tListener.service = NWListener.Service(
                name: serverName,
                type: TrackpadProtocol.bonjourServiceType,
                domain: "local."
            )
            tListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.tcpPort = tListener.port?.rawValue ?? 0
                    self.notifyState(.listening(port: self.tcpPort, udpPort: self.udpPort))
                case .failed(let error):
                    self.notifyState(.failed(error.localizedDescription))
                default:
                    break
                }
            }
            tListener.newConnectionHandler = { [weak self] tcpConn in
                self?.acceptTCPClient(tcpConn)
            }
            tcpListener = tListener
            tListener.start(queue: queue)

            startMetricsTimer()
        } catch {
            notifyState(.failed(error.localizedDescription))
        }
    }

    private func stopInternal() {
        metricsTimer?.cancel()
        metricsTimer = nil

        activeUDPPeer?.cancel()
        activeUDPPeer = nil
        activeTCPClient?.cancel()
        activeTCPClient = nil
        isUDPPeerConnected = false

        udpListener?.cancel()
        udpListener = nil
        tcpListener?.cancel()
        tcpListener = nil

        tcpPort = 0
        udpPort = 0
        clientName = ""
        activeEndpointString = ""
        currentMedium = .disconnected
        notifyState(.stopped)
    }

    private func acceptTCPClient(_ connection: NWConnection) {
        activeTCPClient?.cancel()
        activeUDPPeer?.cancel()
        activeUDPPeer = nil
        isUDPPeerConnected = false
        activeTCPClient = connection

        connection.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let medium = TrackpadNetworkParameters.classifyMedium(from: path)
            let remote = TrackpadNetworkParameters.formatEndpoint(path.remoteEndpoint)
            if !remote.isEmpty {
                self.activeEndpointString = "\(remote) (TCP:\(self.tcpPort) / UDP:\(self.udpPort))"
            }
            if medium != self.currentMedium {
                self.currentMedium = medium
                if !self.clientName.isEmpty && connection.state == .ready {
                    self.notifyState(.connected(clientName: self.clientName, medium: medium))
                }
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.currentMedium = TrackpadNetworkParameters.classifyMedium(from: connection.currentPath)
                let remote = TrackpadNetworkParameters.formatEndpoint(connection.currentPath?.remoteEndpoint)
                self.activeEndpointString = remote.isEmpty
                    ? "TCP:\(self.tcpPort) / UDP:\(self.udpPort)"
                    : "\(remote) (TCP:\(self.tcpPort) / UDP:\(self.udpPort))"
                self.receiveNextTCPMessage(on: connection)
            case .failed, .cancelled:
                if self.activeTCPClient === connection {
                    self.activeTCPClient = nil
                    self.activeUDPPeer?.cancel()
                    self.activeUDPPeer = nil
                    self.isUDPPeerConnected = false
                    self.clientName = ""
                    self.activeEndpointString = ""
                    self.currentMedium = .disconnected
                    self.notifyState(.listening(port: self.tcpPort, udpPort: self.udpPort))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func acceptUDPPeer(_ connection: NWConnection) {
        activeUDPPeer?.cancel()
        activeUDPPeer = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isUDPPeerConnected = true
                self.receiveNextUDPMessage(on: connection)
            case .failed, .cancelled:
                if self.activeUDPPeer === connection {
                    self.isUDPPeerConnected = false
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendFramedTCP(_ data: Data, on connection: NWConnection) {
        let message = NWProtocolFramer.Message(definition: TrackpadPacketFramer.definition)
        let context = NWConnection.ContentContext(identifier: "TrackpadControlAck", metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receiveNextTCPMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.handleIncomingData(content, viaUDP: false, replyConnection: connection)
            }
            if error == nil && connection.state == .ready {
                self.receiveNextTCPMessage(on: connection)
            }
        }
    }

    private func receiveNextUDPMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.handleIncomingData(content, viaUDP: true, replyConnection: connection)
            }
            if error == nil && connection.state == .ready {
                self.receiveNextUDPMessage(on: connection)
            }
        }
    }

    private func handleIncomingData(_ data: Data, viaUDP: Bool, replyConnection: NWConnection) {
        guard let packet = try? PacketCodec.decode(data) else { return }
        switch packet {
        case .handshake(let payload):
            clientName = payload.deviceName
            currentMedium = TrackpadNetworkParameters.classifyMedium(from: replyConnection.currentPath)
            let remote = TrackpadNetworkParameters.formatEndpoint(replyConnection.currentPath?.remoteEndpoint)
            activeEndpointString = remote.isEmpty
                ? "TCP:\(tcpPort) / UDP:\(udpPort)"
                : "\(remote) (TCP:\(tcpPort) / UDP:\(udpPort))"

            let ack = HandshakePayload(
                udpPort: udpPort,
                aspectRatio: 16.0 / 10.0,
                deviceName: serverName
            )
            sendFramedTCP(PacketCodec.encode(.handshakeAck(ack)), on: replyConnection)
            notifyState(.connected(clientName: clientName, medium: currentMedium))
            let callback = onClientHandshake
            DispatchQueue.main.async {
                callback?(payload)
            }

        case .touchFrame(let frame):
            packetsReceivedWindow += 1
            bytesReceivedWindow += data.count
            onTouchPacket?(frame)

        case .systemGesture(let action):
            packetsReceivedWindow += 1
            bytesReceivedWindow += data.count
            onSystemGesture?(action)

        case .ping(let heartbeat):
            let pong = HeartbeatPayload(
                sequence: heartbeat.sequence,
                clientTimestampNs: heartbeat.clientTimestampNs,
                serverTimestampNs: DispatchTime.now().uptimeNanoseconds
            )
            let encoded = PacketCodec.encode(.pong(pong))
            if viaUDP {
                replyConnection.send(content: encoded, completion: .contentProcessed { _ in })
            } else {
                sendFramedTCP(encoded, on: replyConnection)
            }

        default:
            break
        }
    }

    private func startMetricsTimer() {
        metricsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let metrics = TransportMetrics(
                rttMs: self.smoothedOneWayMs * 2.0,
                oneWayMs: self.smoothedOneWayMs,
                packetsPerSecond: Double(self.packetsReceivedWindow),
                touchEventsPerSecond: Double(self.packetsReceivedWindow),
                compressionSavingsPercent: 0,
                bytesPerSecond: self.bytesReceivedWindow,
                medium: self.currentMedium,
                peerName: self.clientName,
                activeEndpoint: self.activeEndpointString,
                isUDPActive: self.isUDPPeerConnected,
                droppedPackets: self.droppedOutOfOrderPackets
            )
            self.packetsReceivedWindow = 0
            self.bytesReceivedWindow = 0

            let callback = self.onMetricsUpdated
            DispatchQueue.main.async {
                callback?(metrics)
            }
        }
        timer.resume()
        metricsTimer = timer
    }

    private func notifyState(_ state: ServerListenerState) {
        let callback = onStateChanged
        DispatchQueue.main.async {
            callback?(state)
        }
    }
}
