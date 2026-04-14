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

/// In-memory thumbnail cache — survives LazyHStack recycling.
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 500
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Loads a thumbnail from a file path asynchronously with caching.
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
            // Check cache first
            if let cached = ThumbnailCache.shared.get(filePath) {
                image = cached
                return
            }
            if let loaded = await loadThumbnail() {
                ThumbnailCache.shared.set(filePath, image: loaded)
                image = loaded
            }
        }
    }

    private func loadThumbnail() async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
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
        print("[ScrollWheelMonitor] viewDidMoveToWindow, window=\(window != nil), monitor=\(monitor != nil)")
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self else { return event }
                return self.handleScroll(event)
            }
            print("[ScrollWheelMonitor] Monitor installed")
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
        guard let _ = self.window else { return event }
        let locationInWindow = event.locationInWindow
        let locationInView = self.convert(locationInWindow, from: nil)

        if !self.bounds.contains(locationInView) { return event }
        print("[ScrollWheelMonitor] Scroll intercepted! deltaY=\(event.scrollingDeltaY)")

        // Find the NSScrollView in our superview hierarchy
        guard let scrollView = findScrollView() else {
            print("[ScrollWheelMonitor] No NSScrollView found!")
            return event
        }
        print("[ScrollWheelMonitor] Found scroll view, redirecting")

        // Convert vertical delta to horizontal and let NSScrollView handle clamping
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        origin.x -= event.scrollingDeltaY * mult
        let constrainedPoint = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: constrainedPoint)
        scrollView.reflectScrolledClipView(clip)
        return nil // Consume the event
    }

    private var cachedScrollView: NSScrollView?

    private func findScrollView() -> NSScrollView? {
        if let cached = cachedScrollView, cached.window != nil { return cached }
        // The background NSView is in a different branch than the ScrollView's NSScrollView.
        // Search the entire window view hierarchy for the horizontal NSScrollView
        // that contains our view's frame.
        guard let window = self.window else { return nil }
        let myFrameInWindow = self.convert(self.bounds, to: nil)
        cachedScrollView = findHorizontalScrollView(in: window.contentView, containing: myFrameInWindow)
        return cachedScrollView
    }

    private func findHorizontalScrollView(in view: NSView?, containing frame: NSRect) -> NSScrollView? {
        guard let view = view else { return nil }
        if let sv = view as? NSScrollView, sv.hasHorizontalScroller || !sv.hasVerticalScroller {
            let svFrame = sv.convert(sv.bounds, to: nil)
            if svFrame.intersects(frame) { return sv }
        }
        for sub in view.subviews {
            if let found = findHorizontalScrollView(in: sub, containing: frame) {
                return found
            }
        }
        return nil
    }
}

