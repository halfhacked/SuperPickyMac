import SwiftUI

/// Floating panel that displays EXIF metadata for the selected photo.
struct ExifPanelView: View {
    @Environment(CullingConfig.self) private var config
    let photo: Photo
    @State private var exifData: EXIFData?
    @State private var loaded = false

    private let labelWidth: CGFloat = 100

    var body: some View {
        ScrollView {
            if loaded, let data = exifData, !data.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Camera section
                    if data.cameraMake != nil || data.cameraModel != nil || data.lensModel != nil {
                        sectionHeader(config.localized("Camera"), showDivider: false)
                        if let make = data.cameraMake, let model = data.cameraModel {
                            exifRow(label: config.localized("Camera"), value: "\(make) \(model)")
                        } else if let model = data.cameraModel {
                            exifRow(label: config.localized("Camera"), value: model)
                        } else if let make = data.cameraMake {
                            exifRow(label: config.localized("Camera"), value: make)
                        }
                        if let lens = data.lensModel {
                            exifRow(label: config.localized("Lens"), value: lens)
                        }
                    }

                    // Exposure section
                    if data.focalLength != nil || data.aperture != nil || data.shutterSpeed != nil || data.iso != nil {
                        sectionHeader(config.localized("Exposure"))
                        if let focal = data.focalLength {
                            exifRow(label: config.localized("Focal Length"), value: "\(formatNumber(focal)) mm")
                        }
                        // Combine exposure like Lightroom: "1/2000 at f/6.3, ISO 1600"
                        exifRow(label: config.localized("Exposure"), value: formatExposure(data))
                        if let bias = data.exposureBias, bias != 0 {
                            let sign = bias >= 0 ? "+" : ""
                            exifRow(label: config.localized("Exp Comp"), value: "\(sign)\(formatNumber(bias)) EV")
                        }
                        if let metering = data.meteringMode {
                            exifRow(label: config.localized("Metering"), value: metering)
                        }
                        if let wb = data.whiteBalance {
                            exifRow(label: config.localized("White Balance"), value: wb)
                        }
                    }

                    // Image section
                    if data.imageWidth != nil || data.dateTimeOriginal != nil {
                        sectionHeader(config.localized("Image"))
                        if let date = data.dateTimeOriginal {
                            exifRow(label: config.localized("Capture Date"), value: formatDate(date))
                        }
                        if let w = data.imageWidth, let h = data.imageHeight {
                            exifRow(label: config.localized("Dimensions"), value: "\(w) \u{00D7} \(h)")
                        }
                    }

                    // Location section
                    if data.latitude != nil || data.city != nil {
                        sectionHeader(config.localized("Location"))
                        if let location = formatLocation(data) {
                            exifRow(label: config.localized("Place"), value: location)
                        }
                        if let lat = data.latitude, let lon = data.longitude {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(config.localized("GPS"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                    .lineLimit(1)
                                Text(formatCoordinates(data) ?? "")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("Exif_GPS")
                                Button {
                                    let label = formatLocation(data) ?? config.localized("Photo Location")
                                    let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")&z=14")!
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "map")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(config.localized("Open in Maps"))
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                        }
                        if let alt = data.altitude {
                            exifRow(label: config.localized("Altitude"), value: "\(Int(alt)) m")
                        }
                    }

                    // Keywords section
                    if !data.keywords.isEmpty {
                        sectionHeader(config.localized("Keywords"))
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
                    Text(config.localized("No EXIF data"))
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
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
                .textCase(.uppercase)
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
        if let shutter = data.shutterSpeed { parts.append(shutter) }
        if let aperture = data.aperture { parts.append("f/\(formatNumber(aperture))") }
        if let iso = data.iso { parts.append("ISO \(iso)") }
        if parts.isEmpty { return "—" }
        // "1/2000 at f/6.3, ISO 1600"
        if parts.count >= 2, data.shutterSpeed != nil, data.aperture != nil {
            let shutter = parts.removeFirst()
            let aperture = parts.removeFirst()
            var result = "\(shutter) at \(aperture)"
            if !parts.isEmpty { result += ", \(parts.joined(separator: ", "))" }
            return result
        }
        return parts.joined(separator: ", ")
    }

    private func formatDate(_ raw: String) -> String {
        // EXIF "yyyy:MM:dd HH:mm:ss" → localized medium date + short time.
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }

        let display = DateFormatter()
        display.locale = config.appLanguage.locale
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
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
