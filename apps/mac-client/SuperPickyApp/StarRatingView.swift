import SwiftUI

struct StarRatingView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(color)
            }
        }
    }

    private var color: Color {
        rating > 0 ? .primary : .secondary
    }
}
