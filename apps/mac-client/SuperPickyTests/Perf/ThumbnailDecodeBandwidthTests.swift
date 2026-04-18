import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

/// Manual diagnostic harness: decodes the same RAW files from two
/// locations to separate "drive is the bottleneck" from "decoder is
/// the bottleneck." Run cold and warm to control for FS cache.
///
/// Interpretation:
/// - `warm_external ≈ warm_local` → CPU/decoder is the ceiling.
/// - `cold_external ≫ cold_local` → drive matters on first touch.
/// - `cold_local ≫ warm_local` by a wide margin → file I/O, not decode.
///
/// Not run by default. Invoke explicitly:
///   EXTERNAL_ARW_FOLDER="<external>" \
///   LOCAL_ARW_FOLDER="<local>" \
///   swift test --filter ThumbnailDecodeBandwidthTests
///
/// Copy the same ~20 ARWs into both folders before running so the two
/// sets are byte-identical.
@Suite(.serialized)
struct ThumbnailDecodeBandwidthTests {

    private static let sampleSize = 20
    private static let parallelism = 6  // match the pipeline's ML fan-out

    private func arwFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.sampleSize)
            .map { $0 }
    }

    private func decodeThumbnail(_ fileURL: URL) -> Bool {
        (try? RAWConverter().decode(fileURL: fileURL)) != nil
    }

    /// 6-way bounded concurrent decode, matching the pipeline's ML fan-out.
    private func timeDecode(_ files: [URL]) async -> (elapsed: Double, rate: Double) {
        let start = DispatchTime.now()
        await withTaskGroup(of: Void.self) { group in
            var nextIdx = 0
            let initial = min(Self.parallelism, files.count)
            while nextIdx < initial {
                let url = files[nextIdx]
                group.addTask { _ = self.decodeThumbnail(url) }
                nextIdx += 1
            }
            for await _ in group {
                if nextIdx < files.count {
                    let url = files[nextIdx]
                    group.addTask { _ = self.decodeThumbnail(url) }
                    nextIdx += 1
                }
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return (elapsed, Double(files.count) / elapsed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXTERNAL_ARW_FOLDER"] != nil
                       && ProcessInfo.processInfo.environment["LOCAL_ARW_FOLDER"] != nil))
    func externalVsLocal() async throws {
        let env = ProcessInfo.processInfo.environment
        let extPath = env["EXTERNAL_ARW_FOLDER"]!
        let localPath = env["LOCAL_ARW_FOLDER"]!
        let external = URL(fileURLWithPath: extPath)
        let local = URL(fileURLWithPath: localPath)

        let externalFiles = try arwFiles(in: external)
        let localFiles = try arwFiles(in: local)
        try #require(externalFiles.count == Self.sampleSize,
                     "Need \(Self.sampleSize) ARWs in \(extPath), found \(externalFiles.count)")
        try #require(localFiles.count == Self.sampleSize,
                     "Need \(Self.sampleSize) ARWs in \(localPath), found \(localFiles.count)")

        // Pass 1 — cold(ish). We don't force `purge` because it needs
        // sudo; instead the two locations are decoded in the order the
        // caller cares about and we trust that first-touch reflects
        // real-world behavior for a folder larger than FS cache.
        let extCold = await timeDecode(externalFiles)
        let locCold = await timeDecode(localFiles)

        // Pass 2 — warm. Pages from pass 1 are now in the unified
        // buffer cache, so the rate reflects decode cost alone.
        let extWarm = await timeDecode(externalFiles)
        let locWarm = await timeDecode(localFiles)

        print(String(format: "cold external: %.2fs → %.1f/s", extCold.elapsed, extCold.rate))
        print(String(format: "cold local   : %.2fs → %.1f/s", locCold.elapsed, locCold.rate))
        print(String(format: "warm external: %.2fs → %.1f/s", extWarm.elapsed, extWarm.rate))
        print(String(format: "warm local   : %.2fs → %.1f/s", locWarm.elapsed, locWarm.rate))

        // Interpretation hints as test output — the test always passes;
        // the numbers and this verdict are the payload.
        let coldRatio = extCold.elapsed / locCold.elapsed
        let warmRatio = extWarm.elapsed / locWarm.elapsed
        let decoderCeiling = min(extWarm.rate, locWarm.rate)
        print(String(format: "cold ratio (ext/local): %.2fx", coldRatio))
        print(String(format: "warm ratio (ext/local): %.2fx", warmRatio))
        print(String(format: "decoder ceiling (warm min): %.1f/s", decoderCeiling))
        if warmRatio < 1.15 && coldRatio < 1.15 {
            print("→ Verdict: DECODER is the ceiling. Drive doesn't matter at this rate.")
        } else if coldRatio > 1.5 && warmRatio < 1.15 {
            print("→ Verdict: Drive matters on COLD reads; CPU caps warm rate.")
        } else if warmRatio > 1.5 {
            print("→ Verdict: EXTERNAL DRIVE is the ceiling even warm — unexpected.")
        }
    }
}
