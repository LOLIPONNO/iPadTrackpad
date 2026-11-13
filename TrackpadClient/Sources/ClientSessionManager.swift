import Foundation
import Observation
import os
import SharedKit
import UIKit

/// Lock-protected hot-path pipeline bridging UIKit touch delivery to `TrackpadClientTransport`
/// without triggering SwiftUI `@Observable` state invalidation on every 120Hz frame.
final class ClientTouchPipeline: @unchecked Sendable {
    private let transport: TrackpadClientTransport
    private let lock = OSAllocatedUnfairLock(initialState: TouchDeltaCompressor())

    init(transport: TrackpadClientTransport) {
        self.transport = transport
    }

    func reset() {
        lock.withLock { compressor in
            compressor.reset()
        }
    }

    func submit(points: [TouchPoint], timestampNs: UInt64) {
        let result: (packet: TouchPacket?, evaluated: UInt64, suppressed: UInt64) = lock.withLock { compressor in
            let pkt = compressor.compress(points: points, timestampNs: timestampNs)
            return (pkt, compressor.totalFramesEvaluated, compressor.suppressedFrames)
        }

        if let packet = result.packet {
            transport.sendTouchPacket(
                packet,
                evaluatedFrames: result.evaluated,
                suppressedFrames: result.suppressed
            )
        } else {
            transport.recordSuppressedFrame(
                evaluatedFrames: result.evaluated,
                suppressedFrames: result.suppressed
            )
        }
    }
}

@Observable
@MainActor
final class ClientSessionManager {
    var servers: [DiscoveredServer] = []
    var connectionState: ClientConnectionState = .idle
    var metrics: TransportMetrics = TransportMetrics()
    var activeTouchCount: Int = 0
    var displayFPS: Double = 60.0
    var lastGestureLabel: String = ""

    // User preferences
    var connectionMode: ClientConnectionMode = .auto {
        didSet {
            guard connectionMode != oldValue else { return }
            pipeline.reset()
            servers = []
            transport.setConnectionMode(connectionMode)
        }
    }
    var autoConnectEnabled: Bool = true
    var blackoutModeEnabled: Bool = true
    var showDebugOverlay: Bool = true
    var showTouchIndicators: Bool = false
    var hapticFeedbackEnabled: Bool = true
    var threeFingerSwipesEnabled: Bool = true
    var hudVisible: Bool = true

    let transport: TrackpadClientTransport
    let pipeline: ClientTouchPipeline

    private var hudHideTask: Task<Void, Never>?
    private var gestureClearTask: Task<Void, Never>?
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    init() {
        let deviceName = UIDevice.current.name
        let transport = TrackpadClientTransport(localDeviceName: deviceName)
        self.transport = transport
        self.pipeline = ClientTouchPipeline(transport: transport)
        hapticGenerator.prepare()
        wireCallbacks()
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        transport.setConnectionMode(connectionMode)
        transport.startDiscovery()
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        transport.disconnect()
        transport.stopDiscovery()
    }

    func connect(to server: DiscoveredServer) {
        pipeline.reset()
        let bounds = UIScreen.main.bounds
        let aspect = Float32(bounds.width / max(bounds.height, 1.0))
        transport.connect(to: server, aspectRatio: aspect)
    }

    func disconnect() {
        pipeline.reset()
        transport.disconnect()
    }

    func sendSystemGesture(_ action: SystemGestureAction) {
        transport.sendSystemGesture(action)
        lastGestureLabel = switch action {
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .spaceLeft: "이전 스페이스"
        case .spaceRight: "다음 스페이스"
        }
        gestureClearTask?.cancel()
        gestureClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.lastGestureLabel = ""
        }
    }

    func revealHUDTemporarily() {
        hudVisible = true
        scheduleHUDAutoHideIfNeeded()
    }

    func scheduleHUDAutoHideIfNeeded() {
        hudHideTask?.cancel()
        guard blackoutModeEnabled, case .connected = connectionState else {
            hudVisible = true
            return
        }
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            if self.blackoutModeEnabled, case .connected = self.connectionState {
                self.hudVisible = false
            }
        }
    }

    private func wireCallbacks() {
        transport.onServersChanged = { [weak self] servers in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.servers = servers
                if self.autoConnectEnabled,
                   case .discovering = self.connectionState,
                   let best = servers.first {
                    self.connect(to: best)
                }
            }
        }

        transport.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = state
                if case .connected = state {
                    self.scheduleHUDAutoHideIfNeeded()
                } else {
                    self.hudVisible = true
                    self.hudHideTask?.cancel()
                }
            }
        }

        transport.onMetricsUpdated = { [weak self] metrics in
            Task { @MainActor [weak self] in
                self?.metrics = metrics
            }
        }

        transport.onHapticCue = { [weak self] cue in
            Task { @MainActor [weak self] in
                guard let self, self.hapticFeedbackEnabled else { return }
                self.hapticGenerator.impactOccurred(intensity: CGFloat(min(max(cue.intensity, 0.2), 1.0)))
                self.hapticGenerator.prepare()
            }
        }
    }
}
