import SwiftUI

/// Floating panel that displays EXIF metadata for the selected photo.
struct ExifPanelView: View {
    let photo: Photo
    @State private var exifData: EXIFData?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if loaded, let data = exifData, !data.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Info")
                        .font(.headline)
                        .padding(.bottom, 4)

                    // Camera
                    if let make = data.cameraMake {
                        exifRow(label: "Make", value: make)
                    }
                    if let model = data.cameraModel {
                        exifRow(label: "Model", value: model)
                    }
                    if let lens = data.lensModel {
                        exifRow(label: "Lens", value: lens)
                    }

                    // Exposure settings
                    if let focal = data.focalLength {
                        exifRow(label: "Focal Length", value: "\(formatNumber(focal)) mm")
                    }
                    if let aperture = data.aperture {
                        exifRow(label: "Aperture", value: "f/\(formatNumber(aperture))")
                    }
                    if let shutter = data.shutterSpeed {
                        exifRow(label: "Shutter", value: shutter)
                    }
                    if let iso = data.iso {
                        exifRow(label: "ISO", value: "\(iso)")
                    }
                    if let bias = data.exposureBias {
                        let sign = bias >= 0 ? "+" : ""
                        exifRow(label: "Exposure Bias", value: "\(sign)\(formatNumber(bias)) EV")
                    }

                    // Metering / WB
                    if let metering = data.meteringMode {
                        exifRow(label: "Metering", value: metering)
                    }
                    if let wb = data.whiteBalance {
                        exifRow(label: "White Balance", value: wb)
                    }

                    // Dimensions
                    if let w = data.imageWidth, let h = data.imageHeight {
                        exifRow(label: "Dimensions", value: "\(w) x \(h)")
                    }

                    // Date
                    if let date = data.dateTimeOriginal {
                        exifRow(label: "Date", value: date)
                    }

                    // Location
                    if let location = formatLocation(data) {
                        exifRow(label: "Location", value: location)
                    }
                    if let coords = formatCoordinates(data) {
                        exifRow(label: "GPS", value: coords)
                    }
                    if let alt = data.altitude {
                        exifRow(label: "Altitude", value: "\(Int(alt)) m")
                    }

                    // Keywords
                    if !data.keywords.isEmpty {
                        exifRow(label: "Keywords", value: data.keywords.joined(separator: ", "))
                    }
                }
                .padding()
            } else if loaded {
                VStack {
                    Spacer()
                    Text("No EXIF data available")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .accessibilityIdentifier("ExifNoData")
                    Spacer()
                }
                .padding()
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
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

    private func exifRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .accessibilityIdentifier("Exif_\(label)")
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
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
