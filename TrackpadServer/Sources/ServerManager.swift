import AppKit
import Darwin
import Foundation
import Observation
import os
import SharedKit

/// Lock-protected hot-path pipeline converting incoming binary `TouchPacket`s and `SystemGestureAction`s
/// into `CGEvent`s directly on the `.userInteractive` queue with zero MainActor hops.
final class ServerTouchPipeline: @unchecked Sendable {
    private struct State {
        var reconstructor = TouchDeltaReconstructor()
        let gestureEngine = GestureStateMachine()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    let eventDriver = SyntheticEventDriver()

    func reset() {
        lock.withLock { state in
            state.reconstructor.reset()
            state.gestureEngine.reset()
        }
    }

    func updateGestureConfig(_ block: @Sendable (inout GestureConfig) -> Void) {
        lock.withLock { state in
            block(&state.gestureEngine.config)
        }
    }

    func handleIncomingPacket(_ packet: TouchPacket, transport: TrackpadServerTransport) {
        let result: (actions: [GestureAction], droppedCount: UInt64, wasDropped: Bool) = lock.withLock { state in
            guard let points = state.reconstructor.apply(packet) else {
                return ([], state.reconstructor.droppedOutOfOrderCount, true)
            }
            let actions = state.gestureEngine.process(points: points, timestampNs: packet.timestampNs)
            return (actions, state.reconstructor.droppedOutOfOrderCount, false)
        }

        if result.wasDropped {
            transport.recordDroppedOutOfOrderPackets(result.droppedCount)
            return
        }
        if !result.actions.isEmpty {
            eventDriver.apply(result.actions)
        }
    }

    func handleSystemGesture(_ action: SystemGestureAction) {
        eventDriver.executeSystemGesture(action)
    }
}

@Observable
@MainActor
final class ServerManager {
    var listenerState: ServerListenerState = .stopped
    var metrics: TransportMetrics = TransportMetrics()
    var isAccessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    var localHostIPs: String = ServerManager.resolveLocalIPSummary()

    // User preferences
    var interfacePreference: ServerInterfacePreference = .all {
        didSet {
            guard interfacePreference != oldValue else { return }
            pipeline.reset()
            transport.setInterfacePreference(interfacePreference)
            localHostIPs = Self.resolveLocalIPSummary()
        }
    }
    var sensitivity: Double = 1.65 {
        didSet {
            let value = sensitivity
            pipeline.eventDriver.updateConfiguration { $0.sensitivity = value }
        }
    }
    var scrollSpeed: Double = 1.25 {
        didSet {
            let value = scrollSpeed
            pipeline.eventDriver.updateConfiguration { $0.scrollSpeed = value }
        }
    }
    var tapToClickEnabled: Bool = true {
        didSet {
            let value = tapToClickEnabled
            pipeline.updateGestureConfig { $0.tapToClickEnabled = value }
        }
    }
    var threeFingerDragEnabled: Bool = false {
        didSet {
            let value = threeFingerDragEnabled
            pipeline.updateGestureConfig { $0.threeFingerDragEnabled = value }
        }
    }
    var naturalScrolling: Bool = true {
        didSet {
            let value = naturalScrolling
            pipeline.updateGestureConfig { $0.naturalScrolling = value }
        }
    }

    let transport: TrackpadServerTransport
    let pipeline = ServerTouchPipeline()

    private var accessibilityPollTask: Task<Void, Never>?

    init() {
        let hostName = Host.current().localizedName ?? "Mac"
        self.transport = TrackpadServerTransport(serverName: hostName)
        wireTransport()
    }

    func start() {
        isAccessibilityTrusted = AccessibilityHelper.checkAndPromptIfNeeded(prompt: true)
        localHostIPs = Self.resolveLocalIPSummary()
        startAccessibilityPolling()
        transport.setInterfacePreference(interfacePreference)
        transport.start()
    }

    func stop() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        transport.stop()
        pipeline.reset()
    }

    func requestAccessibilityPermission() {
        isAccessibilityTrusted = AccessibilityHelper.checkAndPromptIfNeeded(prompt: true)
        if !isAccessibilityTrusted {
            AccessibilityHelper.openAccessibilitySettings()
        }
    }

    var menuBarIconName: String {
        switch listenerState {
        case .connected(_, .usbWired):
            return "cable.connector"
        case .connected:
            return "ipad.and.arrow.forward"
        case .listening:
            return "rectangle.and.hand.point.up.left"
        case .stopped, .failed:
            return "rectangle.and.hand.point.up.left.filled"
        }
    }

    var connectionBadgeText: String {
        switch listenerState {
        case .stopped:
            return "연결 상태: 중지됨"
        case .listening:
            return "연결 상태: 대기 중 (\(interfacePreference.rawValue))"
        case .connected(let clientName, let medium):
            return "연결 상태: \(medium.rawValue) • \(clientName)"
        case .failed(let message):
            return "연결 오류: \(message)"
        }
    }

    var endpointDetailText: String {
        switch listenerState {
        case .connected:
            return metrics.activeEndpoint.isEmpty ? localHostIPs : metrics.activeEndpoint
        case .listening(let tcpPort, let udpPort):
            let host = localHostIPs.isEmpty ? "local" : localHostIPs
            return "\(host) • TCP :\(tcpPort) / UDP :\(udpPort)"
        case .stopped:
            return "수신 대기 안 함"
        case .failed(let msg):
            return msg
        }
    }

    private func wireTransport() {
        transport.onTouchPacket = { [pipeline, transport] packet in
            pipeline.handleIncomingPacket(packet, transport: transport)
        }

        transport.onSystemGesture = { [pipeline] action in
            pipeline.handleSystemGesture(action)
        }

        transport.onClientHandshake = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pipeline.reset()
            }
        }

        transport.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.listenerState = state
                self.localHostIPs = Self.resolveLocalIPSummary()
                if case .listening = state {
                    self.pipeline.reset()
                }
            }
        }

        transport.onMetricsUpdated = { [weak self] metrics in
            Task { @MainActor [weak self] in
                self?.metrics = metrics
            }
        }
    }

    private func startAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                let trusted = AccessibilityHelper.isTrusted()
                if trusted != self.isAccessibilityTrusted {
                    self.isAccessibilityTrusted = trusted
                }
            }
        }
    }

    private static func resolveLocalIPSummary() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return ""
        }
        defer { freeifaddrs(ifaddr) }

        var ipv4List: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            if isUp, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        ipv4List.append("\(ip) (\(name))")
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return ipv4List.first ?? ""
    }
}
