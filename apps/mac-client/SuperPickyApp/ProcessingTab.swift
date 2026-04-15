import SwiftUI

struct ProcessingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        Form {
            Text(config.localized("Processing settings will appear here."))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
