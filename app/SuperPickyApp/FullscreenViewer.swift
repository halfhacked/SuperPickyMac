import SwiftUI

struct FullscreenViewer: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    var onSetPickStatus: ((UUID, PhotoPickStatus) -> Void)?
    @State private var showInfo = true
    @Bindable var zoomState: ZoomState
    @State private var image: NSImage?
    @State private var isFullRes = false

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
        .background(KeyboardMonitor { key in
            handleKey(key)
        })
        .task(id: selectedPhotoID) {
            isFullRes = false
            guard let photo = selectedPhoto else { image = nil; return }
            if zoomState.scale > 1.0 {
                isFullRes = true
                if let cached = ImageCache.fullRes.get(photo.filePath) {
                    image = cached
                    return
                }
                guard let full = await ImageLoader.load(path: photo.filePath) else { return }
                guard !Task.isCancelled else { return }
                ImageCache.fullRes.set(photo.filePath, image: full)
                image = full
                return
            }
            if let cached = ImageCache.preview.get(photo.filePath) {
                image = cached
            } else if let loaded = await ImageLoader.load(path: photo.filePath, maxPixelSize: 2000) {
                guard !Task.isCancelled else { return }
                ImageCache.preview.set(photo.filePath, image: loaded)
                image = loaded
            }
        }
        .onChange(of: zoomState.scale) { _, newScale in
            guard newScale > 1.0, !isFullRes, let photo = selectedPhoto else { return }
            isFullRes = true
            if let cached = ImageCache.fullRes.get(photo.filePath) {
                image = cached
                return
            }
            let pinnedID = photo.id
            Task {
                guard let full = await ImageLoader.load(path: photo.filePath) else {
                    if !Task.isCancelled, selectedPhotoID == pinnedID { isFullRes = false }
                    return
                }
                ImageCache.fullRes.set(photo.filePath, image: full)
                guard !Task.isCancelled, selectedPhotoID == pinnedID else { return }
                image = full
            }
        }
    }

    private var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        if key.characters == "i" {
            showInfo.toggle()
            return true
        }
        if key.characters == "f" || key.isEscape {
            isPresented = false
            return true
        }
        if key.isLeftArrow { navigatePhoto(direction: -1); return true }
        if key.isRightArrow { navigatePhoto(direction: 1); return true }
        if let status = key.photoPickStatus, let id = selectedPhoto?.id {
            onSetPickStatus?(id, status)
            return true
        }
        if let char = key.characters.first,
           let digit = char.wholeNumberValue,
           (0...5).contains(digit),
           key.modifiers.intersection([.command, .shift, .option, .control]).isEmpty {
            if let id = selectedPhoto?.id {
                onRatePhoto?(id, digit)
            }
            return true
        }
        return false
    }

    private func navigatePhoto(direction: Int) {
        guard let currentID = selectedPhotoID,
              let currentIndex = photos.firstIndex(where: { $0.id == currentID }) else { return }
        let newIndex = currentIndex + direction
        if photos.indices.contains(newIndex) {
            selectedPhotoID = photos[newIndex].id
        }
    }
}
