import SwiftUI

struct ServerStatusView: View {
    @Environment(ProcessManager.self) private var processManager

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

    private var statusText: LocalizedStringKey {
        if processManager.isReady {
            return "Models ready"
        } else if processManager.isRunning {
            return "Loading models..."
        } else {
            return "Server offline"
        }
    }
}
