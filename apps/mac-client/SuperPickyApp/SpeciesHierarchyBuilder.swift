import Foundation

/// Pure computation: groups photos into species hierarchy entries.
///
/// A photo may carry multiple species in its `assignedSpecies` list; the
/// builder emits one contribution *per assigned species*, so a photo
/// tagged with both A and B appears under both buckets. The primary
/// (first) entry still drives burst-dominant-species assignment so a
/// burst lives under one species only.
///
/// Bucket identity is `SpeciesMatch.speciesID` (eBird code or, when the
/// user entered a custom species, the scientific name). Never the
/// localized common name — renames don't jump buckets.
struct SpeciesHierarchyBuilder {

    /// Sentinel used internally so `Dictionary` can key off a non-optional
    /// value. Rendered as `isUnidentified: true` with `speciesID == nil` in
    /// the emitted `SpeciesEntry`.
    private static let unidentifiedKey = "__unidentified__"

    static func build(
        from photos: [Photo],
        sortOrder: SpeciesSortOrder = .name,
        displayName: (SpeciesEntry) -> String = { $0.name },
        locale: Locale = .current
    ) -> [SpeciesEntry] {
        // Assign each burst to its dominant species by highest confidence
        // primary ID. A burst spanning multiple species classifications
        // appears only once. Uses the PRIMARY species (assignedSpecies.first)
        // — not the union — so multi-species tagging on individual photos
        // doesn't duplicate bursts across buckets.
        var burstPrimaryByGroup: [UUID: String] = [:]
        var burstBestConfidence: [UUID: (id: String, confidence: Float)] = [:]
        var burstPhotos: [UUID: [Photo]] = [:]

        for photo in photos {
            guard let groupID = photo.burstGroupID else { continue }
            burstPhotos[groupID, default: []].append(photo)

            guard let primary = photo.assignedSpecies.first else { continue }
            let confidence = primary.confidence
            if let current = burstBestConfidence[groupID] {
                if confidence > current.confidence {
                    burstBestConfidence[groupID] = (primary.speciesID, confidence)
                }
            } else {
                burstBestConfidence[groupID] = (primary.speciesID, confidence)
            }
        }

        for groupID in burstPhotos.keys {
            burstPrimaryByGroup[groupID] = burstBestConfidence[groupID]?.id ?? unidentifiedKey
        }

        // Group photos by species ID. A multi-species photo contributes
        // to every bucket it's tagged with.
        struct Bucket {
            var scientificName: String?
            var commonName: String?
            var cnName: String?
            var photos: [Photo] = []
            var isUnidentified: Bool = false
        }
        var bySpeciesID: [String: Bucket] = [:]

        for photo in photos {
            let list = photo.assignedSpecies
            if list.isEmpty {
                var bucket = bySpeciesID[unidentifiedKey] ?? Bucket(isUnidentified: true)
                bucket.photos.append(photo)
                bySpeciesID[unidentifiedKey] = bucket
                continue
            }
            for match in list {
                var bucket = bySpeciesID[match.speciesID] ?? Bucket()
                if bucket.scientificName == nil { bucket.scientificName = match.scientificName }
                if bucket.commonName == nil { bucket.commonName = match.commonName }
                if bucket.cnName == nil { bucket.cnName = match.cnName }
                bucket.photos.append(photo)
                bySpeciesID[match.speciesID] = bucket
            }
        }

        let entries = bySpeciesID.map { id, bucket -> SpeciesEntry in
            // Only include burst groups whose primary species matches this
            // bucket. A multi-species photo still counts in every bucket,
            // but each of its bursts shows up under only one species.
            var burstGroupIDs: Set<UUID> = []
            var singleCount = 0
            for photo in bucket.photos {
                if let groupID = photo.burstGroupID {
                    if burstPrimaryByGroup[groupID] == id {
                        burstGroupIDs.insert(groupID)
                    }
                } else {
                    singleCount += 1
                }
            }

            let burstGroups = burstGroupIDs.map { groupID in
                let groupPhotos = burstPhotos[groupID] ?? []
                let best = groupPhotos.first { $0.isBurstBest }
                return BurstGroupEntry(
                    id: groupID,
                    count: groupPhotos.count,
                    bestFilename: best?.filename ?? groupPhotos.first?.filename
                )
            }.sorted { $0.count > $1.count }

            let label: String = {
                if bucket.isUnidentified { return String(localized: "Unidentified") }
                return bucket.commonName ?? bucket.scientificName ?? String(localized: "Unidentified")
            }()

            return SpeciesEntry(
                speciesID: bucket.isUnidentified ? nil : id,
                scientificName: bucket.scientificName,
                name: label,
                cnName: bucket.cnName,
                count: bucket.photos.count,
                burstGroups: burstGroups,
                singlePhotos: singleCount,
                isUnidentified: bucket.isUnidentified
            )
        }
        return sorted(entries: entries, by: sortOrder, displayName: displayName, locale: locale)
    }

    /// Unidentified always first, then by the chosen sort order. Name sort
    /// uses `displayName` and the matching `locale`, so e.g. Chinese rows
    /// sort by pinyin under `zh-Hans`, Japanese by gojūon under `ja`, etc.
    static func sorted(
        entries: [SpeciesEntry],
        by order: SpeciesSortOrder,
        displayName: (SpeciesEntry) -> String = { $0.name },
        locale: Locale = .current
    ) -> [SpeciesEntry] {
        entries.sorted { a, b in
            if a.isUnidentified != b.isUnidentified { return a.isUnidentified }
            switch order {
            case .name:
                return displayName(a).compare(displayName(b), options: [], range: nil, locale: locale) == .orderedAscending
            case .count:
                return a.count > b.count
            }
        }
    }
}
