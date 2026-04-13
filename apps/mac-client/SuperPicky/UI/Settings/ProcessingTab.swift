import SwiftUI

struct ProcessingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Toggle("Auto-organize into star folders", isOn: $config.autoOrganize)
        }
        .formStyle(.grouped)
    }
}
