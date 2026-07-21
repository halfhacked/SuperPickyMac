import SwiftUI

struct SourceListView: View {
    @Environment(CullingConfig.self) private var config
    @Binding var selection: SidebarSelection?
    @Binding var folders: [URL]
    let ratingCounts: [Int: Int]
    let rejectedCount: Int
    let flyingCount: Int
    let picksCount: Int
    let speciesEntries: [SpeciesEntry]
    let processingFolder: URL?
    let processingProgress: Double
    let processingProcessed: Int
    let processingTotal: Int

    let onAddFolder: () -> Void
    let onRemoveFolder: (URL) -> Void
    var onCancelProcessing: (() -> Void)?
    var onReprocessFolder: ((URL) -> Void)?
    var onRefreshFolder: ((URL) -> Void)?

    var body: some View {
        @Bindable var config = config
        List(selection: $selection) {
            Section {
                ForEach(folders, id: \.self) { folder in
                    FolderRow(
                        folder: folder,
                        isProcessing: processingFolder == folder,
                        progress: processingFolder == folder ? processingProgress : 0,
                        processed: processingFolder == folder ? processingProcessed : 0,
                        total: processingFolder == folder ? processingTotal : 0,
                        onCancel: (processingFolder == folder) ? onCancelProcessing : nil
                    )
                    .tag(SidebarSelection.folder(folder))
                    .contextMenu {
                        Button {
                            onRefreshFolder?(folder)
                        } label: {
                            Label(config.localized("Refresh Folder"), systemImage: "arrow.clockwise")
                        }

                        Button {
                            onReprocessFolder?(folder)
                        } label: {
                            Label(config.localized("Reprocess Folder"), systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(role: .destructive) {
                            removeFolder(folder)
                        } label: {
                            Label(config.localized("Remove"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text(config.localized("Folders"))
                    Spacer()
                    Button {
                        onAddFolder()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(config.localized("Process new folder"))
                    .accessibilityIdentifier("AddFolderButton")
                    .padding(.trailing, 12)
                }
            }

            Section(config.localized("Ratings")) {
                ForEach([5, 4, 3, 2, 1, 0], id: \.self) { rating in
                    let count = ratingCounts[rating] ?? 0
                    Label {
                        HStack {
                            Text(ratingLabel(rating))
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: ratingIcon(rating))
                            .foregroundStyle(ratingColor(rating))
                    }
                    .tag(SidebarSelection.rating(rating))
                }

                Label {
                    HStack {
                        Text(config.localized("Rejected"))
                        Spacer()
                        Text("\(rejectedCount)")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .tag(SidebarSelection.rejected)
            }

            Section(config.localized("Tags")) {
                Label {
                    HStack {
                        Text(config.localized("In Flight"))
                        Spacer()
                        Text("\(flyingCount)")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bird")
                }
                .tag(SidebarSelection.flying)

                Label {
                    HStack {
                        Text(config.localized("Picks"))
                        Spacer()
                        Text("\(picksCount)")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "flag.fill")
                }
                .tag(SidebarSelection.picks)
            }

            if !speciesEntries.isEmpty {
                Section {
                    ForEach(speciesEntries) { species in
                        if species.burstGroups.isEmpty {
                            // No bursts — flat selectable row
                            Label {
                                HStack {
                                    Text(species.isUnidentified ? config.localized("Unidentified") : config.localizedName(en: species.name, cn: species.cnName))
                                    Spacer()
                                    Text("\(species.picks)/\(species.count)")
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: species.isUnidentified ? "questionmark.circle" : "bird")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarSelection.species(species.speciesID))
                        } else {
                            // Has bursts — native DisclosureGroup
                            DisclosureGroup {
                                ForEach(species.burstGroups) { burst in
                                    Label {
                                        HStack {
                                            Text(config.localized("Burst"))
                                            Spacer()
                                            Text("\(burst.pickCount)/\(burst.count)")
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "rectangle.stack")
                                            .foregroundStyle(.orange)
                                    }
                                    .tag(SidebarSelection.burstGroup(burst.id))
                                }
                                if species.singlePhotos > 0 {
                                    Label {
                                        HStack {
                                            Text(config.localized("Singles"))
                                            Spacer()
                                            Text("\(species.singlePicks)/\(species.singlePhotos)")
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                    .tag(SidebarSelection.singles(species.speciesID))
                                }
                            } label: {
                                Label {
                                    HStack {
                                        Text(species.isUnidentified ? config.localized("Unidentified") : config.localizedName(en: species.name, cn: species.cnName))
                                        Spacer()
                                        Text("\(species.picks)/\(species.count)")
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: species.isUnidentified ? "questionmark.circle" : "bird")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(SidebarSelection.species(species.speciesID))
                        }
                    }
                } header: {
                    HStack {
                        Text(config.localized("Species"))
                        Spacer()
                        Menu {
                            Picker(config.localized("Sort species"), selection: $config.speciesSortOrder) {
                                Text(config.localized("Sort by name")).tag(SpeciesSortOrder.name)
                                Text(config.localized("Sort by count")).tag(SpeciesSortOrder.count)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(config.localized("Sort species"))
                        .accessibilityIdentifier("SpeciesSortMenu")
                        .padding(.trailing, 12)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func removeFolder(_ folder: URL) {
        folders.removeAll { $0 == folder }
        if case .folder(let selected) = selection, selected == folder {
            selection = nil
        }
        onRemoveFolder(folder)
    }

    private func ratingLabel(_ rating: Int) -> String {
        switch rating {
        case 5: config.localized("Excellent")
        case 4: config.localized("Good")
        case 3: config.localized("Average")
        case 2: config.localized("Below Average")
        case 1: config.localized("Poor")
        case 0: config.localized("0 Stars")
        default: config.localized("Unknown")
        }
    }

    private func ratingIcon(_ rating: Int) -> String {
        switch rating {
        case 5: "star.fill"
        case 4: "star.fill"
        case 3: "star.leadinghalf.filled"
        case 2: "star"
        case 1: "star"
        case 0: "star"
        default: "questionmark"
        }
    }

    private func ratingColor(_ rating: Int) -> Color {
        switch rating {
        case 5: .green
        case 4: .blue
        case 3: .yellow
        case 2: .orange
        case 1: .secondary
        case 0: .secondary
        default: .secondary
        }
    }
}

struct FolderRow: View {
    @Environment(CullingConfig.self) private var config
    let folder: URL
    let isProcessing: Bool
    let progress: Double
    let processed: Int
    let total: Int
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(folder.lastPathComponent, systemImage: "folder")
            if isProcessing {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .scaleEffect(y: 0.5)
                    if total > 0 {
                        Text("\(processed)/\(total)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        onCancel?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help(config.localized("Cancel processing"))
                    .accessibilityIdentifier("CancelProcessingButton")
                }
            }
        }
    }
}
