import SwiftUI

struct FullscreenViewer: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    @Binding var isPresented: Bool
    @State private var showInfo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let photo = selectedPhoto {
                VStack {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 120))
                        .foregroundStyle(.gray)
                    Text(photo.filename)
                        .foregroundStyle(.white)
                }

                if showInfo {
                    VStack {
                        Spacer()
                        InfoBarView(photo: photo)
                    }
                }
            }
        }
        .onKeyPress(.leftArrow) { navigatePhoto(direction: -1); return .handled }
        .onKeyPress(.rightArrow) { navigatePhoto(direction: 1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress("i") { showInfo.toggle(); return .handled }
        .onKeyPress("1") { rateSelected(1); return .handled }
        .onKeyPress("2") { rateSelected(2); return .handled }
        .onKeyPress("3") { rateSelected(3); return .handled }
        .onKeyPress("0") { rateSelected(0); return .handled }
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
        // Rating update will be wired to database in future task
    }
}
