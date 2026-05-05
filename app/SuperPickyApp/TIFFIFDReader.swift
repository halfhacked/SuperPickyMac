import Foundation

/// Shared low-level helpers for walking TIFF/Exif IFDs straight from
/// file bytes. Used by `EXIFOffsetReader` (timezone offset) and
/// `SonyMakerNoteReader` (Sony AF tags) — both exist because Apple's
/// ImageIO drops the tags they need.
///
/// Internal-only; no public clients outside this module.
enum TIFFIFDReader {

    enum ByteOrder {
        case little, big

        func read16(_ data: Data, at offset: Int) -> UInt16 {
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            return self == .little ? (b1 << 8) | b0 : (b0 << 8) | b1
        }

        func read32(_ data: Data, at offset: Int) -> UInt32 {
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            return self == .little
                ? (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
                : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    /// Offset of the TIFF header within `data`. Bare TIFF/ARW starts at 0;
    /// JPEG files place the TIFF inside an `APP1` segment after `"Exif\0\0"`.
    static func locateTIFFStart(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        if (data[0] == 0x49 && data[1] == 0x49) || (data[0] == 0x4D && data[1] == 0x4D) {
            return 0
        }
        guard data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var cursor = 2
        while cursor + 4 <= data.count {
            guard data[cursor] == 0xFF else { return nil }
            let marker = data[cursor + 1]
            if marker == 0xDA || marker == 0xD9 { return nil }
            let segmentLength = Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            guard segmentLength >= 2 else { return nil }
            if marker == 0xE1 {
                let headerStart = cursor + 4
                if headerStart + 6 <= data.count,
                   data[headerStart]     == 0x45,   // 'E'
                   data[headerStart + 1] == 0x78,   // 'x'
                   data[headerStart + 2] == 0x69,   // 'i'
                   data[headerStart + 3] == 0x66,   // 'f'
                   data[headerStart + 4] == 0x00,
                   data[headerStart + 5] == 0x00 {
                    return headerStart + 6
                }
            }
            cursor += 2 + segmentLength
        }
        return nil
    }

    /// Returns the absolute byte offset of the IFD entry for `tag`, or
    /// nil when not present. The 12-byte entry layout is
    /// `(tag:2)(type:2)(count:4)(value-or-offset:4)`.
    static func findEntry(in data: Data,
                          tiffStart: Int,
                          ifdRelativeOffset: Int,
                          tag: UInt16,
                          byteOrder: ByteOrder) -> Int? {
        let ifdAbsolute = tiffStart + ifdRelativeOffset
        guard ifdAbsolute >= 0, ifdAbsolute + 2 <= data.count else { return nil }
        let entryCount = Int(byteOrder.read16(data, at: ifdAbsolute))
        guard entryCount >= 0, entryCount < 4096 else { return nil }
        let entriesStart = ifdAbsolute + 2
        guard entriesStart + entryCount * 12 <= data.count else { return nil }
        for index in 0..<entryCount {
            let entry = entriesStart + index * 12
            if byteOrder.read16(data, at: entry) == tag {
                return entry
            }
        }
        return nil
    }

    /// Read the `(value-or-offset)` 4-byte field of an IFD entry. Used
    /// when we only need a scalar (e.g. an inner-IFD pointer like 0x8769).
    static func findTagValueField(in data: Data,
                                  tiffStart: Int,
                                  ifdRelativeOffset: Int,
                                  tag: UInt16,
                                  byteOrder: ByteOrder) -> UInt32? {
        guard let entry = findEntry(in: data,
                                     tiffStart: tiffStart,
                                     ifdRelativeOffset: ifdRelativeOffset,
                                     tag: tag,
                                     byteOrder: byteOrder) else { return nil }
        return byteOrder.read32(data, at: entry + 8)
    }
}
