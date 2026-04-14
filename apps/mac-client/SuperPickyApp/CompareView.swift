import SwiftUI

struct CompareView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    var onTogglePick: ((UUID) -> Void)?
    @State private var rightIndex: Int = 0
    @State private var activeSide: Side = .left
    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?

    enum Side { case left, right }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                    .accessibilityIdentifier("CompareView")

                HStack(spacing: 2) {
                    // Left side (selected photo)
                    comparePanel(photo: leftPhoto, image: leftImage, side: .left)
                    // Right side (comparison photo)
                    comparePanel(photo: rightPhoto, image: rightImage, side: .right)
                }
            }
        }
        .task(id: selectedPhotoID) {
            updateIndices()
            await loadImages()
        }
        .onChange(of: rightIndex) { _, _ in
            Task { await loadRightImage() }
        }
        .background(KeyboardMonitor { key in
            return handleKey(key)
        })
    }

    @ViewBuilder
    private func comparePanel(photo: Photo?, image: NSImage?, side: Side) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .border(activeSide == side ? Color.accentColor : Color.clear, width: 2)
            .onTapGesture { activeSide = side }

            if let photo {
                HStack(spacing: 12) {
                    StarRatingView(rating: photo.starRating)
                    if photo.isPick {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    Spacer()
                    Text(photo.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black)
            }
        }
    }

    private var leftPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    private var rightPhoto: Photo? {
        guard photos.indices.contains(rightIndex) else { return nil }
        return photos[rightIndex]
    }

    private func updateIndices() {
        guard let id = selectedPhotoID,
              let idx = photos.firstIndex(where: { $0.id == id }) else { return }
        let nextIdx = idx + 1
        rightIndex = photos.indices.contains(nextIdx) ? nextIdx : max(idx - 1, 0)
    }

    private func loadImages() async {
        async let left = loadImage(for: leftPhoto)
        async let right = loadImage(for: rightPhoto)
        leftImage = await left
        rightImage = await right
    }

    private func loadRightImage() async {
        rightImage = await loadImage(for: rightPhoto)
    }

    private func loadImage(for photo: Photo?) async -> NSImage? {
        guard let photo else { return nil }
        return await ImageLoader.load(path: photo.filePath, maxPixelSize: 2000)
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        if key.isEscape || key.characters == "c" {
            isPresented = false
            return true
        }

        if key.isRightArrow {
            if rightIndex + 1 < photos.count { rightIndex += 1 }
            return true
        }
        if key.isLeftArrow {
            if rightIndex > 0 { rightIndex -= 1 }
            return true
        }

        // Rating for active side
        if let char = key.characters.first,
           let digit = char.wholeNumberValue,
           (0...5).contains(digit) {
            let photo = activeSide == .left ? leftPhoto : rightPhoto
            if let id = photo?.id {
                onRatePhoto?(id, digit)
            }
            return true
        }

        if key.characters == "p" {
            let photo = activeSide == .left ? leftPhoto : rightPhoto
            if let id = photo?.id {
                onTogglePick?(id)
            }
            return true
        }

        return false
    }
}
