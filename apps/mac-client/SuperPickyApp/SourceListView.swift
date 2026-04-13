import SwiftUI

enum SidebarSelection: Hashable {
    case folder(URL)
    case rating(Int)
    case flying
    case picks
    case species(String)
    case burstGroup(UUID)
}

struct SourceListView: View {
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

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(folders, id: \.self) { folder in
                    FolderRow(
                        folder: folder,
                        isProcessing: processingFolder == folder,
                        progress: processingFolder == folder ? processingProgress : 0
                    )
                    .tag(SidebarSelection.folder(folder))
                    .contextMenu {
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
                                    Text(species.name)
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
                                }
                            } label: {
                                Label {
                                    HStack {
                                        Text(species.name)
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

    private func ratingLabel(_ rating: Int) -> String {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(folder.lastPathComponent, systemImage: "folder")
            if isProcessing {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .scaleEffect(y: 0.5)
            }
        }
    }
}

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

    private var statusText: String {
        if processManager.isReady {
            return "Models ready"
        } else if processManager.isRunning {
            return "Loading models..."
        } else {
            return "Server offline"
        }
    }
}
