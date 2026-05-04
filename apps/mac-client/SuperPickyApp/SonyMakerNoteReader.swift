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
        guard let tiffStart = TIFFIFDReader.locateTIFFStart(in: data) else { return nil }
        guard data.count >= tiffStart + 8 else { return nil }

        let byteOrder: TIFFIFDReader.ByteOrder
        switch (data[tiffStart], data[tiffStart + 1]) {
        case (0x49, 0x49): byteOrder = .little
        case (0x4D, 0x4D): byteOrder = .big
        default: return nil
        }
        guard byteOrder.read16(data, at: tiffStart + 2) == 42 else { return nil }

        // IFD0 → ExifIFD (tag 0x8769) → MakerNote (tag 0x927C).
        let ifd0Offset = Int(byteOrder.read32(data, at: tiffStart + 4))
        guard let exifIFDPtr = TIFFIFDReader.findTagValueField(
            in: data,
            tiffStart: tiffStart,
            ifdRelativeOffset: ifd0Offset,
            tag: 0x8769,
            byteOrder: byteOrder
        ) else {
            return nil
        }
        guard let makerNoteEntry = TIFFIFDReader.findEntry(
            in: data,
            tiffStart: tiffStart,
            ifdRelativeOffset: Int(exifIFDPtr),
            tag: 0x927C,
            byteOrder: byteOrder
        ) else {
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

    // MARK: - Typed value extraction

    /// Read a single BYTE-typed (type=1) tag value.
    private static func readByte(in data: Data, entry: Int,
                                 tiffStart: Int, byteOrder: TIFFIFDReader.ByteOrder) -> UInt8? {
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
                                        tiffStart: Int, byteOrder: TIFFIFDReader.ByteOrder,
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

}
