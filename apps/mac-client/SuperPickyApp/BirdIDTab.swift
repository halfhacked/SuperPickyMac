import SwiftUI

struct BirdIDTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Picker(config.localized("Naming Standard"), selection: $config.namingStandard) {
                Text("OSEA (Original)").tag(NamingStandard.osea)
                Text("AviList v2025").tag(NamingStandard.avilist)
                Text("Clements/eBird 2024").tag(NamingStandard.clements)
                Text("BirdLife International v9").tag(NamingStandard.birdlife)
                Text("Scientific Names Only").tag(NamingStandard.scientific)
            }

            Section(config.localized("Confidence")) {
                HStack {
                    Text(config.localized("Bird ID Confidence"))
                    Slider(
                        value: Binding(
                            get: { Double(config.birdIdConfidence) },
                            set: { config.birdIdConfidence = Int($0) }
                        ),
                        in: 50...95,
                        step: 5
                    )
                    Text("\(config.birdIdConfidence)%")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text(config.localized("Species below this confidence will not be written to EXIF."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
