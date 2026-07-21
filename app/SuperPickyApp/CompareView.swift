import SwiftUI

struct CompareView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    var onTogglePick: ((UUID) -> Void)?
    @Environment(CullingConfig.self) private var config
    @State private var rightIndex: Int = 0
    @State private var activeSide: Side = .left
    @State private var leftImage: NSImage?
    @State private var rightImage: NSImage?
    @State private var leftZoomState = ZoomState()
    @State private var rightZoomState = ZoomState()
    @State private var zoomLocked = false

    enum Side { case left, right }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                    .accessibilityIdentifier("CompareView")

                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        // Left side (selected photo)
                        comparePanel(photo: leftPhoto, image: leftImage, side: .left)
                        // Right side (comparison photo)
                        comparePanel(photo: rightPhoto, image: rightImage, side: .right)
                    }

                    // Lock zoom toolbar
                    HStack {
                        Spacer()
                        Button {
                            zoomLocked.toggle()
                            if zoomLocked {
                                rightZoomState.scale = leftZoomState.scale
                                rightZoomState.offset = leftZoomState.offset
                            }
                        } label: {
                            Image(systemName: zoomLocked ? "lock.fill" : "lock.open")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(zoomLocked ? config.localized("Zoom locked (click to unlock)") : config.localized("Lock zoom (sync both panels)"))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .background(.black)
                }
            }
        }
        .task(id: selectedPhotoID) {
            updateIndices()
            leftZoomState.reset()
            rightZoomState.reset()
            await loadImages()
        }
        .onChange(of: rightIndex) { _, _ in
            Task { await loadRightImage() }
        }
        .onChange(of: leftZoomState.scale) { _, newScale in
            if zoomLocked { rightZoomState.scale = newScale }
        }
        .onChange(of: leftZoomState.offset) { _, newOffset in
            if zoomLocked { rightZoomState.offset = newOffset }
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
                    ZoomableImageView(image: image, zoomState: side == .left ? leftZoomState : rightZoomState)
                } else {
                    Rectangle().fill(.black)
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
                            .transition(.opacity)
                    }
                    if photo.isRejected {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .transition(.opacity)
                    }
                    Spacer()
                    Text(photo.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black)
                .animation(.easeInOut(duration: 0.2), value: photo.isPick)
                .animation(.easeInOut(duration: 0.2), value: photo.isRejected)
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
        // Decode in parallel via async let. Return CGImage (Sendable) from
        // the child tasks and wrap in NSImage on MainActor — NSImage isn't
        // Sendable, so `async let` with an NSImage return fails Swift 6
        // strict-concurrency checking.
        async let left = loadCGImage(for: leftPhoto)
        async let right = loadCGImage(for: rightPhoto)
        let (l, r) = await (left, right)
        guard !Task.isCancelled else { return }
        leftImage = l.map(Self.makeNSImage)
        rightImage = r.map(Self.makeNSImage)
    }

    private func loadRightImage() async {
        let cg = await loadCGImage(for: rightPhoto)
        guard !Task.isCancelled else { return }
        rightImage = cg.map(Self.makeNSImage)
    }

    private func loadCGImage(for photo: Photo?) async -> CGImage? {
        guard let photo else { return nil }
        return await ImageLoader.loadCGImage(path: photo.filePath, maxPixelSize: 2000)
    }

    private static func makeNSImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        if key.isEscape || key.characters == "c" {
            isPresented = false
            return true
        }

        if key.isRightArrow {
            if activeSide == .right {
                if rightIndex + 1 < photos.count { rightIndex += 1 }
            } else {
                if let currentID = selectedPhotoID,
                   let idx = photos.firstIndex(where: { $0.id == currentID }),
                   idx + 1 < photos.count {
                    selectedPhotoID = photos[idx + 1].id
                }
            }
            return true
        }
        if key.isLeftArrow {
            if activeSide == .right {
                if rightIndex > 0 { rightIndex -= 1 }
            } else {
                if let currentID = selectedPhotoID,
                   let idx = photos.firstIndex(where: { $0.id == currentID }),
                   idx > 0 {
                    selectedPhotoID = photos[idx - 1].id
                }
            }
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
