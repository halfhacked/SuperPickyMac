import Foundation

/// Reads Sony AF tags directly from the file bytes.
///
/// Apple's ImageIO does not surface Sony MakerNote at all for ARW —
/// `CGImageSourceCopyPropertiesAtIndex` returns no `{MakerNote}` key
/// — so the brand-dispatched parser in `FocusPointDetector` never
/// receives input via the standard path. This reader walks the TIFF
/// IFD chain by hand:
///
/// ```
///   TIFF header → IFD0 → ExifIFD (0x8769) → MakerNote (0x927C) → Sony5 IFD
/// ```
///
/// Sony5 (modern bodies — A1 / A7Rx / A9) starts the MakerNote with a
/// bare TIFF-style IFD using the same byte order as the parent and
/// entry offsets relative to the TIFF base. Older bodies prefix the
/// IFD with a 12-byte `"SONY DSC \0\0\0"` header; we detect this and
/// skip past it before parsing.
///
/// Returns a dict shaped for `FocusPointDetector.parseSonyFocusPoint` —
/// `FocusLocation` as `[Int]`, `FocusFrameSize` as `[Int]`, and the
/// integer `FocusMode` code (Sony 1=MF, 2=AF-S, 3=AF-C, 4=AF-A, …).
enum SonyMakerNoteReader {

    /// Sony MakerNote tag IDs we care about for AF data.
    private static let tagFocusMode: UInt16     = 0x201B  // int8u[1]
    private static let tagFocusLocation: UInt16 = 0x2027  // int16u[4]: imgW imgH x y
    private static let tagFocusFrameSize: UInt16 = 0x2037 // undef[6] → int16u[3]: w h validity

    /// Memory-maps the file and returns a dict of Sony focus tags
    /// (or nil if the container can't be parsed or no Sony MakerNote
    /// is present).
    static func readFocusData(from path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .alwaysMapped) else { return nil }
        return readFocusData(fromContainer: data)
    }

    /// Pure-data entry point. Exposed `internal` for tests that craft
    /// byte buffers without touching the filesystem.
    static func readFocusData(fromContainer data: Data) -> [String: Any]? {
        guard let tiffStart = locateTIFFStart(in: data) else { return nil }
        guard data.count >= tiffStart + 8 else { return nil }

        let byteOrder: ByteOrder
        switch (data[tiffStart], data[tiffStart + 1]) {
        case (0x49, 0x49): byteOrder = .little
        case (0x4D, 0x4D): byteOrder = .big
        default: return nil
        }
        guard byteOrder.read16(data, at: tiffStart + 2) == 42 else { return nil }

        // IFD0 → ExifIFD (tag 0x8769) → MakerNote (tag 0x927C).
        let ifd0Offset = Int(byteOrder.read32(data, at: tiffStart + 4))
        guard let exifIFDPtr = findTagValueField(in: data,
                                                  tiffStart: tiffStart,
                                                  ifdRelativeOffset: ifd0Offset,
                                                  tag: 0x8769,
                                                  byteOrder: byteOrder) else {
            return nil
        }
        guard let makerNoteEntry = findEntry(in: data,
                                              tiffStart: tiffStart,
                                              ifdRelativeOffset: Int(exifIFDPtr),
                                              tag: 0x927C,
                                              byteOrder: byteOrder) else {
            return nil
        }
        // MakerNote contents live at the value-offset; the count is the
        // byte length of the data block.
        let mnRelativeOffset = Int(byteOrder.read32(data, at: makerNoteEntry + 8))
        let mnByteCount      = Int(byteOrder.read32(data, at: makerNoteEntry + 4))
        let mnAbsolute       = tiffStart + mnRelativeOffset
        guard mnAbsolute >= 0,
              mnByteCount >= 2,
              mnAbsolute + mnByteCount <= data.count else {
            return nil
        }

        // Sony5 starts the IFD directly. Older bodies prefix it with
        // "SONY DSC \0\0\0" (12 bytes) — skip past that when present.
        let sonyHeader: [UInt8] = [0x53, 0x4F, 0x4E, 0x59, 0x20,    // "SONY "
                                    0x44, 0x53, 0x43, 0x20]          // "DSC "
        var ifdStart = mnAbsolute
        if mnByteCount >= 12,
           Array(data[mnAbsolute..<(mnAbsolute + sonyHeader.count)]) == sonyHeader {
            ifdStart = mnAbsolute + 12
        }
        guard ifdStart + 2 <= data.count else { return nil }

        // Iterate Sony IFD entries looking for the AF tags. Bail when
        // the entry count is implausibly large — defensive against
        // misidentified containers.
        let entryCount = Int(byteOrder.read16(data, at: ifdStart))
        guard entryCount > 0, entryCount < 1000 else { return nil }
        let entriesStart = ifdStart + 2
        guard entriesStart + entryCount * 12 <= data.count else { return nil }

        var out: [String: Any] = [:]
        for index in 0..<entryCount {
            let entry = entriesStart + index * 12
            let tag = byteOrder.read16(data, at: entry)
            switch tag {
            case tagFocusMode:
                if let value = readByte(in: data, entry: entry, tiffStart: tiffStart, byteOrder: byteOrder) {
                    out["FocusMode"] = Int(value)
                }
            case tagFocusLocation:
                if let values = readUInt16Array(in: data, entry: entry,
                                                 tiffStart: tiffStart, byteOrder: byteOrder,
                                                 expectedType: 3) {
                    out["FocusLocation"] = values.map { Int($0) }
                }
            case tagFocusFrameSize:
                // Stored as `undef` (type 7), but the byte payload is
                // logically three little-endian shorts. We accept either
                // declared type defensively.
                if let values = readUInt16Array(in: data, entry: entry,
                                                 tiffStart: tiffStart, byteOrder: byteOrder,
                                                 expectedType: nil, expectedByteCount: 6) {
                    out["FocusFrameSize"] = values.map { Int($0) }
                }
            default:
                continue
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Container detection

    /// Same logic as `EXIFOffsetReader.locateTIFFStart` — bare TIFF/ARW
    /// at offset 0, JPEG inside an APP1 segment after `"Exif\0\0"`.
    private static func locateTIFFStart(in data: Data) -> Int? {
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

    // MARK: - IFD walking

    /// Returns the absolute byte offset of the IFD entry for `tag`, or
    /// nil when not present. The 12-byte entry layout is
    /// `(tag:2)(type:2)(count:4)(value-or-offset:4)`.
    private static func findEntry(in data: Data,
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

    /// Convenience: read the `(value-or-offset)` field of an IFD entry.
    private static func findTagValueField(in data: Data,
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

    // MARK: - Typed value extraction

    /// Read a single BYTE-typed (type=1) tag value.
    private static func readByte(in data: Data, entry: Int,
                                 tiffStart: Int, byteOrder: ByteOrder) -> UInt8? {
        let type = byteOrder.read16(data, at: entry + 2)
        let count = Int(byteOrder.read32(data, at: entry + 4))
        guard type == 1 || type == 7, count >= 1 else { return nil }
        // Inline (count ≤ 4) — first byte of value field.
        return data[entry + 8]
    }

    /// Read SHORT-typed (type=3) array values. When `expectedType` is
    /// nil, accept any type and use `expectedByteCount` to delineate
    /// the byte payload, then reinterpret as little/big-endian shorts.
    /// This handles the `undef[6] → int16u[3]` case for FocusFrameSize.
    private static func readUInt16Array(in data: Data, entry: Int,
                                        tiffStart: Int, byteOrder: ByteOrder,
                                        expectedType: UInt16?,
                                        expectedByteCount: Int? = nil) -> [UInt16]? {
        let type = byteOrder.read16(data, at: entry + 2)
        let count = Int(byteOrder.read32(data, at: entry + 4))
        if let expectedType, type != expectedType { return nil }
        let byteCount: Int
        if let expectedByteCount {
            // Accept either type (3 → count = byteCount/2 shorts; 7 →
            // count = byteCount raw bytes). Bail if neither matches.
            if count == expectedByteCount, type != 3 { byteCount = expectedByteCount }
            else if type == 3, count * 2 == expectedByteCount { byteCount = expectedByteCount }
            else { return nil }
        } else if type == 3 {
            byteCount = count * 2
        } else {
            return nil
        }

        let bytes: ArraySlice<UInt8>
        if byteCount <= 4 {
            // Inline — pulled from the value-or-offset field.
            let inlineStart = entry + 8
            bytes = ArraySlice(data[inlineStart..<(inlineStart + byteCount)])
        } else {
            let payloadOffset = tiffStart + Int(byteOrder.read32(data, at: entry + 8))
            guard payloadOffset >= 0, payloadOffset + byteCount <= data.count else { return nil }
            bytes = ArraySlice(data[payloadOffset..<(payloadOffset + byteCount)])
        }

        var result: [UInt16] = []
        result.reserveCapacity(byteCount / 2)
        let base = bytes.startIndex
        for shortIndex in 0..<(byteCount / 2) {
            let lo = bytes[base + shortIndex * 2]
            let hi = bytes[base + shortIndex * 2 + 1]
            let value: UInt16 = byteOrder == .little
                ? (UInt16(hi) << 8) | UInt16(lo)
                : (UInt16(lo) << 8) | UInt16(hi)
            result.append(value)
        }
        return result
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
