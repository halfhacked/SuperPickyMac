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
            image = nil
            zoomState.reset()
            guard let photo = selectedPhoto else { return }
            image = await AsyncImageLoader.load(filePath: photo.filePath, size: .fullscreen)
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
}
