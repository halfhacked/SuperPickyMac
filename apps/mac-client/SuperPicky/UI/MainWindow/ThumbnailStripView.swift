import SwiftUI

struct ThumbnailStripView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            List(photos, selection: $selectedPhotoID) { photo in
                ThumbnailCell(photo: photo)
                    .tag(photo.id)
                    .id(photo.id)
            }
            .listStyle(.plain)
            .onChange(of: selectedPhotoID) { _, newValue in
                if let id = newValue {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    let photo: Photo

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }

            if photo.starRating >= 0 {
                StarRatingView(rating: photo.starRating)
                    .padding(4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }

            if photo.isPick {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
