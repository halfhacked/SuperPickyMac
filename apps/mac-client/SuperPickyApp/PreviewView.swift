import SwiftUI

struct PreviewView: View {
    let photo: Photo?

    var body: some View {
        VStack(spacing: 0) {
            if let photo {
                // Photo preview
                AsyncPreviewImage(filePath: photo.filePath)
                    .accessibilityIdentifier("PhotoPreview")
                InfoBarView(photo: photo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bird")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text("Select a photo to preview")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Loads a full-size preview image asynchronously.
struct AsyncPreviewImage: View {
    let filePath: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                ProgressView()
            }
        }
        .task(id: filePath) {
            image = nil
            image = await loadImage()
        }
    }

    private func loadImage() async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                // For preview, use a larger size (max 2000px)
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 2000,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                continuation.resume(returning: nsImage)
            }
        }
    }
}

struct InfoBarView: View {
    let photo: Photo

    private var hasBird: Bool { photo.starRating >= 0 && photo.birdConfidence != nil }

    var body: some View {
        HStack(spacing: 16) {
            StarRatingView(rating: photo.starRating)

            if !hasBird {
                Text("No bird detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasBird, let sharpness = photo.sharpnessScore, sharpness > 0 {
                Label("Sharp: \(Int(sharpness))", systemImage: "scope")
                    .font(.caption)
            }

            if hasBird, let aesthetics = photo.aestheticsScore {
                Label("Aesth: \(String(format: "%.1f", aesthetics))", systemImage: "sparkles")
                    .font(.caption)
            }

            if photo.isFlying {
                Label("Flying", systemImage: "bird")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let species = photo.speciesScientificName {
                Label {
                    Text(photo.speciesCommonName ?? species)
                    if let conf = photo.speciesConfidence {
                        Text("\(Int(conf * 100))%")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bird.fill")
                }
                .font(.caption)
            }

            Spacer()

            Text(photo.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("InfoBar")
    }
}
