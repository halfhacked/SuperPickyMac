import SwiftUI

struct FullscreenViewer: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    @State private var showInfo = false
    @Bindable var zoomState: ZoomState
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                    .accessibilityIdentifier("FullscreenViewer")

                if let photo = selectedPhoto {
                    if let image {
                        ZoomableImageView(image: image, zoomState: zoomState)
                    } else {
                        VStack {
                            ProgressView()
                                .controlSize(.large)
                            Text(photo.filename)
                                .foregroundStyle(.white)
                                .padding(.top, 8)
                        }
                    }

                    if showInfo {
                        VStack {
                            Spacer()
                            InfoBarView(photo: photo)
                        }
                    }
                }
            }
        }
        .task(id: selectedPhotoID) {
            zoomState.reset()
            guard let photo = selectedPhoto else { image = nil; return }
            // Fast: load embedded preview first
            let preview = await loadImage(path: photo.filePath, fullRes: false)
            image = preview
            // Then upgrade to full-res in background
            let full = await loadImage(path: photo.filePath, fullRes: true)
            if let full { image = full }
        }
    }

    private var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    private func navigatePhoto(direction: Int) {
        guard let currentID = selectedPhotoID,
              let currentIndex = photos.firstIndex(where: { $0.id == currentID }) else { return }
        let newIndex = currentIndex + direction
        guard photos.indices.contains(newIndex) else { return }
        selectedPhotoID = photos[newIndex].id
    }

    private func rateSelected(_ rating: Int) {
        guard let id = selectedPhotoID else { return }
        onRatePhoto?(id, rating)
    }

    private func loadImage(path: String, fullRes: Bool) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let cgImage: CGImage?
                if fullRes {
                    cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
                } else {
                    cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceThumbnailMaxPixelSize: 2000,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
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
