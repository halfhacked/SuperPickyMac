import Foundation

struct SpeciesHierarchyChange {
    let previous: Photo
    let updated: Photo
}

/// Pure computation: groups photos into species hierarchy entries.
///
/// A photo may carry multiple species in its `assignedSpecies` list; the
/// builder emits one contribution *per assigned species*, so a photo
/// tagged with both A and B appears under both buckets. Bursts follow
/// the same rule: a burst whose members are tagged with species A and B
/// appears under both A and B, each with a `BurstGroupEntry` carrying
/// the full burst size.
///
/// Bucket identity is `SpeciesMatch.speciesID` (eBird code or, when the
/// user entered a custom species, the scientific name). Never the
/// localized common name — renames don't jump buckets.
struct SpeciesHierarchyBuilder {

    /// Sentinel used internally so `Dictionary` can key off a non-optional
    /// value. Rendered as `isUnidentified: true` with `speciesID == nil` in
    /// the emitted `SpeciesEntry`.
    private static let unidentifiedKey = "__unidentified__"

    private struct BucketDelta {
        var count = 0
        var picks = 0
        var singlePhotos = 0
        var singlePicks = 0
        var metadata: SpeciesMatch?
        var replacesMetadata = false
        var upsertedBursts: [UUID: BurstGroupEntry] = [:]
        var removedBursts: Set<UUID> = []
    }

    static func build(
        from photos: [Photo],
        sortOrder: SpeciesSortOrder = .name,
        displayName: (SpeciesEntry) -> String = { $0.name },
        locale: Locale = .current
    ) -> [SpeciesEntry] {
        // Group burst members by group ID so each burst emits one
        // BurstGroupEntry per bucket it's attached to, carrying the full
        // burst size.
        var burstPhotos: [UUID: [Photo]] = [:]
        for photo in photos {
            guard let groupID = photo.burstGroupID else { continue }
            burstPhotos[groupID, default: []].append(photo)
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
            // A burst attaches to every bucket any of its members is
            // tagged with. Because `bucket.photos` already filters to
            // photos whose `assignedSpecies` includes `id`, any burst
            // member seen here implies the burst is tagged with `id`.
            var burstGroupIDs: Set<UUID> = []
            var singleCount = 0
            for photo in bucket.photos {
                if let groupID = photo.burstGroupID {
                    burstGroupIDs.insert(groupID)
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
                    pickCount: groupPhotos.lazy.filter(\.isPicked).count,
                    bestFilename: best?.filename ?? groupPhotos.first?.filename
                )
            }.sorted { $0.count > $1.count }

            var singlePicks = 0
            var speciesPicks = 0
            for photo in bucket.photos where photo.isPicked {
                speciesPicks += 1
                if photo.burstGroupID == nil { singlePicks += 1 }
            }

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
                picks: speciesPicks,
                burstGroups: burstGroups,
                singlePhotos: singleCount,
                singlePicks: singlePicks,
                isUnidentified: bucket.isUnidentified
            )
        }
        return sorted(entries: entries, by: sortOrder, displayName: displayName, locale: locale)
    }

    /// Apply a batch of species-only photo changes without rebuilding from the
    /// full library. For every touched burst, `changes` must include all of its
    /// members (unchanged members included) so burst membership remains exact.
    static func applySpeciesChanges(
        entries: [SpeciesEntry],
        changes: [SpeciesHierarchyChange],
        sortOrder: SpeciesSortOrder = .name,
        displayName: (SpeciesEntry) -> String = { $0.name },
        locale: Locale = .current
    ) -> [SpeciesEntry] {
        guard !changes.isEmpty else { return entries }

        var deltas: [String: BucketDelta] = [:]
        var changesByBurst: [UUID: [SpeciesHierarchyChange]] = [:]

        for change in changes {
            let beforeMatches = matchesByKey(for: change.previous)
            let afterMatches = matchesByKey(for: change.updated)
            let beforeKeys = bucketKeys(for: beforeMatches)
            let afterKeys = bucketKeys(for: afterMatches)

            for key in beforeKeys.union(afterKeys) {
                let wasMember = beforeKeys.contains(key)
                let isMember = afterKeys.contains(key)
                var delta = deltas[key, default: BucketDelta()]
                delta.count += (isMember ? 1 : 0) - (wasMember ? 1 : 0)
                delta.picks += (isMember && change.updated.isPicked ? 1 : 0)
                    - (wasMember && change.previous.isPicked ? 1 : 0)

                if change.previous.burstGroupID == nil && change.updated.burstGroupID == nil {
                    delta.singlePhotos += (isMember ? 1 : 0) - (wasMember ? 1 : 0)
                    delta.singlePicks += (isMember && change.updated.isPicked ? 1 : 0)
                        - (wasMember && change.previous.isPicked ? 1 : 0)
                }

                if let after = afterMatches[key] {
                    if let before = beforeMatches[key],
                       hierarchyMetadataDiffers(before, after) {
                        delta.metadata = after
                        delta.replacesMetadata = true
                    } else if delta.metadata == nil {
                        delta.metadata = after
                    }
                }
                deltas[key] = delta
            }

            if let groupID = change.updated.burstGroupID ?? change.previous.burstGroupID {
                changesByBurst[groupID, default: []].append(change)
            }
        }

        for (groupID, groupChanges) in changesByBurst {
            let beforeKeys = groupChanges.reduce(into: Set<String>()) { result, change in
                result.formUnion(bucketKeys(for: matchesByKey(for: change.previous)))
            }
            let afterKeys = groupChanges.reduce(into: Set<String>()) { result, change in
                result.formUnion(bucketKeys(for: matchesByKey(for: change.updated)))
            }
            let updatedPhotos = groupChanges.map(\.updated)
            let best = updatedPhotos.first { $0.isBurstBest }
            let burst = BurstGroupEntry(
                id: groupID,
                count: updatedPhotos.count,
                pickCount: updatedPhotos.lazy.filter(\.isPicked).count,
                bestFilename: best?.filename ?? updatedPhotos.first?.filename
            )

            for key in beforeKeys.union(afterKeys) {
                var delta = deltas[key, default: BucketDelta()]
                if afterKeys.contains(key) {
                    delta.upsertedBursts[groupID] = burst
                    delta.removedBursts.remove(groupID)
                } else {
                    delta.upsertedBursts.removeValue(forKey: groupID)
                    delta.removedBursts.insert(groupID)
                }
                deltas[key] = delta
            }
        }

        var entriesByKey = Dictionary(
            uniqueKeysWithValues: entries.map { (($0.speciesID ?? unidentifiedKey), $0) }
        )
        for (key, delta) in deltas {
            let existing = entriesByKey[key]
            let count = max(0, (existing?.count ?? 0) + delta.count)
            guard count > 0 else {
                entriesByKey.removeValue(forKey: key)
                continue
            }

            var burstsByID = Dictionary(
                uniqueKeysWithValues: (existing?.burstGroups ?? []).map { ($0.id, $0) }
            )
            for groupID in delta.removedBursts {
                burstsByID.removeValue(forKey: groupID)
            }
            for (groupID, burst) in delta.upsertedBursts {
                burstsByID[groupID] = burst
            }

            let isUnidentified = key == unidentifiedKey
            let scientificName = delta.replacesMetadata
                ? delta.metadata?.scientificName
                : existing?.scientificName ?? delta.metadata?.scientificName
            let name: String
            if isUnidentified {
                name = String(localized: "Unidentified")
            } else if delta.replacesMetadata {
                name = delta.metadata?.commonName
                    ?? delta.metadata?.scientificName
                    ?? existing?.name
                    ?? key
            } else {
                name = existing?.name
                    ?? delta.metadata?.commonName
                    ?? delta.metadata?.scientificName
                    ?? key
            }
            let cnName = delta.replacesMetadata
                ? delta.metadata?.cnName
                : existing?.cnName ?? delta.metadata?.cnName

            entriesByKey[key] = SpeciesEntry(
                speciesID: isUnidentified ? nil : key,
                scientificName: scientificName,
                name: name,
                cnName: cnName,
                count: count,
                picks: max(0, (existing?.picks ?? 0) + delta.picks),
                burstGroups: burstsByID.values.sorted { $0.count > $1.count },
                singlePhotos: max(0, (existing?.singlePhotos ?? 0) + delta.singlePhotos),
                singlePicks: max(0, (existing?.singlePicks ?? 0) + delta.singlePicks),
                isUnidentified: isUnidentified
            )
        }

        return sorted(
            entries: Array(entriesByKey.values),
            by: sortOrder,
            displayName: displayName,
            locale: locale
        )
    }

    private static func matchesByKey(for photo: Photo) -> [String: SpeciesMatch] {
        var result: [String: SpeciesMatch] = [:]
        for match in photo.assignedSpecies where result[match.speciesID] == nil {
            result[match.speciesID] = match
        }
        return result
    }

    private static func bucketKeys(for matches: [String: SpeciesMatch]) -> Set<String> {
        matches.isEmpty ? [unidentifiedKey] : Set(matches.keys)
    }

    private static func hierarchyMetadataDiffers(
        _ before: SpeciesMatch,
        _ after: SpeciesMatch
    ) -> Bool {
        before.scientificName != after.scientificName
            || before.commonName != after.commonName
            || before.cnName != after.cnName
    }

    /// Apply a single-photo delta — `remove` an old primary-bucket
    /// contribution and/or `add` a new one — without rebuilding the whole
    /// hierarchy. Only touches the two buckets involved. Callers should
    /// `sorted(...)` afterwards when ordering matters.
    static func applyIncremental(
        entries: [SpeciesEntry],
        removing old: Photo? = nil,
        adding newPhoto: Photo? = nil
    ) -> [SpeciesEntry] {
        var updated = entries
        if let old { removePrimary(from: &updated, of: old) }
        if let newPhoto { addPrimary(to: &updated, of: newPhoto) }
        return updated
    }

    private static func bucketKey(for photo: Photo) -> String {
        photo.assignedSpecies.first?.speciesID ?? unidentifiedKey
    }

    private static func indexOfBucket(in entries: [SpeciesEntry], key: String) -> Int? {
        entries.firstIndex { ($0.speciesID ?? unidentifiedKey) == key }
    }

    private static func addPrimary(to entries: inout [SpeciesEntry], of photo: Photo) {
        let primary = photo.assignedSpecies.first
        let key = bucketKey(for: photo)
        let pickDelta = photo.isPicked ? 1 : 0
        if let idx = indexOfBucket(in: entries, key: key) {
            let existing = entries[idx]
            entries[idx] = SpeciesEntry(
                speciesID: existing.speciesID,
                scientificName: existing.scientificName ?? primary?.scientificName,
                name: existing.name,
                cnName: existing.cnName ?? primary?.cnName,
                count: existing.count + 1,
                picks: existing.picks + pickDelta,
                burstGroups: existing.burstGroups,
                singlePhotos: existing.singlePhotos + 1,
                singlePicks: existing.singlePicks + pickDelta,
                isUnidentified: existing.isUnidentified
            )
        } else {
            let hasSpecies = primary != nil
            let name = primary?.commonName
                ?? primary?.scientificName
                ?? String(localized: "Unidentified")
            entries.append(SpeciesEntry(
                speciesID: primary?.speciesID,
                scientificName: primary?.scientificName,
                name: name,
                cnName: primary?.cnName,
                count: 1,
                picks: pickDelta,
                burstGroups: [],
                singlePhotos: 1,
                singlePicks: pickDelta,
                isUnidentified: !hasSpecies
            ))
        }
    }

    private static func removePrimary(from entries: inout [SpeciesEntry], of photo: Photo) {
        let key = bucketKey(for: photo)
        guard let idx = indexOfBucket(in: entries, key: key) else { return }
        let existing = entries[idx]
        if existing.count <= 1 && existing.burstGroups.isEmpty {
            entries.remove(at: idx)
            return
        }
        let pickDelta = photo.isPicked ? 1 : 0
        entries[idx] = SpeciesEntry(
            speciesID: existing.speciesID,
            scientificName: existing.scientificName,
            name: existing.name,
            cnName: existing.cnName,
            count: max(0, existing.count - 1),
            picks: max(0, existing.picks - pickDelta),
            burstGroups: existing.burstGroups,
            singlePhotos: max(0, existing.singlePhotos - 1),
            singlePicks: max(0, existing.singlePicks - pickDelta),
            isUnidentified: existing.isUnidentified
        )
    }

    /// Apply a pick-toggle delta to every bucket (species + any burst/singles
    /// counter) the photo participates in. Multi-species photos contribute to
    /// every tagged bucket, matching `build`'s fan-out.
    static func applyPickToggle(
        entries: [SpeciesEntry],
        photo: Photo,
        newIsPick: Bool
    ) -> [SpeciesEntry] {
        let delta = newIsPick ? 1 : -1
        var updated = entries

        let keys: Set<String>
        if photo.assignedSpecies.isEmpty {
            keys = [unidentifiedKey]
        } else {
            keys = Set(photo.assignedSpecies.map(\.speciesID))
        }

        for key in keys {
            guard let idx = indexOfBucket(in: updated, key: key) else { continue }
            let existing = updated[idx]
            let newBursts: [BurstGroupEntry]
            if let groupID = photo.burstGroupID {
                newBursts = existing.burstGroups.map { burst in
                    guard burst.id == groupID else { return burst }
                    return BurstGroupEntry(
                        id: burst.id,
                        count: burst.count,
                        pickCount: max(0, burst.pickCount + delta),
                        bestFilename: burst.bestFilename
                    )
                }
            } else {
                newBursts = existing.burstGroups
            }
            let singleDelta = photo.burstGroupID == nil ? delta : 0
            updated[idx] = SpeciesEntry(
                speciesID: existing.speciesID,
                scientificName: existing.scientificName,
                name: existing.name,
                cnName: existing.cnName,
                count: existing.count,
                picks: max(0, existing.picks + delta),
                burstGroups: newBursts,
                singlePhotos: existing.singlePhotos,
                singlePicks: max(0, existing.singlePicks + singleDelta),
                isUnidentified: existing.isUnidentified
            )
        }
        return updated
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
