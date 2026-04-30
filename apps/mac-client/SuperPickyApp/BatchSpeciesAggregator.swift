import Foundation

/// Aggregates species data across a set of photos for the batch-mode
/// species edit panel. Pure — no DB, no UI. Sibling to
/// `SpeciesAssignmentEditor`.
enum BatchSpeciesAggregator {

    struct AssignedRow {
        let species: SpeciesMatch
        let photoCount: Int
    }

    /// Union of `photo.assignedSpecies` across all `photos`. Returns one
    /// row per distinct `speciesID`, with `photoCount` = number of
    /// `photos` whose assigned list contains that species. Sorted by
    /// `photoCount` descending, then by `commonName` ascending (case-
    /// insensitive) for deterministic tie-breaks.
    static func unionAssigned(_ photos: [Photo]) -> [AssignedRow] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: SpeciesMatch] = [:]
        for photo in photos {
            for sp in photo.assignedSpecies {
                counts[sp.speciesID, default: 0] += 1
                if firstSeen[sp.speciesID] == nil {
                    firstSeen[sp.speciesID] = sp
                }
            }
        }
        return counts.map { id, count in
            AssignedRow(species: firstSeen[id]!, photoCount: count)
        }.sorted { lhs, rhs in
            if lhs.photoCount != rhs.photoCount {
                return lhs.photoCount > rhs.photoCount
            }
            let l = lhs.species.commonName ?? lhs.species.scientificName
            let r = rhs.species.commonName ?? rhs.species.scientificName
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }
    }

    /// Top `limit` candidates across `photos`, drawn from each photo's
    /// stored `speciesTop5JSON`. Deduped by `speciesID`. Each entry's
    /// confidence is the **max** observed across photos that surfaced it.
    /// Sorted by confidence descending, with `commonName` tie-break.
    /// Malformed or nil JSON contributes no candidates.
    static func topCandidates(_ photos: [Photo], limit: Int = 10) -> [SpeciesMatch] {
        var bestByID: [String: SpeciesMatch] = [:]
        for photo in photos {
            let cs = SpeciesAssignmentEditor.decodeCandidates(fromJSON: photo.speciesTop5JSON)
            for c in cs {
                if let existing = bestByID[c.speciesID] {
                    if c.confidence > existing.confidence {
                        bestByID[c.speciesID] = c
                    }
                } else {
                    bestByID[c.speciesID] = c
                }
            }
        }
        return bestByID.values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            let l = lhs.commonName ?? lhs.scientificName
            let r = rhs.commonName ?? rhs.scientificName
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }.prefix(limit).map { $0 }
    }
}
