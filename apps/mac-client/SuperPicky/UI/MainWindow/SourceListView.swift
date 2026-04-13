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
    let folders: [URL]
    let ratingCounts: [Int: Int]
    let speciesList: [(name: String, count: Int)]

    var body: some View {
        List(selection: $selection) {
            Section("Folders") {
                ForEach(folders, id: \.self) { folder in
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .tag(SidebarSelection.folder(folder))
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
