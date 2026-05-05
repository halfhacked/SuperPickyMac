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
        guard let tiffStart = TIFFIFDReader.locateTIFFStart(in: data) else { return nil }
        guard data.count >= tiffStart + 8 else { return nil }

        let byteOrder: TIFFIFDReader.ByteOrder
        switch (data[tiffStart], data[tiffStart + 1]) {
        case (0x49, 0x49): byteOrder = .little
        case (0x4D, 0x4D): byteOrder = .big
        default: return nil
        }
        // Magic number must be 42.
        guard byteOrder.read16(data, at: tiffStart + 2) == 42 else { return nil }

        let ifd0Offset = Int(byteOrder.read32(data, at: tiffStart + 4))
        // Follow IFD0 → ExifIFD pointer (tag 0x8769).
        guard let exifIFDOffsetValue = TIFFIFDReader.findTagValueField(
            in: data,
            tiffStart: tiffStart,
            ifdRelativeOffset: ifd0Offset,
            tag: 0x8769,
            byteOrder: byteOrder
        ) else {
            return nil
        }
        // Read OffsetTimeOriginal (tag 0x9011) from the ExifIFD.
        return findASCIITag(in: data,
                            tiffStart: tiffStart,
                            ifdRelativeOffset: Int(exifIFDOffsetValue),
                            tag: 0x9011,
                            byteOrder: byteOrder)
    }

    /// Returns the ASCII string value of an EXIF tag (type 2), stripping the
    /// trailing null byte(s) the EXIF spec requires. Values ≤ 4 bytes live
    /// inline in the entry; longer values are referenced via an offset from
    /// the TIFF start.
    private static func findASCIITag(in data: Data,
                                     tiffStart: Int,
                                     ifdRelativeOffset: Int,
                                     tag: UInt16,
                                     byteOrder: TIFFIFDReader.ByteOrder) -> String? {
        guard let entry = TIFFIFDReader.findEntry(in: data,
                                                    tiffStart: tiffStart,
                                                    ifdRelativeOffset: ifdRelativeOffset,
                                                    tag: tag,
                                                    byteOrder: byteOrder) else {
            return nil
        }
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
}
