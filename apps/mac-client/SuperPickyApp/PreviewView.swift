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
        await ImageLoader.load(path: filePath, maxPixelSize: maxSize)
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
