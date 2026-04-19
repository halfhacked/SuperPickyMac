import SwiftUI

struct BirdIDTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Picker(config.localized("Naming Standard"), selection: $config.namingStandard) {
                Text(config.localized("OSEA (Original)")).tag(NamingStandard.osea)
                Text(config.localized("AviList v2025")).tag(NamingStandard.avilist)
                Text(config.localized("Clements/eBird 2024")).tag(NamingStandard.clements)
                Text(config.localized("BirdLife International v9")).tag(NamingStandard.birdlife)
                Text(config.localized("Scientific Names Only")).tag(NamingStandard.scientific)
            }
            Text(config.localized("Taxonomy used for common and scientific species names written to EXIF."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Section(config.localized("Confidence")) {
                SliderRow(label: config.localized("Bird ID Confidence"),
                          value: Binding(
                              get: { Double(config.birdIdConfidence) },
                              set: { config.birdIdConfidence = (Int(($0 / 5).rounded()) * 5) }
                          ),
                          range: 50...95,
                          display: "\(config.birdIdConfidence)%")
                Text(config.localized("Species below this confidence will not be written to EXIF."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
