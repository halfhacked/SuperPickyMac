import SwiftUI

struct StarRatingView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(color)
            }
        }
    }

    private var color: Color {
        switch rating {
        case 3: .green
        case 2: .blue
        case 1: .yellow
        default: .secondary
        }
    }
}
