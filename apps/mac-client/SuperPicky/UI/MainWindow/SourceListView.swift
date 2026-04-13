import SwiftUI

enum SidebarSelection: Hashable {
    case folder(URL)
    case rating(Int)
    case flying
    case picks
    case species(String)
}

struct SourceListView: View {
    @Binding var selection: SidebarSelection?
    @Binding var folders: [URL]
    let ratingCounts: [Int: Int]
    let speciesList: [(name: String, count: Int)]
    @Environment(ProcessManager.self) private var processManager

    let onAddFolder: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(folders, id: \.self) { folder in
                    Label(folder.lastPathComponent, systemImage: "folder")
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
                        Image(systemName: rating > 0 ? "star.fill" : "xmark")
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

            if !speciesList.isEmpty {
                Section("Species") {
                    ForEach(speciesList, id: \.name) { species in
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
