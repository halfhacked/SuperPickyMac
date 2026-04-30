import Foundation

/// Pure list-mutation helpers for `PhotoSelection`. No `@Observable` state,
/// no SwiftUI, no DB — keeps the range / toggle / reconcile math
/// unit-testable in isolation. Matches the pattern of
/// `SpeciesAssignmentEditor`.
enum PhotoSelectionEditor {

    /// Inclusive range of photo IDs from `anchor` to `target` in `photos`
    /// list order. Returns `[]` if either ID is missing from `photos`.
    /// Endpoint order is normalized — backward ranges work the same as
    /// forward.
    static func rangeIDs(from anchor: UUID, to target: UUID, in photos: [Photo]) -> [UUID] {
        guard
            let i = photos.firstIndex(where: { $0.id == anchor }),
            let j = photos.firstIndex(where: { $0.id == target })
        else { return [] }
        let lo = min(i, j), hi = max(i, j)
        return photos[lo...hi].map(\.id)
    }

    /// Add `id` to `set` if absent, remove it if present.
    static func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if !set.insert(id).inserted { set.remove(id) }
    }

    /// Drop IDs from `set` that are not present in `photos`. Used after
    /// filter / folder changes.
    static func reconcile(set: inout Set<UUID>, against photos: [Photo]) {
        let surviving = Set(photos.map(\.id))
        set.formIntersection(surviving)
    }

    /// Photo `direction` slots away from `from` in `photos`. `direction`
    /// of `+1` is next, `-1` is previous. Clamps at endpoints. Returns
    /// `photos.first?.id` when `from` is nil.
    static func neighbor(of from: UUID?, direction: Int, in photos: [Photo]) -> UUID? {
        guard !photos.isEmpty else { return nil }
        guard let from, let i = photos.firstIndex(where: { $0.id == from }) else {
            return photos.first?.id
        }
        let target = i + direction
        guard photos.indices.contains(target) else {
            return photos[i].id
        }
        return photos[target].id
    }
}
