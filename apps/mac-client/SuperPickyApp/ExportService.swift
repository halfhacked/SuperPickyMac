import Foundation

struct ExportResult: Sendable {
    let exportedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let errors: [String]
}

struct ExportService {

    /// Compute the picks export destination: `<folder>-picks/` next to the source folder.
    static func picksDestination(for folder: URL) -> URL {
        let parent = folder.deletingLastPathComponent()
        let name = folder.lastPathComponent + "-picks"
        return parent.appendingPathComponent(name)
    }

    /// Export photos to destination folder with XMP sidecars.
    ///
    /// For each photo:
    /// 1. Writes XMP sidecar next to the original (source folder)
    /// 2. Checks if original already exists in destination — skips if so
    /// 3. Copies original RAW + XMP to destination
    ///
    /// Supports cancellation via `Task.isCancelled`.
    static func export(
        photos: [Photo],
        to destination: URL,
        onProgress: @Sendable @MainActor (Int, Int) -> Void
    ) async throws -> ExportResult {
        let fm = FileManager.default
        let total = photos.count

        var exported = 0
        var skipped = 0
        var failed = 0
        var errors: [String] = []

        for (index, photo) in photos.enumerated() {
            if Task.isCancelled {
                break
            }

            let originalURL = URL(fileURLWithPath: photo.filePath)
            let destFile = destination.appendingPathComponent(originalURL.lastPathComponent)

            // Check if original already exists in destination — skip
            if fm.fileExists(atPath: destFile.path) {
                skipped += 1
                await onProgress(index + 1, total)
                continue
            }

            do {
                // Write XMP sidecar next to original
                let sidecarURL = try XMPWriter.write(photo: photo)

                // Copy original to destination
                try fm.copyItem(at: originalURL, to: destFile)

                // Copy XMP to destination
                let destXMP = destination.appendingPathComponent(sidecarURL.lastPathComponent)
                if fm.fileExists(atPath: destXMP.path) {
                    try fm.removeItem(at: destXMP)
                }
                try fm.copyItem(at: sidecarURL, to: destXMP)

                exported += 1
            } catch {
                failed += 1
                errors.append("\(photo.filename): \(error.localizedDescription)")
            }

            await onProgress(index + 1, total)
        }

        return ExportResult(
            exportedCount: exported,
            skippedCount: skipped,
            failedCount: failed,
            errors: errors
        )
    }
}
