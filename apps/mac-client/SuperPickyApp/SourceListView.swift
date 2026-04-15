import SwiftUI

struct SourceListView: View {
    @Environment(CullingConfig.self) private var config
    @Binding var selection: SidebarSelection?
    @Binding var folders: [URL]
    let ratingCounts: [Int: Int]
    let flyingCount: Int
    let picksCount: Int
    let speciesEntries: [SpeciesEntry]
    let processingFolder: URL?
    let processingProgress: Double
    @Environment(ProcessManager.self) private var processManager

    let onAddFolder: () -> Void
    let onRemoveFolder: (URL) -> Void
    var onCancelProcessing: (() -> Void)?
    var onReprocessFolder: ((URL) -> Void)?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(folders, id: \.self) { folder in
                    FolderRow(
                        folder: folder,
                        isProcessing: processingFolder == folder,
                        progress: processingFolder == folder ? processingProgress : 0,
                        onCancel: (processingFolder == folder) ? onCancelProcessing : nil
                    )
                    .tag(SidebarSelection.folder(folder))
                    .contextMenu {
                        Button {
                            onReprocessFolder?(folder)
                        } label: {
                            Label("Reprocess Folder", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Button(role: .destructive) {
                            removeFolder(folder)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        onAddFolder()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Process new folder")
                    .accessibilityIdentifier("AddFolderButton")
                    .padding(.trailing, 12)
                }
            }

            Section("Ratings") {
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
            }

            Section("Tags") {
                Label {
                    HStack {
                        Text("In Flight")
                        Spacer()
                        Text("\(flyingCount)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "bird")
                }
                .tag(SidebarSelection.flying)

                Label {
                    HStack {
                        Text("Picks")
                        Spacer()
                        Text("\(picksCount)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "flag.fill")
                }
                .tag(SidebarSelection.picks)
            }

            if !speciesEntries.isEmpty {
                Section("Species") {
                    ForEach(speciesEntries) { species in
                        if species.burstGroups.isEmpty {
                            // No bursts — flat selectable row
                            Label {
                                HStack {
                                    Text(species.isUnidentified ? config.localized("Unidentified") : config.localizedName(en: species.name, cn: species.cnName))
                                    Spacer()
                                    Text("\(species.count)")
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: species.isUnidentified ? "questionmark.circle" : "bird")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarSelection.species(species.name))
                        } else {
                            // Has bursts — native DisclosureGroup
                            DisclosureGroup {
                                ForEach(species.burstGroups) { burst in
                                    Label {
                                        HStack {
                                            Text("Burst")
                                            Spacer()
                                            Text("\(burst.count)")
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
                                            Text("Singles")
                                            Spacer()
                                            Text("\(species.singlePhotos)")
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                    .tag(SidebarSelection.singles(species.name))
                                }
                            } label: {
                                Label {
                                    HStack {
                                        Text(species.isUnidentified ? config.localized("Unidentified") : config.localizedName(en: species.name, cn: species.cnName))
                                        Spacer()
                                        Text("\(species.count)")
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: species.isUnidentified ? "questionmark.circle" : "bird")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(SidebarSelection.species(species.name))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ServerStatusView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private func removeFolder(_ folder: URL) {
        folders.removeAll { $0 == folder }
        if case .folder(let selected) = selection, selected == folder {
            selection = nil
        }
        onRemoveFolder(folder)
    }

    private func ratingLabel(_ rating: Int) -> LocalizedStringKey {
        switch rating {
        case 5: "Excellent"
        case 4: "Good"
        case 3: "Average"
        case 2: "Below Average"
        case 1: "Poor"
        case 0: "Reject"
        default: "Unknown"
        }
    }

    private func ratingIcon(_ rating: Int) -> String {
        switch rating {
        case 5: "star.fill"
        case 4: "star.fill"
        case 3: "star.leadinghalf.filled"
        case 2: "star"
        case 1: "star"
        case 0: "xmark"
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
        case 0: .red
        default: .secondary
        }
    }
}

struct FolderRow: View {
    let folder: URL
    let isProcessing: Bool
    let progress: Double
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(folder.lastPathComponent, systemImage: "folder")
            if isProcessing {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .scaleEffect(y: 0.5)
                    Button {
                        onCancel?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel processing")
                    .accessibilityIdentifier("CancelProcessingButton")
                }
            }
        }
    }
}
