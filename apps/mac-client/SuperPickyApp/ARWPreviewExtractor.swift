import Foundation

/// Extracts the full-resolution JPEG preview embedded in Sony ARW files.
///
/// Sony ARW stores three images: a small thumbnail (~160 px), a medium
/// preview (1616×1080, what ImageIO's `kCGImageSourceCreateThumbnailFrom
/// ImageIfAbsent` returns), and a full-resolution JPEG matching the
/// sensor's active area (5616×3744 on Sony A1, 8640×5760 on A1 II /
/// A7R V). The full-res JPEG lives in **IFD2** under standard EXIF tags
/// `JpgFromRawStart` (0x0201) and `JpgFromRawLength` (0x0202). IFD2 is
/// reached by following the next-IFD pointer at the end of IFD0 twice.
///
/// ImageIO doesn't expose this as a separate sub-image
/// (`CGImageSourceGetCount` returns 1 for ARW), and the only way to
/// force full-res via ImageIO is `kCGImageSourceCreateThumbnailFrom
/// ImageAlways`, which routes through CIRAW. Measured cost on a Sony A1
/// ARW: 611 ms via `Always` vs 18 ms decoding our extracted JPEG slice.
///
/// The extractor's output is a `Data` slice positioned over the
/// memory-mapped file — no copy. Pass it to
/// `CGImageSourceCreateWithData` to decode at native resolution.
enum ARWPreviewExtractor {
    private static let tagJpgFromRawStart: UInt16 = 0x0201
    private static let tagJpgFromRawLength: UInt16 = 0x0202

    /// Memory-maps the file and returns the embedded full-res JPEG slice.
    /// Returns nil for non-ARW containers, files that lack IFD2, or
    /// older Sony bodies that don't write a `JpgFromRaw` block.
    static func extractFullResJPEG(from path: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .alwaysMapped) else { return nil }
        return extractFullResJPEG(fromContainer: data)
    }

    /// Pure-data entry point. Exposed `internal` for tests using crafted
    /// byte buffers.
    static func extractFullResJPEG(fromContainer data: Data) -> Data? {
        guard let tiffStart = TIFFIFDReader.locateTIFFStart(in: data) else { return nil }
        guard data.count >= tiffStart + 8 else { return nil }

        let byteOrder: TIFFIFDReader.ByteOrder
        switch (data[tiffStart], data[tiffStart + 1]) {
        case (0x49, 0x49): byteOrder = .little
        case (0x4D, 0x4D): byteOrder = .big
        default: return nil
        }
        guard byteOrder.read16(data, at: tiffStart + 2) == 42 else { return nil }

        // Walk IFD0 → next → IFD1 → next → IFD2 by chasing the
        // next-IFD pointer that sits right after each IFD's entry array.
        var ifdOffset = Int(byteOrder.read32(data, at: tiffStart + 4))
        for _ in 0..<2 {
            guard ifdOffset > 0 else { return nil }
            let ifdAbsolute = tiffStart + ifdOffset
            guard ifdAbsolute + 2 <= data.count else { return nil }
            let entryCount = Int(byteOrder.read16(data, at: ifdAbsolute))
            guard entryCount >= 0, entryCount < 4096 else { return nil }
            let nextIFDPos = ifdAbsolute + 2 + entryCount * 12
            guard nextIFDPos + 4 <= data.count else { return nil }
            ifdOffset = Int(byteOrder.read32(data, at: nextIFDPos))
        }
        guard ifdOffset > 0 else { return nil }

        // IFD2: read JpgFromRawStart (0x0201) + JpgFromRawLength (0x0202).
        // Both are TIFF type LONG (4) count 1, so the 4-byte value-or-
        // offset field holds the scalar directly.
        guard let startEntry = TIFFIFDReader.findEntry(in: data,
                                                        tiffStart: tiffStart,
                                                        ifdRelativeOffset: ifdOffset,
                                                        tag: tagJpgFromRawStart,
                                                        byteOrder: byteOrder),
              let lengthEntry = TIFFIFDReader.findEntry(in: data,
                                                         tiffStart: tiffStart,
                                                         ifdRelativeOffset: ifdOffset,
                                                         tag: tagJpgFromRawLength,
                                                         byteOrder: byteOrder) else {
            return nil
        }
        let jpgStart = Int(byteOrder.read32(data, at: startEntry + 8))
        let jpgLength = Int(byteOrder.read32(data, at: lengthEntry + 8))
        guard jpgStart > 0, jpgLength > 0,
              jpgStart + jpgLength <= data.count else {
            return nil
        }

        // Sanity check: the bytes must start with a JPEG SOI marker.
        // Catches files where IFD2 exists but the tags point at non-JPEG
        // data (some older or third-party RAW).
        guard data[jpgStart] == 0xFF, data[jpgStart + 1] == 0xD8 else {
            return nil
        }

        return data.subdata(in: jpgStart..<(jpgStart + jpgLength))
    }
}
