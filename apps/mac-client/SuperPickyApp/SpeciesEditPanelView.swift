import SwiftUI

/// Floating panel for editing which species are tagged on the selected
/// photo. Sections: currently assigned (removable chips + primary marker),
/// OSEA candidates grouped by filter level, and an autocomplete-backed
/// free-form search for species OSEA missed.
struct SpeciesEditPanelView: View {
    @Environment(CullingConfig.self) private var config
    let photo: Photo
    /// Called with the new full assigned-species list whenever the user
    /// makes a change. Parent persists via `AppState.setAssignedSpecies`.
    var onAssignedChanged: ([SpeciesMatch]) -> Void
    /// Autocomplete backend — defaults to "no matches" so previews and
    /// unit tests don't need the CoreML species database wired up.
    var searchSpecies: (_ query: String) -> [SpeciesMatch] = { _ in [] }

    @State private var searchQuery: String = ""
    @State private var searchResults: [SpeciesMatch] = []

    private var assigned: [SpeciesMatch] { photo.assignedSpecies }
    private var candidates: [SpeciesMatch] { decodeCandidates() }
    private var assignedIDs: Set<String> { Set(assigned.map(\.speciesID)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                assignedSection
                candidatesSection
                searchSection
            }
            .padding(.vertical, 8)
        }
        .frame(width: 280, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, x: -2, y: 2)
        .padding(8)
        .accessibilityIdentifier("SpeciesEditPanel")
        .onChange(of: photo.id) {
            searchQuery = ""
            searchResults = []
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var assignedSection: some View {
        sectionHeader(config.localized("Assigned"), showDivider: false)
        if assigned.isEmpty {
            Text(config.localized("No species assigned"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("SpeciesEditPanel_EmptyAssigned")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(assigned.enumerated()), id: \.element.speciesID) { index, match in
                    assignedRow(match: match, isPrimary: index == 0, index: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        let available = candidates.filter { !assignedIDs.contains($0.speciesID) }
        if !available.isEmpty {
            sectionHeader(config.localized("OSEA Candidates"))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(available, id: \.speciesID) { match in
                    candidateRow(match: match)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        sectionHeader(config.localized("Add Species"))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(config.localized("Search species"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("SpeciesEditPanel_SearchField")
                    .onSubmit {
                        commitSearchQuery()
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(searchResults.prefix(8), id: \.speciesID) { match in
                        searchResultRow(match: match)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .padding(.bottom, 4)
        .onChange(of: searchQuery) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchResults = []
                return
            }
            searchResults = searchSpecies(trimmed)
                .filter { !assignedIDs.contains($0.speciesID) }
        }
    }

    // MARK: - Row builders

    private func assignedRow(match: SpeciesMatch, isPrimary: Bool, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isPrimary ? "crown.fill" : "bird.fill")
                .font(.system(size: 10))
                .foregroundStyle(isPrimary ? .yellow : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayLabel(for: match))
                    .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                    .lineLimit(1)
                Text(match.scientificName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .italic()
                    .lineLimit(1)
            }
            Spacer()
            if !isPrimary {
                Button {
                    var list = assigned
                    let entry = list.remove(at: index)
                    list.insert(entry, at: 0)
                    onAssignedChanged(list)
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(config.localized("Make primary"))
            }
            Button {
                var list = assigned
                list.remove(at: index)
                onAssignedChanged(list)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SpeciesEditPanel_Remove_\(match.speciesID)")
            .help(config.localized("Remove"))
        }
    }

    private func candidateRow(match: SpeciesMatch) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayLabel(for: match))
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(match.scientificName)
                        .italic()
                    if match.confidence > 0 {
                        Text("\(Int(match.confidence * 100))%")
                    }
                    if let level = match.thresholdUsed {
                        Text(levelLabel(level))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
            Button {
                var list = assigned
                list.append(match)
                onAssignedChanged(list)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SpeciesEditPanel_Add_\(match.speciesID)")
        }
    }

    private func searchResultRow(match: SpeciesMatch) -> some View {
        Button {
            var list = assigned
            list.append(match)
            onAssignedChanged(list)
            searchQuery = ""
            searchResults = []
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayLabel(for: match))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(match.scientificName)
                        .font(.system(size: 10))
                        .italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func displayLabel(for match: SpeciesMatch) -> String {
        config.localizedName(en: match.commonName ?? match.scientificName, cn: match.cnName)
    }

    private func levelLabel(_ raw: String) -> String {
        switch raw {
        case "gps": return config.localized("GPS")
        case "country": return config.localized("Region")
        case "global": return config.localized("Global")
        case "manual": return config.localized("Manual")
        default: return raw
        }
    }

    private func decodeCandidates() -> [SpeciesMatch] {
        guard let json = photo.speciesTop5JSON,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([SpeciesMatch].self, from: data) else {
            return []
        }
        return list
    }

    private func commitSearchQuery() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let match: SpeciesMatch
        if let first = searchResults.first {
            match = first
        } else {
            // No autocomplete match — treat as user-entered custom species.
            match = SpeciesMatch(
                scientificName: trimmed,
                commonName: trimmed,
                confidence: 0,
                cnName: nil,
                pinyin: nil,
                thresholdUsed: "manual",
                ebirdCode: nil
            )
        }
        var list = assigned
        guard !assignedIDs.contains(match.speciesID) else {
            searchQuery = ""
            searchResults = []
            return
        }
        list.append(match)
        onAssignedChanged(list)
        searchQuery = ""
        searchResults = []
    }

    private func sectionHeader(_ title: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showDivider {
                Divider()
                    .padding(.horizontal, 12)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, showDivider ? 8 : 2)
                .padding(.bottom, 4)
        }
    }
}
