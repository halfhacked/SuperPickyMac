import SwiftUI

struct PreviewView: View {
    let photo: Photo?
    @Bindable var zoomState: ZoomState
    @Binding var mouseInView: CGPoint
    @Binding var viewSize: CGSize
    @State private var previousPhotoID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let photo {
                // Photo preview — hover and size tracked on the image view itself
                AsyncPreviewImage(filePath: photo.filePath, zoomState: zoomState)
                    .accessibilityIdentifier("PhotoPreview")
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase { mouseInView = loc }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { viewSize = geo.size }
                            .onChange(of: geo.size) { _, s in viewSize = s }
                    })
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
        .onChange(of: photo?.id) { _, newID in
            if newID != previousPhotoID {
                previousPhotoID = newID
                zoomState.reset()
            }
        }
    }
}

/// Loads a full-size preview image asynchronously.
struct AsyncPreviewImage: View {
    let filePath: String
    @Bindable var zoomState: ZoomState
    @State private var image: NSImage?
    @State private var isFullRes = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                ZoomableImageView(image: image, zoomState: zoomState)
            } else {
                ProgressView()
            }
        }
        .task(id: filePath) {
            isFullRes = false
            let newImage = await loadImage(maxSize: 2000)
            image = newImage
        }
        .onChange(of: zoomState.scale) { _, newScale in
            // Load full-res when user zooms in
            if newScale > 1.0 && !isFullRes {
                isFullRes = true
                Task {
                    if let fullRes = await loadImage(maxSize: nil) {
                        image = fullRes
                    }
                }
            }
        }
    }

    private func loadImage(maxSize: Int?) async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let cgImage: CGImage?
                if let maxSize {
                    // Preview: fast embedded thumbnail
                    let options: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxSize,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ]
                    cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                } else {
                    // Full-res: decode the actual image (not just embedded preview)
                    cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
                }

                guard let cgImage else {
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

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                StarRatingView(rating: photo.starRating)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("InfoBarRating")
                    .accessibilityLabel("Star rating")
                    .accessibilityValue("\(photo.starRating)")
                if photo.isManualRating {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ManualRatingIndicator")
                }
            }

            if let sharpness = photo.sharpnessScore {
                Label("Sharp: \(Int(sharpness))", systemImage: "scope")
                    .font(.caption)
            }

            if let aesthetics = photo.aestheticsScore {
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
