import Foundation

/// Pure computation: groups photos into species hierarchy entries.
struct SpeciesHierarchyBuilder {
    static func build(from photos: [Photo]) -> [SpeciesEntry] {
        // Assign each burst to its dominant species by highest confidence ID.
        // A burst spanning multiple species classifications appears only once.
        var burstToSpecies: [UUID: String] = [:]
        var burstBestConfidence: [UUID: (species: String, confidence: Float)] = [:]
        var burstPhotos: [UUID: [Photo]] = [:]

        for photo in photos {
            guard let groupID = photo.burstGroupID else { continue }
            burstPhotos[groupID, default: []].append(photo)

            guard let name = photo.speciesCommonName ?? photo.speciesScientificName else { continue }
            let confidence = photo.speciesConfidence ?? 0
            if let current = burstBestConfidence[groupID] {
                if confidence > current.confidence {
                    burstBestConfidence[groupID] = (name, confidence)
                }
            } else {
                burstBestConfidence[groupID] = (name, confidence)
            }
        }

        for groupID in burstPhotos.keys {
            burstToSpecies[groupID] = burstBestConfidence[groupID]?.species ?? "Unidentified"
        }

        // Group photos by species
        var bySpecies: [String: (photos: [Photo], isUnidentified: Bool)] = [:]
        for photo in photos {
            let hasSpecies = photo.speciesScientificName != nil
            let name = photo.speciesCommonName ?? photo.speciesScientificName ?? String(localized: "Unidentified")
            var entry = bySpecies[name] ?? (photos: [], isUnidentified: !hasSpecies)
            entry.photos.append(photo)
            bySpecies[name] = entry
        }

        return bySpecies.map { name, entry in
            // Only include burst groups whose dominant species matches this entry
            var burstGroupIDs: Set<UUID> = []
            var singleCount = 0
            for photo in entry.photos {
                if let groupID = photo.burstGroupID {
                    if burstToSpecies[groupID] == name {
                        burstGroupIDs.insert(groupID)
                    }
                    // Photos in bursts owned by another species don't count as singles
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

            return SpeciesEntry(
                name: name,
                cnName: entry.photos.first?.speciesCnName,
                count: entry.photos.count,
                burstGroups: burstGroups,
                singlePhotos: singleCount,
                isUnidentified: entry.isUnidentified
            )
        }.sorted {
            // Unidentified always first, then by count
            if $0.isUnidentified != $1.isUnidentified { return $0.isUnidentified }
            return $0.count > $1.count
        }
    }
}
