import SwiftUI

/// Read-only 5-star rating display. Fills stars up to `rating`, uses
/// primary color when rated and secondary when zero. Pick a `Size` preset
/// instead of applying font/frame modifiers at the call site.
struct StarRatingView: View {
    /// Visual size preset controlling glyph point size and inter-star spacing.
    enum Size {
        case small, medium, large

        var pointSize: CGFloat {
            switch self {
            case .small: 5
            case .medium: 7
            case .large: 12
            }
        }

        var spacing: CGFloat {
            switch self {
            case .small: 1
            case .medium: 1
            case .large: 2
            }
        }
    }

    let rating: Int
    var size: Size = .medium

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: size.pointSize))
                    .foregroundStyle(color)
            }
        }
    }

    private var color: Color {
        rating > 0 ? .primary : .secondary
    }
}
