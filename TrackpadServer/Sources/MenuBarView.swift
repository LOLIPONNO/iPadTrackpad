import SharedKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var server: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if !server.isAccessibilityTrusted {
                accessibilityBanner
            }

            Divider()

            interfaceSection

            Divider()

            telemetrySection

            Divider()

            preferencesSection

            Divider()

            footerActions
        }
        .padding(14)
        .frame(width: 330)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: server.menuBarIconName)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("iPad Trackpad Server")
                    .font(.headline)
                Text(server.connectionBadgeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(server.endpointDetailText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("손쉬운 사용(Accessibility) 권한 필요")
                    .font(.caption.weight(.semibold))
            }
            Text("커서 이동, 스크롤 및 시스템 제스처 주입을 위해 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 TrackpadServer를 허용하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("손쉬운 사용 설정 열기") {
                server.requestAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("수신 인터페이스")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(server.metrics.isUDPActive ? "UDP 초저지연" : "TCP 제어/대기")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(server.metrics.isUDPActive ? .green : .secondary)
            }

            Picker("수신 인터페이스", selection: $server.interfacePreference) {
                ForEach(ServerInterfacePreference.allCases) { pref in
                    Text(pref.rawValue).tag(pref)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private var telemetrySection: some View {
        HStack(spacing: 0) {
            telemetryCell(title: "전송 매체", value: server.metrics.medium.rawValue)
            Spacer()
            telemetryCell(title: "RATE", value: "\(Int(server.metrics.packetsPerSecond)) pkt/s")
            Spacer()
            telemetryCell(title: "DROP", value: "\(server.metrics.droppedPackets)")
            Spacer()
            telemetryCell(title: "대역폭", value: String(format: "%.1f KB/s", Double(server.metrics.bytesPerSecond) / 1024.0))
        }
    }

    private func telemetryCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("트래킹 감도")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", server.sensitivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $server.sensitivity, in: 0.5...3.5, step: 0.05)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("스크롤 속도")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", server.scrollSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $server.scrollSpeed, in: 0.5...3.0, step: 0.05)
                    .controlSize(.small)
            }

            Toggle("탭하여 클릭", isOn: $server.tapToClickEnabled)
                .font(.caption)
            Toggle("3손가락 드래그 (해제 시 Mission Control/스페이스)", isOn: $server.threeFingerDragEnabled)
                .font(.caption)
            Toggle("자연스러운 스크롤", isOn: $server.naturalScrolling)
                .font(.caption)
        }
    }

    private var footerActions: some View {
        HStack {
            Button("리스너 재시작") {
                server.stop()
                server.start()
            }
            .controlSize(.small)

            Spacer()

            Button("종료") {
                server.stop()
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch server.listenerState {
        case .connected(_, .usbWired):
            return .green
        case .connected:
            return .cyan
        case .listening:
            return .orange
        case .stopped, .failed:
            return .red
        }
    }
}
