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
                ForEach([3, 2, 1, 0], id: \.self) { rating in
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
                Label("In Flight", systemImage: "bird")
                    .tag(SidebarSelection.flying)
                Label("Picks", systemImage: "flag.fill")
                    .tag(SidebarSelection.picks)
            }

            if !speciesEntries.isEmpty {
                Section("Species") {
                    ForEach(speciesEntries) { species in
                        if species.burstGroups.isEmpty {
                            // No bursts — flat row, no disclosure arrow
                            HStack {
                                Text(species.name)
                                Spacer()
                                Text("\(species.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarSelection.species(species.name))
                        } else {
                            // Has bursts — expandable
                            DisclosureGroup {
                                ForEach(species.burstGroups) { burst in
                                    HStack {
                                        Image(systemName: "rectangle.stack")
                                            .foregroundStyle(.orange)
                                        Text("Burst")
                                        Spacer()
                                        Text("\(burst.count)")
                                            .foregroundStyle(.secondary)
                                    }
                                    .tag(SidebarSelection.burstGroup(burst.id))
                                }
                                if species.singlePhotos > 0 {
                                    HStack {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                        Text("Singles")
                                        Spacer()
                                        Text("\(species.singlePhotos)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(species.name)
                                    Spacer()
                                    Text("\(species.count)")
                                        .foregroundStyle(.secondary)
                                }
                                .tag(SidebarSelection.species(species.name))
                            }
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
        case 3: "Excellent"
        case 2: "Good"
        case 1: "Average"
        case 0: "Reject"
        default: "Unknown"
        }
    }

    private func ratingIcon(_ rating: Int) -> String {
        switch rating {
        case 3: "star.fill"
        case 2: "star.leadinghalf.filled"
        case 1: "star"
        case 0: "xmark"
        default: "questionmark"
        }
    }

    private func ratingColor(_ rating: Int) -> Color {
        switch rating {
        case 3: .green
        case 2: .blue
        case 1: .yellow
        case 0: .secondary
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
