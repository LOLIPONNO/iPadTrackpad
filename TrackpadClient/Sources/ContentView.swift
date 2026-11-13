import SharedKit
import SwiftUI

struct ContentView: View {
    @State private var session = ClientSessionManager()
    @State private var showSettingsSheet = false

    var body: some View {
        ZStack {
            // Pure #000000 canvas prevents OLED/Mini-LED burn-in and minimizes display power draw.
            Color.black.ignoresSafeArea()

            TrackpadTouchView(
                showTouchIndicators: session.showTouchIndicators,
                hapticFeedbackEnabled: session.hapticFeedbackEnabled,
                threeFingerSwipesEnabled: session.threeFingerSwipesEnabled,
                onTouchFrame: { [pipeline = session.pipeline] points, timestampNs in
                    pipeline.submit(points: points, timestampNs: timestampNs)
                },
                onSystemGesture: { action in
                    session.sendSystemGesture(action)
                },
                onActiveTouchCountChanged: { count in
                    session.activeTouchCount = count
                },
                onDisplayRefreshMetrics: { fps in
                    session.displayFPS = fps
                }
            )
            .ignoresSafeArea()

            // Minimalist floating HUD & Debug Telemetry Overlay
            VStack {
                HStack(alignment: .top, spacing: 10) {
                    if session.hudVisible {
                        connectionPill
                        connectionModeMenu
                        Spacer()
                        if session.showDebugOverlay {
                            debugTelemetryPill
                        }
                        settingsButton
                    } else {
                        Spacer()
                        Button {
                            session.revealHUDTemporarily()
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.22))
                                .padding(12)
                        }
                        .accessibilityLabel("트랙패드 컨트롤 표시")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                if !session.lastGestureLabel.isEmpty {
                    Text(session.lastGestureLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial.opacity(0.5), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                        .transition(.opacity)
                        .padding(.bottom, 20)
                }

                if case .discovering = session.connectionState {
                    if !session.servers.isEmpty {
                        serverPickerOverlay
                            .padding(.bottom, 40)
                    } else if session.connectionMode == .usbWired {
                        usbWaitingHint
                            .padding(.bottom, 40)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: session.hudVisible)
            .animation(.easeInOut(duration: 0.18), value: session.lastGestureLabel)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            session.start()
        }
        .onDisappear {
            session.stop()
        }
        .sheet(isPresented: $showSettingsSheet) {
            ClientSettingsSheet(session: session)
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(statusSubtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
    }

    private var connectionModeMenu: some View {
        Menu {
            Picker("연결 방식", selection: $session.connectionMode) {
                ForEach(ClientConnectionMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: iconForMode(mode))
                        .tag(mode)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconForMode(session.connectionMode))
                    .font(.caption)
                Text(shortModeLabel(session.connectionMode))
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        }
    }

    private var debugTelemetryPill: some View {
        HStack(spacing: 14) {
            metricCell(label: "STREAM", value: session.metrics.isUDPActive ? "UDP" : "TCP")
            metricCell(label: "RTT", value: String(format: "%.1f ms", session.metrics.rttMs))
            metricCell(label: "Hz", value: String(format: "%.0f", session.displayFPS))
            metricCell(label: "PPS", value: String(format: "%.0f", session.metrics.packetsPerSecond))
            metricCell(label: "DELTA", value: String(format: "%.0f%%", session.metrics.compressionSavingsPercent))
            metricCell(label: "TOUCH", value: "\(session.activeTouchCount)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.75))
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var settingsButton: some View {
        Button {
            session.revealHUDTemporarily()
            showSettingsSheet = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(10)
                .background(.ultraThinMaterial.opacity(0.35), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
        }
    }

    private var serverPickerOverlay: some View {
        VStack(spacing: 12) {
            Text("연결 가능한 Mac")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

            ForEach(session.servers) { server in
                Button {
                    session.connect(to: server)
                } label: {
                    HStack {
                        Image(systemName: server.isWiredCandidate ? "cable.connector" : "wifi")
                            .foregroundStyle(server.isWiredCandidate ? .green : .blue)
                        Text(server.name)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(server.isWiredCandidate ? "USB 유선" : "Wi-Fi")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: 360)
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var usbWaitingHint: some View {
        VStack(spacing: 6) {
            Label("USB 유선 연결 대기 중…", systemImage: "cable.connector")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
            Text("USB-C 케이블 또는 유선 네트워크 브리지 연결 후 Mac에서 TrackpadServer가 실행 중인지 확인하세요.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
    }

    private func iconForMode(_ mode: ClientConnectionMode) -> String {
        switch mode {
        case .auto: "bolt.horizontal.circle"
        case .wifi: "wifi"
        case .usbWired: "cable.connector"
        }
    }

    private func shortModeLabel(_ mode: ClientConnectionMode) -> String {
        switch mode {
        case .auto: "자동"
        case .wifi: "Wi-Fi"
        case .usbWired: "USB 유선"
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected(_, let medium):
            return medium == .usbWired ? .green : .cyan
        case .connecting, .discovering:
            return .orange
        case .failed:
            return .red
        case .idle:
            return .gray
        }
    }

    private var statusTitle: String {
        switch session.connectionState {
        case .idle: return "대기 중"
        case .discovering: return session.connectionMode == .usbWired ? "USB 유선 Mac 검색 중…" : "Mac 검색 중…"
        case .connecting(let name): return "\(name)에 연결 중…"
        case .connected(let peerName, _): return peerName
        case .failed: return "연결 오류"
        }
    }

    private var statusSubtitle: String {
        switch session.connectionState {
        case .connected(_, let medium):
            let endpoint = session.metrics.activeEndpoint.isEmpty ? "" : " • \(session.metrics.activeEndpoint)"
            return "\(medium.rawValue) • \(String(format: "%.1f ms", session.metrics.oneWayMs))\(endpoint)"
        case .discovering:
            return "\(session.servers.count)대의 Mac 발견됨"
        case .failed(let msg):
            return msg
        default:
            return "Bonjour (_virtualtrackpad._tcp)"
        }
    }
}

private struct ClientSettingsSheet: View {
    @Bindable var session: ClientSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("연결 모드 (Wi-Fi / USB 유선)") {
                    Picker("연결 방식", selection: $session.connectionMode) {
                        ForEach(ClientConnectionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("자동 연결 (USB 우선)", isOn: $session.autoConnectEnabled)

                    if case .connected(let name, let medium) = session.connectionState {
                        LabeledContent("연결된 Mac", value: name)
                        LabeledContent("전송 매체", value: medium.rawValue)
                        LabeledContent("터치 스트림", value: session.metrics.isUDPActive ? "UDP (초저지연)" : "TCP (보조)")
                        if !session.metrics.activeEndpoint.isEmpty {
                            LabeledContent("연결 주소", value: session.metrics.activeEndpoint)
                        }
                        Button("연결 끊기", role: .destructive) {
                            session.disconnect()
                            dismiss()
                        }
                    } else if !session.servers.isEmpty {
                        ForEach(session.servers) { server in
                            Button {
                                session.connect(to: server)
                                dismiss()
                            } label: {
                                Label(
                                    "\(server.name) (\(server.isWiredCandidate ? "USB 유선" : "Wi-Fi"))",
                                    systemImage: server.isWiredCandidate ? "cable.connector" : "wifi"
                                )
                            }
                        }
                    } else {
                        Text("Mac에서 TrackpadServer 실행을 기다리는 중…")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("디스플레이 & 제스처") {
                    Toggle("3손가락 시스템 제스처 (Mission Control / 스페이스)", isOn: $session.threeFingerSwipesEnabled)
                    Toggle("OLED 블랙아웃 HUD 자동 숨김", isOn: $session.blackoutModeEnabled)
                    Toggle("지연시간 / FPS 디버그 오버레이", isOn: $session.showDebugOverlay)
                    Toggle("터치 접촉 링 표시", isOn: $session.showTouchIndicators)
                    Toggle("클릭/제스처 햅틱 피드백", isOn: $session.hapticFeedbackEnabled)
                }

                Section("지원 제스처 안내") {
                    LabeledContent("1손가락", value: "커서 이동 및 탭 클릭")
                    LabeledContent("2손가락", value: "관성 스크롤, 핀치 줌, 탭 우클릭")
                    LabeledContent("3손가락 상/하", value: "Mission Control / App Exposé")
                    LabeledContent("3손가락 좌/우", value: "데스크톱(스페이스) 전환")
                    LabeledContent("4손가락 스와이프", value: "시스템 제스처 (3손가락 드래그 사용 시)")
                }
            }
            .navigationTitle("TrackpadClient 설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
