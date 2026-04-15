import SwiftUI

struct ServerStatusView: View {
    @Environment(ProcessManager.self) private var processManager
    @Environment(CullingConfig.self) private var config

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(processManager.isReady ? .green : (processManager.isRunning ? .orange : .red))
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .accessibilityIdentifier("ServerStatus")
    }

    private var statusText: String {
        if processManager.isReady {
            return config.localized("Models ready")
        } else if processManager.isRunning {
            return config.localized("Loading models...")
        } else {
            return config.localized("Server offline")
        }
    }
}
