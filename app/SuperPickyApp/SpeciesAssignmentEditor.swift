import Foundation

/// Pure list-mutation helpers used by `SpeciesEditPanelView` to keep the
/// add / remove / make-primary / decode logic out of the SwiftUI body and
/// unit-testable in isolation.
enum SpeciesAssignmentEditor {

    /// Append `match` to `assigned` if its speciesID isn't already present.
    /// Returns the updated list, or `nil` when `match` is a duplicate.
    static func add(_ match: SpeciesMatch, to assigned: [SpeciesMatch]) -> [SpeciesMatch]? {
        guard !assigned.contains(where: { $0.speciesID == match.speciesID }) else { return nil }
        return assigned + [match]
    }

    /// Remove the entry at `index`. Precondition: `index` is valid.
    static func remove(at index: Int, from assigned: [SpeciesMatch]) -> [SpeciesMatch] {
        var updated = assigned
        updated.remove(at: index)
        return updated
    }

    /// Move `assigned[index]` to slot 0 (primary). Precondition: `index` is valid.
    static func makePrimary(at index: Int, in assigned: [SpeciesMatch]) -> [SpeciesMatch] {
        var updated = assigned
        let entry = updated.remove(at: index)
        updated.insert(entry, at: 0)
        return updated
    }

    /// Candidates from `all` whose speciesID isn't already in `assigned`.
    static func unassignedCandidates(from all: [SpeciesMatch],
                                     excluding assigned: [SpeciesMatch]) -> [SpeciesMatch] {
        let assignedIDs = Set(assigned.map(\.speciesID))
        return all.filter { !assignedIDs.contains($0.speciesID) }
    }

    /// Decode a `Photo.speciesTop5JSON` blob into a list of `SpeciesMatch`.
    /// Returns `[]` on nil, empty, or malformed input (decode errors are
    /// swallowed — the UI just shows an empty candidates section).
    static func decodeCandidates(fromJSON json: String?) -> [SpeciesMatch] {
        guard let json,
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([SpeciesMatch].self, from: data) else {
            return []
        }
        return list
    }
}
