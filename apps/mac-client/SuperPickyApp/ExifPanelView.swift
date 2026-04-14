import SwiftUI

/// Floating panel that displays EXIF metadata for the selected photo.
struct ExifPanelView: View {
    let photo: Photo
    @State private var exifData: EXIFData?
    @State private var loaded = false

    private let labelWidth: CGFloat = 100

    var body: some View {
        ScrollView {
            if loaded, let data = exifData, !data.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Camera section
                    if data.camera.make != nil || data.camera.model != nil || data.camera.lens != nil {
                        sectionHeader("Camera", showDivider: false)
                        if let make = data.camera.make, let model = data.camera.model {
                            exifRow(label: "Camera", value: "\(make) \(model)")
                        } else if let model = data.camera.model {
                            exifRow(label: "Camera", value: model)
                        } else if let make = data.camera.make {
                            exifRow(label: "Camera", value: make)
                        }
                        if let lens = data.camera.lens {
                            exifRow(label: "Lens", value: lens)
                        }
                    }

                    // Exposure section
                    if data.exposure.focalLength != nil || data.exposure.aperture != nil || data.exposure.shutterSpeed != nil || data.exposure.iso != nil {
                        sectionHeader("Exposure")
                        if let focal = data.exposure.focalLength {
                            exifRow(label: "Focal Length", value: "\(formatNumber(focal)) mm")
                        }
                        // Combine exposure like Lightroom: "1/2000 at f/6.3, ISO 1600"
                        exifRow(label: "Exposure", value: formatExposure(data))
                        if let bias = data.exposure.exposureBias, bias != 0 {
                            let sign = bias >= 0 ? "+" : ""
                            exifRow(label: "Exp Comp", value: "\(sign)\(formatNumber(bias)) EV")
                        }
                        if let metering = data.exposure.meteringMode {
                            exifRow(label: "Metering", value: metering)
                        }
                        if let wb = data.exposure.whiteBalance {
                            exifRow(label: "White Balance", value: wb)
                        }
                    }

                    // Image section
                    if data.image.width != nil || data.image.dateTimeOriginal != nil {
                        sectionHeader("Image")
                        if let date = data.image.dateTimeOriginal {
                            exifRow(label: "Capture Date", value: formatDate(date))
                        }
                        if let w = data.image.width, let h = data.image.height {
                            exifRow(label: "Dimensions", value: "\(w) \u{00D7} \(h)")
                        }
                    }

                    // Location section
                    if data.location.latitude != nil || data.location.city != nil {
                        sectionHeader("Location")
                        if let place = formatLocation(data) {
                            exifRow(label: "Place", value: place)
                        }
                        if let lat = data.location.latitude, let lon = data.location.longitude {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("GPS")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                    .lineLimit(1)
                                Text(formatCoordinates(data) ?? "")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("Exif_GPS")
                                Button {
                                    let label = formatLocation(data) ?? "Photo Location"
                                    let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")&z=14")!
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "map")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Open in Maps")
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                        }
                        if let alt = data.location.altitude {
                            exifRow(label: "Altitude", value: "\(Int(alt)) m")
                        }
                    }

                    // Keywords section
                    if !data.keywords.isEmpty {
                        sectionHeader("Keywords")
                        FlowLayout(spacing: 4) {
                            ForEach(data.keywords, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                        .accessibilityIdentifier("Exif_Keywords")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 8)
            } else if loaded {
                VStack(spacing: 8) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No EXIF data")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("ExifNoData")
                }
                .padding(20)
            }
        }
        .frame(width: 270, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
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

    private func sectionHeader(_ title: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showDivider {
                Divider()
                    .padding(.horizontal, 12)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, showDivider ? 8 : 2)
                .padding(.bottom, 4)
        }
    }

    private func exifRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("Exif_\(label)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Formatters

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private func formatExposure(_ data: EXIFData) -> String {
        var parts: [String] = []
        if let shutter = data.exposure.shutterSpeed { parts.append(shutter) }
        if let aperture = data.exposure.aperture { parts.append("f/\(formatNumber(aperture))") }
        if let iso = data.exposure.iso { parts.append("ISO \(iso)") }
        if parts.isEmpty { return "—" }
        // "1/2000 at f/6.3, ISO 1600"
        if parts.count >= 2, data.exposure.shutterSpeed != nil, data.exposure.aperture != nil {
            let shutter = parts.removeFirst()
            let aperture = parts.removeFirst()
            var result = "\(shutter) at \(aperture)"
            if !parts.isEmpty { result += ", \(parts.joined(separator: ", "))" }
            return result
        }
        return parts.joined(separator: ", ")
    }

    private func formatDate(_ raw: String) -> String {
        // "2025:03:15 07:30:22" → "Mar 15, 2025  07:30"
        let parts = raw.split(separator: " ")
        guard let datePart = parts.first else { return raw }
        let dateComponents = datePart.split(separator: ":")
        guard dateComponents.count == 3,
              let year = Int(dateComponents[0]),
              let month = Int(dateComponents[1]),
              let day = Int(dateComponents[2]) else { return raw }

        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthName = month >= 1 && month <= 12 ? months[month] : "\(month)"

        var result = "\(monthName) \(day), \(year)"
        if parts.count > 1 {
            let time = String(parts[1])
            // Drop seconds: "07:30:22" → "07:30"
            let timeParts = time.split(separator: ":")
            if timeParts.count >= 2 {
                result += "  \(timeParts[0]):\(timeParts[1])"
            }
        }
        return result
    }

    private func formatLocation(_ data: EXIFData) -> String? {
        let parts = [data.location.city, data.location.state, data.location.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func formatCoordinates(_ data: EXIFData) -> String? {
        guard let lat = data.location.latitude, let lon = data.location.longitude else { return nil }
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
