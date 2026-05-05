import Testing
import Foundation
@testable import SuperPicky

@Suite struct EXIFOffsetReaderTests {

    // MARK: - Byte builders

    /// Builds a minimal little-endian TIFF blob with one IFD0 (pointing to
    /// ExifIFD via 0x8769) and an ExifIFD that carries OffsetTimeOriginal
    /// (0x9011). The payload string (e.g. "+08:00\0") is stored at a fixed
    /// offset past the IFDs.
    static func minimalTIFFLittleEndian(offset payload: String) -> Data {
        var out = Data()
        // TIFF header: "II", magic 42, IFD0 offset = 8.
        out.append(contentsOf: [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        // IFD0 at offset 8: 1 entry (tag 0x8769 → ExifIFD pointer).
        // Entry layout (12 bytes): tag(2) type(2) count(4) value(4)
        // ExifIFD located at offset 26 (8 + 2 + 12 + 4).
        appendU16(&out, 1)               // entry count
        appendU16(&out, 0x8769)          // tag: ExifIFD pointer
        appendU16(&out, 4)               // type: LONG
        appendU32(&out, 1)               // count
        appendU32(&out, 26)              // value: ExifIFD offset (absolute from TIFF start = 0)
        appendU32(&out, 0)               // next IFD offset (none)
        // ExifIFD at offset 26: 1 entry (tag 0x9011 → OffsetTimeOriginal).
        // Payload (ASCII, count=N, N≥5 → stored out-of-line).
        let payloadBytes = Array(payload.utf8) + [0]
        let payloadOffset = 26 + 2 + 12 + 4  // = 44
        appendU16(&out, 1)
        appendU16(&out, 0x9011)
        appendU16(&out, 2)               // type: ASCII
        appendU32(&out, UInt32(payloadBytes.count))
        appendU32(&out, UInt32(payloadOffset))
        appendU32(&out, 0)               // next IFD
        // Payload
        out.append(contentsOf: payloadBytes)
        return out
    }

    /// Same shape but big-endian ("MM") — verifies byte-order awareness.
    static func minimalTIFFBigEndian(offset payload: String) -> Data {
        var out = Data()
        out.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
        appendU16BE(&out, 1)
        appendU16BE(&out, 0x8769)
        appendU16BE(&out, 4)
        appendU32BE(&out, 1)
        appendU32BE(&out, 26)
        appendU32BE(&out, 0)
        let payloadBytes = Array(payload.utf8) + [0]
        let payloadOffset = 26 + 2 + 12 + 4
        appendU16BE(&out, 1)
        appendU16BE(&out, 0x9011)
        appendU16BE(&out, 2)
        appendU32BE(&out, UInt32(payloadBytes.count))
        appendU32BE(&out, UInt32(payloadOffset))
        appendU32BE(&out, 0)
        out.append(contentsOf: payloadBytes)
        return out
    }

    /// Wraps a TIFF blob inside a JPEG APP1 segment so we exercise the
    /// JPEG container walker.
    static func wrapAsJPEGAPP1(_ tiff: Data) -> Data {
        var out = Data([0xFF, 0xD8])           // SOI
        let segmentPayload = Data("Exif\0\0".utf8) + tiff
        let segmentLength = segmentPayload.count + 2
        out.append(0xFF)
        out.append(0xE1)
        out.append(UInt8((segmentLength >> 8) & 0xFF))
        out.append(UInt8(segmentLength & 0xFF))
        out.append(segmentPayload)
        // Fake SOS + EOI so the scanner stops cleanly.
        out.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        return out
    }

    private static func appendU16(_ out: inout Data, _ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendU32(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }
    private static func appendU16BE(_ out: inout Data, _ v: UInt16) {
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }
    private static func appendU32BE(_ out: inout Data, _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    // MARK: - Tests

    @Test func readsOffsetFromLittleEndianTIFF() {
        let data = Self.minimalTIFFLittleEndian(offset: "+08:00")
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: data) == "+08:00")
    }

    @Test func readsOffsetFromBigEndianTIFF() {
        let data = Self.minimalTIFFBigEndian(offset: "-05:00")
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: data) == "-05:00")
    }

    @Test func readsOffsetFromJPEGAPP1Container() {
        let tiff = Self.minimalTIFFLittleEndian(offset: "+09:00")
        let jpeg = Self.wrapAsJPEGAPP1(tiff)
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: jpeg) == "+09:00")
    }

    @Test func returnsNilForNonImageBytes() {
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: junk) == nil)
    }

    @Test func returnsNilForTruncatedTIFF() {
        // Only 6 bytes — not even enough for a TIFF header.
        let truncated = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00])
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: truncated) == nil)
    }

    @Test func returnsNilForTIFFWithWrongMagic() {
        var data = Self.minimalTIFFLittleEndian(offset: "+08:00")
        // Corrupt the magic number (42 → 43).
        data[2] = 0x2B
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: data) == nil)
    }

    @Test func returnsNilWhenExifIFDPointerMissing() {
        // A TIFF with IFD0 but no 0x8769 entry — just a dummy entry.
        var out = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        // IFD0: 1 entry, tag 0x0100 (ImageWidth), LONG=1, value=100.
        out.append(contentsOf: [0x01, 0x00])  // count = 1
        out.append(contentsOf: [0x00, 0x01])  // tag 0x0100
        out.append(contentsOf: [0x04, 0x00])  // type LONG
        out.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        out.append(contentsOf: [0x64, 0x00, 0x00, 0x00])
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        #expect(EXIFOffsetReader.readOffsetTimeOriginal(fromContainer: out) == nil)
    }

    // MARK: - Real-file end-to-end

    @Test func readsOffsetFromRealSonyARWIfPresent() {
        // Opt-in: only runs when the user has a Sony ARW parked at a known
        // spot. Covers the exact bug that motivated EXIFOffsetReader —
        // ImageIO drops the tag for Sony, we walk the bytes ourselves.
        let candidate = ("~/photo/untitled folder/DSC09821.ARW" as NSString)
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: candidate) else { return }
        let offset = EXIFOffsetReader.readOffsetTimeOriginal(from: candidate)
        #expect(offset == "+08:00")
    }
}
