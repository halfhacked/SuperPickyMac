import SwiftUI

struct ThumbnailStripView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        ThumbnailCell(photo: photo, isSelected: photo.id == selectedPhotoID)
                            .id(photo.id)
                            .onTapGesture {
                                selectedPhotoID = photo.id
                            }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(ScrollWheelRedirector())
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
        ZStack {
            AsyncThumbnailImage(filePath: photo.filePath)
                .aspectRatio(3/2, contentMode: .fit)
                .clipped()

            // Flag top-left
            if photo.isPick {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.primary)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(2)
            }

            // Stars bottom-left
            StarRatingView(rating: photo.starRating)
                .padding(2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .accessibilityIdentifier("Thumbnail_\(photo.filename)")
    }
}
