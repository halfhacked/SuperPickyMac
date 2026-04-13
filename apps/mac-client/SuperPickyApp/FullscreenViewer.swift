import SwiftUI

struct FullscreenViewer: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    @State private var showInfo = false
    @State private var zoomState = ZoomState()
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

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
            .onKeyPress("z") {
                guard let img = image else { return .ignored }
                zoomState.toggleFitActualPixels(
                    imagePixelWidth: img.size.width,
                    viewWidth: geo.size.width
                )
                return .handled
            }
        }
        .onKeyPress(.leftArrow) { navigatePhoto(direction: -1); return .handled }
        .onKeyPress(.rightArrow) { navigatePhoto(direction: 1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress("i") { showInfo.toggle(); return .handled }
        .onKeyPress("0") { rateSelected(0); return .handled }
        .onKeyPress("1") { rateSelected(1); return .handled }
        .onKeyPress("2") { rateSelected(2); return .handled }
        .onKeyPress("3") { rateSelected(3); return .handled }
        .onKeyPress("4") { rateSelected(4); return .handled }
        .onKeyPress("5") { rateSelected(5); return .handled }
        .task(id: selectedPhotoID) {
            image = nil
            zoomState.reset()
            guard let photo = selectedPhoto else { return }
            image = await loadFullscreenImage(path: photo.filePath)
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

    private func loadFullscreenImage(path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Full resolution for fullscreen
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4000,
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
