import SwiftUI

struct BirdIDTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Picker("Naming Standard", selection: $config.namingStandard) {
                Text("OSEA (Original)").tag(NamingStandard.osea)
                Text("AviList v2025").tag(NamingStandard.avilist)
                Text("Clements/eBird 2024").tag(NamingStandard.clements)
                Text("BirdLife International v9").tag(NamingStandard.birdlife)
                Text("Scientific Names Only").tag(NamingStandard.scientific)
            }

            Section("Keywords") {
                Toggle("Write keywords to photos", isOn: $config.writeKeywords)

                if config.writeKeywords {
                    TextField("Keyword format", text: $config.keywordFormat)
                        .textFieldStyle(.roundedBorder)
                    Text("Tokens: {en} {cn} {latin} {pinyin}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
