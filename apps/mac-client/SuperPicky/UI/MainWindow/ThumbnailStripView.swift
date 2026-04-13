import SwiftUI

struct ThumbnailStripView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { photo in
                        ThumbnailCell(photo: photo, isSelected: photo.id == selectedPhotoID)
                            .id(photo.id)
                            .onTapGesture {
                                selectedPhotoID = photo.id
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.bar)
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
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }

            if photo.starRating >= 0 {
                StarRatingView(rating: photo.starRating)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }

            if photo.isPick {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}
