import Testing
import Foundation
@testable import SuperPicky

/// Unit tests for the raw-bytes Sony MakerNote IFD walker.
/// Test fixtures are hand-built TIFF + IFD byte buffers so we don't
/// need a real ARW on disk.
@Suite struct SonyMakerNoteReaderTests {

    // MARK: - Fixture builder

    /// Builds a minimal valid little-endian TIFF container with one
    /// IFD0 entry pointing at an ExifIFD that contains a MakerNote
    /// pointer to a Sony5-style sub-IFD with the supplied entries.
    /// All offsets are TIFF-base-relative.
    private func makeFixture(sonyEntries: [SonyEntry], sonyHeaderPrefix: Bool = false) -> Data {
        var data = Data()
        // --- TIFF header (8 bytes) ---
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])     // "II" little-endian + magic 42
        data.append(contentsOf: u32le(8))                     // IFD0 offset = 8

        // --- IFD0 at offset 8 ---
        // 1 entry: ExifIFD pointer (tag 0x8769, type 4 LONG, count 1, value=offset of ExifIFD)
        let ifd0Start = data.count
        let ifd0EntryCount: UInt16 = 1
        data.append(contentsOf: u16le(ifd0EntryCount))

        // Compute layout: ExifIFD will follow IFD0 (which is 2 + 12 + 4 = 18 bytes).
        // ExifIFD: 1 entry (MakerNote pointer 0x927C) + 2 bytes count + 4 bytes nextIFD = 18 bytes.
        // Then comes the MakerNote data (Sony IFD).
        let exifIFDOffset = ifd0Start + 2 + 12 + 4              // start of ExifIFD
        let makerNoteOffset = exifIFDOffset + 2 + 12 + 4         // start of MakerNote bytes
        // Sony MakerNote layout: optional 12-byte "SONY DSC \0\0\0" header,
        // then IFD (2-byte count + N×12-byte entries + 4-byte next-IFD).
        let sonyHeaderLen = sonyHeaderPrefix ? 12 : 0
        let sonyIFDStart = makerNoteOffset + sonyHeaderLen
        let sonyIFDEntriesStart = sonyIFDStart + 2
        let sonyIFDEnd = sonyIFDEntriesStart + sonyEntries.count * 12 + 4

        // IFD0 entry: ExifIFD pointer
        data.append(contentsOf: u16le(0x8769))                // tag
        data.append(contentsOf: u16le(4))                     // type = LONG
        data.append(contentsOf: u32le(1))                     // count
        data.append(contentsOf: u32le(UInt32(exifIFDOffset))) // value = offset
        data.append(contentsOf: u32le(0))                     // next IFD = 0

        // --- ExifIFD ---
        data.append(contentsOf: u16le(1))                     // entry count
        // MakerNote pointer (tag 0x927C, type 7 UNDEFINED, count = full MakerNote size)
        let mnByteCount = sonyHeaderLen + 2 + sonyEntries.count * 12 + 4
            + sonyEntries.compactMap(\.outOfLineBytes).map { $0.count }.reduce(0, +)
        data.append(contentsOf: u16le(0x927C))                // tag
        data.append(contentsOf: u16le(7))                     // type = UNDEFINED
        data.append(contentsOf: u32le(UInt32(mnByteCount)))   // count = byte length
        data.append(contentsOf: u32le(UInt32(makerNoteOffset)))// value = offset
        data.append(contentsOf: u32le(0))                     // next IFD = 0

        // --- MakerNote header (optional) ---
        if sonyHeaderPrefix {
            data.append(contentsOf: [0x53, 0x4F, 0x4E, 0x59, 0x20,    // "SONY "
                                      0x44, 0x53, 0x43, 0x20,         // "DSC "
                                      0x00, 0x00, 0x00])              // 3 nulls
        }

        // --- Sony IFD ---
        data.append(contentsOf: u16le(UInt16(sonyEntries.count)))
        // Out-of-line payloads go after all 12-byte entry slots + the
        // 4-byte next-IFD field. Track positions as we write entries.
        var payloadCursor = sonyIFDEnd
        var payloads: [(offset: Int, bytes: [UInt8])] = []
        for entry in sonyEntries {
            data.append(contentsOf: u16le(entry.tag))
            data.append(contentsOf: u16le(entry.type))
            data.append(contentsOf: u32le(UInt32(entry.count)))
            switch entry.valueOrOffset {
            case .inline(let bytes):
                var padded = bytes
                while padded.count < 4 { padded.append(0) }
                data.append(contentsOf: padded.prefix(4))
            case .outOfLine(let bytes):
                data.append(contentsOf: u32le(UInt32(payloadCursor)))
                payloads.append((payloadCursor, bytes))
                payloadCursor += bytes.count
            }
        }
        data.append(contentsOf: u32le(0))    // next IFD = 0

        // --- Out-of-line payloads ---
        for (offset, bytes) in payloads {
            // Pad with zeros if there are gaps (shouldn't happen here).
            while data.count < offset { data.append(0) }
            data.append(contentsOf: bytes)
        }
        return data
    }

    private struct SonyEntry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let valueOrOffset: Value
        var outOfLineBytes: [UInt8]? {
            if case .outOfLine(let b) = valueOrOffset { return b }
            return nil
        }
        enum Value {
            case inline([UInt8])
            case outOfLine([UInt8])
        }
    }

    private func u16le(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }
    private func u32le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }

    // MARK: - Tests

    @Test func parsesSonyA1FocusTags() {
        // FocusLocation (0x2027) int16u[4] = {5616, 3744, 2860, 2106}
        // FocusFrameSize (0x2037) undef[6] read as int16u[3] = {421, 421, 257}
        // FocusMode (0x201B) int8u[1] = {3} (AF-C)
        let focLocBytes: [UInt8] = u16le(5616) + u16le(3744) + u16le(2860) + u16le(2106)
        let focFrameBytes: [UInt8] = u16le(421) + u16le(421) + u16le(257)
        let entries = [
            SonyEntry(tag: 0x201B, type: 1, count: 1,
                      valueOrOffset: .inline([3])),
            SonyEntry(tag: 0x2027, type: 3, count: 4,
                      valueOrOffset: .outOfLine(focLocBytes)),
            SonyEntry(tag: 0x2037, type: 7, count: 6,
                      valueOrOffset: .outOfLine(focFrameBytes))
        ]
        let data = makeFixture(sonyEntries: entries)
        let result = SonyMakerNoteReader.readFocusData(fromContainer: data)
        #expect(result != nil)
        #expect(result?["FocusLocation"] as? [Int] == [5616, 3744, 2860, 2106])
        #expect(result?["FocusFrameSize"] as? [Int] == [421, 421, 257])
        #expect(result?["FocusMode"] as? Int == 3)
    }

    @Test func handlesLegacySonyDscPrefix() {
        // Older bodies prefix the MakerNote IFD with "SONY DSC \0\0\0".
        let entries = [
            SonyEntry(tag: 0x201B, type: 1, count: 1,
                      valueOrOffset: .inline([2])),    // AF-S
            SonyEntry(tag: 0x2027, type: 3, count: 4,
                      valueOrOffset: .outOfLine(u16le(6000) + u16le(4000) + u16le(3000) + u16le(2000)))
        ]
        let data = makeFixture(sonyEntries: entries, sonyHeaderPrefix: true)
        let result = SonyMakerNoteReader.readFocusData(fromContainer: data)
        #expect(result?["FocusLocation"] as? [Int] == [6000, 4000, 3000, 2000])
        #expect(result?["FocusMode"] as? Int == 2)
    }

    @Test func skipsUnknownSonyTags() {
        // Foreign entries between the AF tags must be ignored, not
        // crash the IFD walk.
        let entries = [
            SonyEntry(tag: 0x1000, type: 3, count: 1,
                      valueOrOffset: .inline(u16le(99))),
            SonyEntry(tag: 0x2027, type: 3, count: 4,
                      valueOrOffset: .outOfLine(u16le(1) + u16le(2) + u16le(3) + u16le(4))),
            SonyEntry(tag: 0xFFFF, type: 4, count: 1,
                      valueOrOffset: .inline(u32le(0)))
        ]
        let data = makeFixture(sonyEntries: entries)
        let result = SonyMakerNoteReader.readFocusData(fromContainer: data)!
        #expect(result["FocusLocation"] as? [Int] == [1, 2, 3, 4])
        #expect(result["FocusMode"] == nil)        // not in the input
        #expect(result["FocusFrameSize"] == nil)
    }

    @Test func returnsNilOnMissingMakerNote() {
        // No MakerNote tag at all → nil.
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(contentsOf: u32le(8))    // IFD0 offset
        // IFD0 with one entry that is NOT the ExifIFD pointer — IFD walk
        // bails because tag 0x8769 isn't found.
        data.append(contentsOf: u16le(1))
        data.append(contentsOf: u16le(0x010F))   // Make tag
        data.append(contentsOf: u16le(2))        // ASCII type
        data.append(contentsOf: u32le(0))
        data.append(contentsOf: u32le(0))
        data.append(contentsOf: u32le(0))
        #expect(SonyMakerNoteReader.readFocusData(fromContainer: data) == nil)
    }

    @Test func returnsNilOnNonTIFFContainer() {
        // Random bytes that aren't TIFF or JPEG.
        let data = Data([0xFF, 0x00, 0xAB, 0xCD])
        #expect(SonyMakerNoteReader.readFocusData(fromContainer: data) == nil)
    }

    @Test func returnsNilOnTruncatedContainer() {
        // Valid TIFF prefix but truncated before any IFD.
        let data = Data([0x49, 0x49, 0x2A, 0x00] + u32le(8))
        #expect(SonyMakerNoteReader.readFocusData(fromContainer: data) == nil)
    }

    @Test func emptyMakerNoteReturnsNil() {
        // MakerNote IFD with zero entries → nothing to extract → nil.
        let data = makeFixture(sonyEntries: [])
        #expect(SonyMakerNoteReader.readFocusData(fromContainer: data) == nil)
    }
}
