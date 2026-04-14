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

/// Uses NSEvent.addLocalMonitorForEvents to intercept vertical scroll wheel
/// events over this view and convert them to horizontal scrolling.
struct ScrollWheelRedirector: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollWheelMonitorView {
        ScrollWheelMonitorView()
    }
    func updateNSView(_ nsView: ScrollWheelMonitorView, context: Context) {}
}

class ScrollWheelMonitorView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self else { return event }
                return self.handleScroll(event)
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.removeFromSuperview()
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // Only intercept vertical scroll
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }

        // Check if cursor is over our view's frame
        guard let window = self.window else { return event }
        let locationInWindow = event.locationInWindow
        let locationInView = self.convert(locationInWindow, from: nil)
        guard self.bounds.contains(locationInView) else { return event }

        // Find the NSScrollView in our superview hierarchy
        guard let scrollView = findScrollView() else { return event }

        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        origin.x -= event.scrollingDeltaY * mult
        let maxX = max(0, (scrollView.documentView?.bounds.width ?? 0) - scrollView.bounds.width)
        origin.x = min(max(0, origin.x), maxX)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return nil // Consume the event
    }

    private func findScrollView() -> NSScrollView? {
        var view: NSView? = self.superview
        while let v = view {
            if let sv = v as? NSScrollView { return sv }
            for sub in v.subviews where sub is NSScrollView {
                return sub as? NSScrollView
            }
            view = v.superview
        }
        return nil
    }
}

