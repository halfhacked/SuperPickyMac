import Foundation

/// Reads EXIF `OffsetTimeOriginal` (tag 0x9011) directly from the file bytes.
///
/// Exists because Apple's ImageIO drops this tag for Sony ARW (and some other
/// RAW formats) — the tag is physically present in the file, but ImageIO's
/// RAW parser never surfaces it through `CGImageSourceCopyPropertiesAtIndex`
/// or the newer `CGImageMetadata` APIs.
///
/// Only walks the two IFDs needed (IFD0 → ExifIFD) for one tag, so this is
/// intentionally small. Handles both bare TIFF containers (ARW, TIFF, DNG)
/// and JPEG containers with an APP1 Exif segment.
enum EXIFOffsetReader {

    /// Memory-maps the file and returns the raw `OffsetTimeOriginal` ASCII
    /// (e.g. `"+08:00"`), or nil when the file isn't a TIFF/JPEG, the tag
    /// isn't present, or the IFD can't be parsed.
    static func readOffsetTimeOriginal(from path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .alwaysMapped) else { return nil }
        return readOffsetTimeOriginal(fromContainer: data)
    }

    /// Pure-data entry point. Exposed `internal` for unit testing without
    /// touching the filesystem.
    static func readOffsetTimeOriginal(fromContainer data: Data) -> String? {
        guard let tiffStart = locateTIFFStart(in: data) else { return nil }
        guard data.count >= tiffStart + 8 else { return nil }

        let byteOrder: ByteOrder
        switch (data[tiffStart], data[tiffStart + 1]) {
        case (0x49, 0x49): byteOrder = .little
        case (0x4D, 0x4D): byteOrder = .big
        default: return nil
        }
        // Magic number must be 42.
        guard byteOrder.read16(data, at: tiffStart + 2) == 42 else { return nil }

        let ifd0Offset = Int(byteOrder.read32(data, at: tiffStart + 4))
        // Follow IFD0 → ExifIFD pointer (tag 0x8769).
        guard let exifIFDOffsetValue = findTagValueField(in: data,
                                                         tiffStart: tiffStart,
                                                         ifdRelativeOffset: ifd0Offset,
                                                         tag: 0x8769,
                                                         byteOrder: byteOrder) else {
            return nil
        }
        // Read OffsetTimeOriginal (tag 0x9011) from the ExifIFD.
        return findASCIITag(in: data,
                            tiffStart: tiffStart,
                            ifdRelativeOffset: Int(exifIFDOffsetValue),
                            tag: 0x9011,
                            byteOrder: byteOrder)
    }

    // MARK: - Container detection

    /// Offset of the TIFF header within `data`. Bare TIFF/ARW starts at 0;
    /// JPEG files place the TIFF inside an `APP1` segment after `"Exif\0\0"`.
    private static func locateTIFFStart(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        // Bare TIFF — byte order marker at offset 0.
        if (data[0] == 0x49 && data[1] == 0x49) || (data[0] == 0x4D && data[1] == 0x4D) {
            return 0
        }
        // JPEG — walk segments looking for APP1 with an Exif header.
        guard data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var cursor = 2
        while cursor + 4 <= data.count {
            guard data[cursor] == 0xFF else { return nil }
            let marker = data[cursor + 1]
            // SOS (Start of Scan) or EOI means we've passed all metadata.
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

    // MARK: - IFD walk

    /// Returns the raw 4-byte "value or offset" field for the given tag.
    /// Used when we only need a scalar (e.g. the ExifIFD pointer at 0x8769).
    private static func findTagValueField(in data: Data,
                                          tiffStart: Int,
                                          ifdRelativeOffset: Int,
                                          tag: UInt16,
                                          byteOrder: ByteOrder) -> UInt32? {
        let ifdAbsolute = tiffStart + ifdRelativeOffset
        guard ifdAbsolute + 2 <= data.count else { return nil }
        let entryCount = Int(byteOrder.read16(data, at: ifdAbsolute))
        let entriesStart = ifdAbsolute + 2
        guard entriesStart + entryCount * 12 <= data.count else { return nil }
        for index in 0..<entryCount {
            let entry = entriesStart + index * 12
            if byteOrder.read16(data, at: entry) == tag {
                return byteOrder.read32(data, at: entry + 8)
            }
        }
        return nil
    }

    /// Returns the ASCII string value of an EXIF tag (type 2), stripping the
    /// trailing null byte(s) the EXIF spec requires. Values ≤ 4 bytes live
    /// inline in the entry; longer values are referenced via an offset from
    /// the TIFF start.
    private static func findASCIITag(in data: Data,
                                     tiffStart: Int,
                                     ifdRelativeOffset: Int,
                                     tag: UInt16,
                                     byteOrder: ByteOrder) -> String? {
        let ifdAbsolute = tiffStart + ifdRelativeOffset
        guard ifdAbsolute + 2 <= data.count else { return nil }
        let entryCount = Int(byteOrder.read16(data, at: ifdAbsolute))
        let entriesStart = ifdAbsolute + 2
        guard entriesStart + entryCount * 12 <= data.count else { return nil }
        for index in 0..<entryCount {
            let entry = entriesStart + index * 12
            if byteOrder.read16(data, at: entry) != tag { continue }
            // Type 2 = ASCII. Reject anything else defensively.
            guard byteOrder.read16(data, at: entry + 2) == 2 else { return nil }
            let valueCount = Int(byteOrder.read32(data, at: entry + 4))
            guard valueCount > 0 else { return nil }
            let bytes: [UInt8]
            if valueCount <= 4 {
                bytes = (0..<valueCount).map { data[entry + 8 + $0] }
            } else {
                let payloadOffset = tiffStart + Int(byteOrder.read32(data, at: entry + 8))
                guard payloadOffset + valueCount <= data.count else { return nil }
                bytes = Array(data[payloadOffset..<(payloadOffset + valueCount)])
            }
            let trimmed = bytes.prefix(while: { $0 != 0 })
            return String(decoding: trimmed, as: UTF8.self)
        }
        return nil
    }

    // MARK: - Byte order

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
}
