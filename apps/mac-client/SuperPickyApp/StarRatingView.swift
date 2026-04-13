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
        switch rating {
        case 5: .green
        case 4: .blue
        case 3: .yellow
        case 2: .orange
        case 1: .secondary
        default: .secondary
        }
    }
}
