import SwiftUI

/// Floating info panel: EXIF metadata on top, species editing at the bottom.
/// Combines what used to be two separate floating panels into a single
/// scrollable surface toggled by one toolbar button.
struct ExifPanelView: View {
    @Environment(CullingConfig.self) private var config
    let appState: AppState
    let photo: Photo
    /// Autocomplete backend — defaults to "no matches" so previews and
    /// unit tests don't need the CoreML species database wired up.
    var searchSpecies: (_ query: String) -> [SpeciesMatch] = { _ in [] }

    @State private var exifData: EXIFData?
    @State private var isMetadataExpanded = true
    @State private var isCandidatesExpanded = true
    @State private var searchQuery: String = ""
    @State private var searchResults: [SpeciesMatch] = []
    @FocusState private var searchFieldFocused: Bool

    private let labelWidth: CGFloat = 100

    private var selection: PhotoSelection { appState.selection }
    private var isMulti: Bool { selection.isMulti }
    private var selectedPhotos: [Photo] {
        let ids = selection.selectedIDs
        if ids.isEmpty { return [photo] }
        return appState.photos.filter { ids.contains($0.id) }
    }
    private var targetIDs: Set<UUID> {
        isMulti ? selection.selectedIDs : [photo.id]
    }
    private var assignedRows: [BatchSpeciesAggregator.AssignedRow] {
        if isMulti {
            return BatchSpeciesAggregator.unionAssigned(selectedPhotos)
        } else {
            return photo.assignedSpecies.map { BatchSpeciesAggregator.AssignedRow(species: $0, photoCount: 1) }
        }
    }
    private var availableCandidates: [SpeciesMatch] {
        if isMulti {
            let assignedIDsLocal = Set(assignedRows.map(\.species.speciesID))
            return BatchSpeciesAggregator.topCandidates(selectedPhotos, limit: 10)
                .filter { !assignedIDsLocal.contains($0.speciesID) }
        } else {
            let assignedIDsLocal = Set(photo.assignedSpecies.map(\.speciesID))
            return SpeciesAssignmentEditor
                .decodeCandidates(fromJSON: photo.speciesTop5JSON)
                .filter { !assignedIDsLocal.contains($0.speciesID) }
        }
    }
    private var assignedIDs: Set<String> {
        Set(assignedRows.map(\.species.speciesID))
    }

    var body: some View {
        VStack(spacing: 0) {
            metadataToggle

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isMetadataExpanded {
                        exifSections
                    }
                    speciesSections
                }
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("ExifPanel")
        }
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, x: -2, y: 2)
        .padding(8)
        // Re-fire on assignedSpeciesJSON changes too: keywords come from the
        // XMP sidecar, which the species edit panel rewrites on every edit.
        // Swap atomically — clearing exifData between photos flashes the
        // species sections up and back down on every switch.
        .task(id: [photo.id.uuidString, photo.assignedSpeciesJSON ?? ""]) {
            let newData = await Task.detached {
                EXIFReader.read(from: photo.filePath)
            }.value
            guard !Task.isCancelled else { return }
            exifData = newData
        }
        .onChange(of: photo.id) {
            searchQuery = ""
            searchResults = []
        }
    }

    // MARK: - EXIF sections

    private var metadataToggle: some View {
        Button {
            isMetadataExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(config.localized("Metadata"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: isMetadataExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ExifMetadataToggle")
        .accessibilityValue(isMetadataExpanded ? "expanded" : "collapsed")
    }

    @ViewBuilder
    private var exifSections: some View {
        if let data = exifData, !data.isEmpty {
            // Camera section
            if data.cameraMake != nil || data.cameraModel != nil || data.lensModel != nil {
                sectionHeader(config.localized("Camera"), showDivider: false)
                if let make = data.cameraMake, let model = data.cameraModel {
                    exifRow(label: config.localized("Camera"), value: "\(make) \(model)")
                } else if let model = data.cameraModel {
                    exifRow(label: config.localized("Camera"), value: model)
                } else if let make = data.cameraMake {
                    exifRow(label: config.localized("Camera"), value: make)
                }
                if let lens = data.lensModel {
                    exifRow(label: config.localized("Lens"), value: lens)
                }
            }

            // Exposure section
            if data.focalLength != nil || data.aperture != nil || data.shutterSpeed != nil || data.iso != nil {
                sectionHeader(config.localized("Exposure"))
                if let focal = data.focalLength {
                    exifRow(label: config.localized("Focal Length"), value: "\(formatNumber(focal)) mm")
                }
                // Combine exposure like Lightroom: "1/2000 at f/6.3, ISO 1600"
                exifRow(label: config.localized("Exposure"), value: formatExposure(data))
                if let bias = data.exposureBias, bias != 0 {
                    let sign = bias >= 0 ? "+" : ""
                    exifRow(label: config.localized("Exp Comp"), value: "\(sign)\(formatNumber(bias)) EV")
                }
                if let metering = data.meteringMode {
                    exifRow(label: config.localized("Metering"), value: metering)
                }
                if let wb = data.whiteBalance {
                    exifRow(label: config.localized("White Balance"), value: wb)
                }
            }

            // Image section
            if data.imageWidth != nil || data.dateTimeOriginal != nil {
                sectionHeader(config.localized("Image"))
                if let date = data.dateTimeOriginal {
                    exifRow(label: config.localized("Capture Date"),
                            value: formatDate(date, offset: data.offsetTimeOriginal))
                }
                if let w = data.imageWidth, let h = data.imageHeight {
                    exifRow(label: config.localized("Dimensions"), value: "\(w) \u{00D7} \(h)")
                }
            }

            // Location section
            if data.latitude != nil || data.city != nil {
                sectionHeader(config.localized("Location"))
                if let location = formatLocation(data) {
                    exifRow(label: config.localized("Place"), value: location)
                }
                if let lat = data.latitude, let lon = data.longitude {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(config.localized("GPS"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .trailing)
                            .lineLimit(1)
                        Text(formatCoordinates(data) ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("Exif_GPS")
                        Button {
                            let label = formatLocation(data) ?? config.localized("Photo Location")
                            let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")&z=14")!
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "map")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(config.localized("Open in Maps"))
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                if let alt = data.altitude {
                    exifRow(label: config.localized("Altitude"), value: "\(Int(alt)) m")
                }
            }

            // Keywords section
            if !data.keywords.isEmpty {
                sectionHeader(config.localized("Keywords"))
                FlowLayout(spacing: 4) {
                    ForEach(data.keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("ExifKeyword_\(keyword)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Species sections

    @ViewBuilder
    private var speciesSections: some View {
        assignedSection
        candidatesSection
        searchSection
    }

    @ViewBuilder
    private var assignedSection: some View {
        let needsDivider = exifData?.isEmpty == false
        if isMulti {
            sectionHeader(
                String(format: config.localized("Editing %lld photos"), selection.count),
                showDivider: needsDivider
            )
        } else {
            sectionHeader(config.localized("Assigned"), showDivider: needsDivider)
        }
        if assignedRows.isEmpty {
            Text(config.localized("No species assigned"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("SpeciesEditPanel_EmptyAssigned")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(assignedRows.enumerated()), id: \.element.species.speciesID) { index, row in
                    assignedRow(row: row, isPrimary: !isMulti && index == 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        let available = availableCandidates
        if !available.isEmpty {
            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal, 12)
                Button {
                    isCandidatesExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(config.localized("OSEA Candidates"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)
                            .textCase(.uppercase)
                        Spacer()
                        Image(systemName: isCandidatesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SpeciesEditPanel_CandidatesToggle")
                .accessibilityValue(isCandidatesExpanded ? "expanded" : "collapsed")
            }

            if isCandidatesExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(available, id: \.speciesID) { match in
                        candidateRow(match: match)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
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
                    .focused($searchFieldFocused)
                    .onSubmit {
                        commitSearchQuery()
                    }
                    .onExitCommand {
                        searchFieldFocused = false
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

    // MARK: - Species row builders

    private func assignedRow(row: BatchSpeciesAggregator.AssignedRow, isPrimary: Bool) -> some View {
        let match = row.species
        return HStack(spacing: 6) {
            Image(systemName: isPrimary ? "crown.fill" : "bird.fill")
                .font(.system(size: 10))
                .foregroundStyle(isPrimary ? .yellow : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(speciesDisplayLabel(for: match))
                        .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                        .lineLimit(1)
                    if isMulti, row.photoCount < selectedPhotos.count {
                        Text("(\(row.photoCount)/\(selectedPhotos.count))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(match.scientificName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .italic()
                    .lineLimit(1)
            }
            Spacer()
            if !isPrimary {
                Button {
                    appState.setPrimarySpecies(ids: targetIDs, species: match)
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SpeciesEditPanel_MakePrimary_\(match.speciesID)")
                .help(config.localized("Make primary"))
            }
            Button {
                appState.removeSpecies(ids: targetIDs, species: match)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SpeciesEditPanel_Remove_\(match.speciesID)")
            .help(config.localized("Remove"))
        }
    }

    private func candidateRow(match: SpeciesMatch) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(speciesDisplayLabel(for: match))
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
                appState.addSpecies(ids: targetIDs, species: match)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SpeciesEditPanel_Add_\(match.speciesID)")
        }
    }

    private func searchResultRow(match: SpeciesMatch) -> some View {
        Button {
            appState.addSpecies(ids: targetIDs, species: match)
            searchQuery = ""
            searchResults = []
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(speciesDisplayLabel(for: match))
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
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Components

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

    private func exifRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Formatters

    private func formatNumber(_ value: Double) -> String {
        ExifFormatters.number(value)
    }

    private func formatExposure(_ data: EXIFData) -> String {
        ExifFormatters.exposure(shutterSpeed: data.shutterSpeed,
                                aperture: data.aperture,
                                iso: data.iso)
    }

    private func formatDate(_ raw: String, offset: String?) -> String {
        ExifFormatters.date(raw, offset: offset, locale: config.appLanguage.locale)
    }

    private func formatLocation(_ data: EXIFData) -> String? {
        ExifFormatters.location(city: data.city, state: data.state, country: data.country)
    }

    private func formatCoordinates(_ data: EXIFData) -> String? {
        ExifFormatters.coordinates(latitude: data.latitude, longitude: data.longitude)
    }

    private func speciesDisplayLabel(for match: SpeciesMatch) -> String {
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

    private func commitSearchQuery() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let match = searchResults.first else { return }
        appState.addSpecies(ids: targetIDs, species: match)
        searchQuery = ""
        searchResults = []
    }
}
