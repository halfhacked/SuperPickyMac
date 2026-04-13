import SwiftUI

struct PreviewView: View {
    let photo: Photo?

    var body: some View {
        VStack(spacing: 0) {
            if let photo {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    VStack {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                        Text(photo.filename)
                            .foregroundStyle(.secondary)
                    }
                }
                InfoBarView(photo: photo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bird")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text("Select a photo to preview")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Process a folder with + to get started")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct InfoBarView: View {
    let photo: Photo

    var body: some View {
        HStack(spacing: 16) {
            StarRatingView(rating: photo.starRating)

            if let sharpness = photo.sharpnessScore {
                Label("Sharp: \(Int(sharpness))", systemImage: "scope")
                    .font(.caption)
            }

            if let aesthetics = photo.aestheticsScore {
                Label("Aesth: \(String(format: "%.1f", aesthetics))", systemImage: "sparkles")
                    .font(.caption)
            }

            if photo.isFlying {
                Label("Flying", systemImage: "bird")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let species = photo.speciesScientificName {
                Label {
                    Text(photo.speciesCommonName ?? species)
                    if let conf = photo.speciesConfidence {
                        Text("\(Int(conf * 100))%")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bird.fill")
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
