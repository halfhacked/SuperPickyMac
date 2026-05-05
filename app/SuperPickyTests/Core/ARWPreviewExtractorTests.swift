import Testing
import Foundation
@testable import SuperPicky

/// Hand-built TIFF byte fixtures for the ARW IFD walker. The structure
/// is: TIFF header → IFD0 (empty, points at IFD1) → IFD1 (empty, points
/// at IFD2) → IFD2 (carries JpgFromRawStart 0x0201 + JpgFromRawLength
/// 0x0202) → JPEG bytes appended at a known offset.
@Suite struct ARWPreviewExtractorTests {

    // MARK: - Helpers

    private func u16le(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
    private func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Build a fixture: empty IFD0 → empty IFD1 → IFD2 with optional
    /// JpgFromRaw entries → JPEG bytes appended after IFD2's
    /// next-pointer. Returns (data, jpegOffset, jpegLength).
    private func makeFixture(jpegBytes: [UInt8],
                             includeStart: Bool = true,
                             includeLength: Bool = true) -> (Data, UInt32, UInt32) {
        var data = Data()
        // TIFF header
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])     // II + magic 42
        data.append(contentsOf: u32le(8))                     // IFD0 offset = 8

        // IFD0: 0 entries, next-IFD-offset = 14 (= 8 + 2 + 0 + 4)
        let ifd0Start = data.count
        data.append(contentsOf: u16le(0))
        let ifd1Offset = ifd0Start + 2 + 4
        data.append(contentsOf: u32le(UInt32(ifd1Offset)))

        // IFD1: 0 entries, next-IFD-offset = ifd2Offset
        data.append(contentsOf: u16le(0))
        let ifd2Offset = ifd1Offset + 2 + 4
        data.append(contentsOf: u32le(UInt32(ifd2Offset)))

        // IFD2: 0–2 entries (depending on flags) + 4-byte next-IFD = 0
        var ifd2Entries: [(UInt16, UInt32)] = []
        // We'll back-fill the value for JpgFromRawStart once we know the
        // append offset; for now write a placeholder.
        let entryCount = (includeStart ? 1 : 0) + (includeLength ? 1 : 0)
        data.append(contentsOf: u16le(UInt16(entryCount)))
        let entriesStart = data.count

        // Reserve entry slots
        for _ in 0..<entryCount {
            data.append(contentsOf: [UInt8](repeating: 0, count: 12))
        }
        data.append(contentsOf: u32le(0))   // next IFD = 0 (end)

        // JPEG bytes appended at the end
        let jpegOffset = UInt32(data.count)
        let jpegLength = UInt32(jpegBytes.count)
        data.append(contentsOf: jpegBytes)

        // Now back-fill IFD2 entries with the correct offset/length.
        var entryIdx = 0
        if includeStart {
            ifd2Entries.append((0x0201, jpegOffset))   // JpgFromRawStart
            let entry = entriesStart + entryIdx * 12
            data.replaceSubrange(entry..<(entry+12), with:
                u16le(0x0201) + u16le(4) + u32le(1) + u32le(jpegOffset))
            entryIdx += 1
        }
        if includeLength {
            ifd2Entries.append((0x0202, jpegLength))   // JpgFromRawLength
            let entry = entriesStart + entryIdx * 12
            data.replaceSubrange(entry..<(entry+12), with:
                u16le(0x0202) + u16le(4) + u32le(1) + u32le(jpegLength))
        }
        _ = ifd2Entries

        return (data, jpegOffset, jpegLength)
    }

    private let validJPEG: [UInt8] = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
        0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xD9
    ]

    // MARK: - Happy path

    @Test func extractsJpegFromValidIFD2() {
        let (data, off, len) = makeFixture(jpegBytes: validJPEG)
        let extracted = ARWPreviewExtractor.extractFullResJPEG(fromContainer: data)
        #expect(extracted != nil)
        #expect(extracted?.count == Int(len))
        #expect(Array(extracted!) == validJPEG)
        _ = off
    }

    // MARK: - Negative paths

    @Test func returnsNilWhenIFD2HasNoStartTag() {
        let (data, _, _) = makeFixture(jpegBytes: validJPEG, includeStart: false)
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenIFD2HasNoLengthTag() {
        let (data, _, _) = makeFixture(jpegBytes: validJPEG, includeLength: false)
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenChainTerminatesBeforeIFD2() {
        // Build a fixture where IFD0's next-offset = 0 (no IFD1).
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: u32le(8))
        data.append(contentsOf: u16le(0))      // IFD0 entry count
        data.append(contentsOf: u32le(0))      // next IFD = 0 (chain ends)
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenChainTerminatesAtIFD1() {
        // IFD0 → IFD1, but IFD1's next = 0
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: u32le(8))
        data.append(contentsOf: u16le(0))      // IFD0 count
        data.append(contentsOf: u32le(14))     // → IFD1 at offset 14
        data.append(contentsOf: u16le(0))      // IFD1 count
        data.append(contentsOf: u32le(0))      // IFD1 next = 0 → no IFD2
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenJpegBytesDoNotStartWithSOI() {
        // Replace JPEG SOI with garbage — extractor must reject.
        let bogus: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
        let (data, _, _) = makeFixture(jpegBytes: bogus)
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenJpegOffsetOutOfRange() {
        // Build fixture, then tamper with the start-offset value to point
        // past the end of the buffer.
        var (data, _, _) = makeFixture(jpegBytes: validJPEG)
        // Find IFD2 (at offset 20) and its first entry (offset 22).
        // Entry layout: tag(2) type(2) count(4) value(4)
        // Replace value with a huge offset.
        data.replaceSubrange(30..<34, with: u32le(0xFFFFFFFF))
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilOnNonTIFFContainer() {
        let data = Data([0xFF, 0x00, 0xAB, 0xCD])
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func returnsNilOnTruncatedTIFF() {
        // Valid TIFF magic but truncated before any IFD.
        let data = Data([0x49, 0x49, 0x2A, 0x00] + u32le(8))
        #expect(ARWPreviewExtractor.extractFullResJPEG(fromContainer: data) == nil)
    }

    @Test func handlesBigEndianByteOrder() {
        // Build the same fixture but with big-endian encoding.
        var data = Data()
        data.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])     // "MM" + magic 42 (big-endian)
        // IFD0 offset = 8 (big-endian)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x08])

        // IFD0: 0 entries, next = 14
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0E])

        // IFD1: 0 entries, next = 20
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x14])

        // IFD2: 2 entries + next=0
        data.append(contentsOf: [0x00, 0x02])
        let entriesStart = data.count
        // reserve 24 bytes for two entries + 4 for next
        data.append(contentsOf: [UInt8](repeating: 0, count: 12))
        data.append(contentsOf: [UInt8](repeating: 0, count: 12))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        let jpegOffset = UInt32(data.count)
        data.append(contentsOf: validJPEG)
        let jpegLength = UInt32(validJPEG.count)

        // Back-fill JpgFromRawStart entry
        data.replaceSubrange(entriesStart..<(entriesStart+12), with:
            [0x02, 0x01, 0x00, 0x04] +     // tag 0x0201 + type 4 (LONG)
            [0x00, 0x00, 0x00, 0x01] +     // count 1
            [
                UInt8((jpegOffset >> 24) & 0xFF),
                UInt8((jpegOffset >> 16) & 0xFF),
                UInt8((jpegOffset >> 8) & 0xFF),
                UInt8(jpegOffset & 0xFF)
            ])
        // JpgFromRawLength entry
        data.replaceSubrange((entriesStart+12)..<(entriesStart+24), with:
            [0x02, 0x02, 0x00, 0x04] +
            [0x00, 0x00, 0x00, 0x01] +
            [
                UInt8((jpegLength >> 24) & 0xFF),
                UInt8((jpegLength >> 16) & 0xFF),
                UInt8((jpegLength >> 8) & 0xFF),
                UInt8(jpegLength & 0xFF)
            ])

        let extracted = ARWPreviewExtractor.extractFullResJPEG(fromContainer: data)
        #expect(extracted != nil)
        #expect(Array(extracted!) == validJPEG)
    }
}
