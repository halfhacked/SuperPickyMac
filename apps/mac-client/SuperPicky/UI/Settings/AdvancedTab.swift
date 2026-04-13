import SwiftUI

struct AdvancedTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section("Burst Detection") {
                Toggle("Enable burst detection", isOn: $config.burstDetectionEnabled)
            }
            Section("Backend") {
                HStack {
                    Text("Python server port")
                    TextField("Port", value: $config.backendPort, format: .number)
                        .frame(width: 80)
                }
            }
        }
        .formStyle(.grouped)
    }
}
