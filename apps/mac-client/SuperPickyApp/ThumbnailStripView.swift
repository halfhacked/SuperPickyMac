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
            .verticalScrollToHorizontal()
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

/// Loads a thumbnail from a file path asynchronously.
struct AsyncThumbnailImage: View {
    let filePath: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task {
            image = await loadThumbnail()
        }
    }

    private func loadThumbnail() async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        // Load and resize on background thread
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Request a thumbnail at max 160px (2x for retina)
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                continuation.resume(returning: nsImage)
            }
        }
    }
}

// MARK: - Vertical scroll wheel → horizontal scroll

/// NSView that intercepts vertical scroll wheel and redirects to the parent NSScrollView horizontally.
struct ScrollWheelRedirector: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollWheelRedirectorView {
        ScrollWheelRedirectorView()
    }
    func updateNSView(_ nsView: ScrollWheelRedirectorView, context: Context) {}
}

class ScrollWheelRedirectorView: NSView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            // Walk up the responder chain to find the NSScrollView
            var responder: NSResponder? = self.nextResponder
            while let r = responder {
                if let scrollView = r as? NSScrollView {
                    let clip = scrollView.contentView
                    var origin = clip.bounds.origin
                    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
                    origin.x -= event.scrollingDeltaY * multiplier
                    let maxX = max(0, (scrollView.documentView?.bounds.width ?? 0) - scrollView.bounds.width)
                    origin.x = min(max(0, origin.x), maxX)
                    clip.scroll(to: origin)
                    scrollView.reflectScrolledClipView(clip)
                    return
                }
                responder = r.nextResponder
            }
        }
        super.scrollWheel(with: event)
    }
}

extension View {
    func verticalScrollToHorizontal() -> some View {
        self.background(ScrollWheelRedirector())
    }
}

