import SwiftUI

/// Floating panel that displays EXIF metadata for the selected photo.
struct ExifPanelView: View {
    let photo: Photo
    @State private var exifData: EXIFData?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if loaded, let data = exifData, !data.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Camera section
                    if data.cameraMake != nil || data.cameraModel != nil || data.lensModel != nil {
                        sectionHeader("Camera")
                        VStack(alignment: .leading, spacing: 6) {
                            if let make = data.cameraMake, let model = data.cameraModel {
                                exifRow(label: "Body", value: "\(make) \(model)")
                            } else if let model = data.cameraModel {
                                exifRow(label: "Body", value: model)
                            } else if let make = data.cameraMake {
                                exifRow(label: "Make", value: make)
                            }
                            if let lens = data.lensModel {
                                exifRow(label: "Lens", value: lens)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }

                    // Exposure section
                    if data.focalLength != nil || data.aperture != nil || data.shutterSpeed != nil || data.iso != nil {
                        sectionHeader("Exposure")
                        VStack(alignment: .leading, spacing: 4) {
                            // Compact exposure line: 800mm  f/6.3  1/2000  ISO 1600
                            HStack(spacing: 12) {
                                if let focal = data.focalLength {
                                    exposureBadge("\(formatNumber(focal))mm")
                                }
                                if let aperture = data.aperture {
                                    exposureBadge("f/\(formatNumber(aperture))")
                                }
                                if let shutter = data.shutterSpeed {
                                    exposureBadge(shutter)
                                }
                                if let iso = data.iso {
                                    exposureBadge("ISO \(iso)")
                                }
                            }
                            .padding(.horizontal, 12)

                            VStack(alignment: .leading, spacing: 6) {
                                if let bias = data.exposureBias {
                                    let sign = bias >= 0 ? "+" : ""
                                    exifRow(label: "EV", value: "\(sign)\(formatNumber(bias))")
                                }
                                if let metering = data.meteringMode {
                                    exifRow(label: "Metering", value: metering)
                                }
                                if let wb = data.whiteBalance {
                                    exifRow(label: "WB", value: wb)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .padding(.bottom, 10)
                    }

                    // Image section
                    if data.imageWidth != nil || data.dateTimeOriginal != nil {
                        sectionHeader("Image")
                        VStack(alignment: .leading, spacing: 6) {
                            if let w = data.imageWidth, let h = data.imageHeight {
                                exifRow(label: "Size", value: "\(w) \u{00D7} \(h)")
                            }
                            if let date = data.dateTimeOriginal {
                                exifRow(label: "Date", value: formatDate(date))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }

                    // Location section
                    if data.latitude != nil || data.city != nil {
                        sectionHeader("Location")
                        VStack(alignment: .leading, spacing: 6) {
                            if let location = formatLocation(data) {
                                exifRow(label: "Place", value: location)
                            }
                            if let coords = formatCoordinates(data) {
                                exifRow(label: "GPS", value: coords)
                            }
                            if let alt = data.altitude {
                                exifRow(label: "Alt", value: "\(Int(alt)) m")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }

                    // Keywords section
                    if !data.keywords.isEmpty {
                        sectionHeader("Keywords")
                        FlowLayout(spacing: 4) {
                            ForEach(data.keywords, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                        .accessibilityIdentifier("Exif_Keywords")
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .padding(.vertical, 8)
            } else if loaded {
                VStack {
                    Spacer()
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No EXIF data")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("ExifNoData")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, x: -2, y: 2)
        .padding(8)
        .accessibilityIdentifier("ExifPanel")
        .task(id: photo.id) {
            loaded = false
            exifData = await Task.detached {
                EXIFReader.read(from: photo.filePath)
            }.value
            loaded = true
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private func exifRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("Exif_\(label)")
        }
    }

    private func exposureBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
    }

    // MARK: - Formatters

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private func formatDate(_ raw: String) -> String {
        // "2025:03:15 07:30:22" → "2025-03-15  07:30"
        let cleaned = raw.replacingOccurrences(of: ":", with: "-", range: raw.startIndex..<raw.index(raw.startIndex, offsetBy: min(10, raw.count)))
        if cleaned.count > 16 {
            return String(cleaned.prefix(16))
        }
        return cleaned
    }

    private func formatLocation(_ data: EXIFData) -> String? {
        let parts = [data.city, data.state, data.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func formatCoordinates(_ data: EXIFData) -> String? {
        guard let lat = data.latitude, let lon = data.longitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f\u{00B0} %@, %.4f\u{00B0} %@",
                      abs(lat), latDir, abs(lon), lonDir)
    }
}

// MARK: - FlowLayout for keyword tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                                   proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (offsets, CGSize(width: maxX, height: y + rowHeight))
    }
}
