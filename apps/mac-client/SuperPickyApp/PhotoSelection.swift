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

import Observation

/// Multi-select state for the filmstrip. Backed by `PhotoSelectionEditor`
/// for the math; this wrapper owns observable state, click/keyboard
/// dispatch, and the activeID invariants.
///
/// Invariants:
///   - `activeID == nil` ⟺ `selectedIDs.isEmpty`
///   - `activeID != nil` ⟹ `selectedIDs.contains(activeID!)`
@Observable
final class PhotoSelection {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var activeID: UUID? = nil
    private(set) var anchorID: UUID? = nil

    var count: Int { selectedIDs.count }
    var isMulti: Bool { selectedIDs.count > 1 }
    func contains(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    // MARK: - Click handlers

    func click(_ id: UUID, photos: [Photo]) {
        selectedIDs = [id]
        activeID = id
        anchorID = id
    }

    func shiftClick(_ id: UUID, photos: [Photo]) {
        guard let anchor = anchorID else {
            click(id, photos: photos); return
        }
        let range = PhotoSelectionEditor.rangeIDs(from: anchor, to: id, in: photos)
        guard !range.isEmpty else { return }
        selectedIDs = Set(range)
        activeID = id
        // anchor preserved
    }

    func cmdClick(_ id: UUID, photos: [Photo]) {
        let wasPresent = selectedIDs.contains(id)
        PhotoSelectionEditor.toggle(id, in: &selectedIDs)
        if wasPresent {
            if activeID == id {
                activeID = firstSelectedInOrder(photos: photos)
                if activeID == nil { anchorID = nil }
            }
        } else {
            activeID = id
            anchorID = id
        }
    }

    // MARK: - Keyboard

    func arrow(direction: Int, photos: [Photo]) {
        if let id = activeID {
            selectedIDs = [id]
            anchorID = id
        }
        guard let next = PhotoSelectionEditor.neighbor(
            of: activeID, direction: direction, in: photos
        ) else { return }
        selectedIDs = [next]
        activeID = next
        anchorID = next
    }

    func shiftArrow(direction: Int, photos: [Photo]) {
        guard let active = activeID,
              let next = PhotoSelectionEditor.neighbor(
                of: active, direction: direction, in: photos
              ),
              next != active else { return }
        selectedIDs.insert(next)
        activeID = next
        if anchorID == nil { anchorID = active }
    }

    func selectAll(photos: [Photo]) {
        selectedIDs = Set(photos.map(\.id))
        if activeID == nil || !selectedIDs.contains(activeID!) {
            activeID = photos.first?.id
            anchorID = activeID
        }
    }

    func collapseToActive() {
        guard let active = activeID else { selectedIDs = []; return }
        selectedIDs = [active]
        anchorID = active
    }

    // MARK: - Lifecycle

    func clear() {
        selectedIDs = []
        activeID = nil
        anchorID = nil
    }

    /// Drop IDs no longer present in `photos`. If the active was dropped,
    /// fall back to the first remaining selected (in `photos` order),
    /// else `photos.first?.id`, else nil.
    func reconcile(with photos: [Photo]) {
        PhotoSelectionEditor.reconcile(set: &selectedIDs, against: photos)
        if let active = activeID, selectedIDs.contains(active) {
            if let anchor = anchorID, !selectedIDs.contains(anchor) {
                anchorID = active
            }
            return
        }
        let fallback = firstSelectedInOrder(photos: photos)
        activeID = fallback
        if let anchor = anchorID, !selectedIDs.contains(anchor) {
            anchorID = fallback
        }
        if activeID == nil {
            selectedIDs = []
            anchorID = nil
        }
    }

    // MARK: - Internals

    private func firstSelectedInOrder(photos: [Photo]) -> UUID? {
        photos.first(where: { selectedIDs.contains($0.id) })?.id
    }
}
