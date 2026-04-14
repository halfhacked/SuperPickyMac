import SwiftUI

struct FullscreenViewer: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    var onRatePhoto: ((UUID, Int) -> Void)?
    @State private var showInfo = false
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
        .task(id: selectedPhotoID) {
            isFullRes = false
            zoomState.reset()
            guard let photo = selectedPhoto else { image = nil; return }
            image = await ImageLoader.load(path: photo.filePath, maxPixelSize: 2000)
        }
        .onChange(of: zoomState.scale) { _, newScale in
            if newScale > 1.0 && !isFullRes, let photo = selectedPhoto {
                isFullRes = true
                Task {
                    if let full = await ImageLoader.load(path: photo.filePath) {
                        image = full
                    }
                }
            }
        }
    }

    private var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }
}
