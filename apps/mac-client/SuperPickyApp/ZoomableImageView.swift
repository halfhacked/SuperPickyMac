import SwiftUI
import AppKit

// MARK: - ZoomState (testable logic)

@Observable
final class ZoomState {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 10.0

    func zoom(by factor: CGFloat) {
        scale = min(max(scale * factor, Self.minScale), Self.maxScale)
        if scale <= 1.0 { offset = .zero }
    }

    func toggleFitActualPixels(imagePixelWidth: CGFloat, viewWidth: CGFloat) {
        if scale == 1.0 {
            scale = imagePixelWidth / viewWidth
            scale = min(max(scale, Self.minScale), Self.maxScale)
        } else {
            scale = 1.0
            offset = .zero
        }
    }

    /// Toggle between fit and 100% zoom. The point under the mouse stays fixed on screen.
    func toggleFitActualPixelsAt(imagePixelWidth: CGFloat, viewSize: CGSize, mouseInView: CGPoint) {
        let oldScale = scale
        let oldOffset = offset
        let cx = viewSize.width / 2
        let cy = viewSize.height / 2

        if scale <= 1.0 {
            let newScale = min(max(imagePixelWidth / viewSize.width, Self.minScale), Self.maxScale)
            // Image point under cursor: (mouse - center - offset) / oldScale
            let imgX = (mouseInView.x - cx - oldOffset.width) / oldScale
            let imgY = (mouseInView.y - cy - oldOffset.height) / oldScale
            // New offset so same image point stays under cursor
            scale = newScale
            offset = CGSize(
                width: mouseInView.x - cx - imgX * newScale,
                height: mouseInView.y - cy - imgY * newScale
            )
        } else {
            scale = 1.0
            offset = .zero
        }
    }

    func reset() {
        scale = 1.0
        offset = .zero
    }

    func pan(by delta: CGSize) {
        guard scale > 1.0 else { return }
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
    }
}

// MARK: - ZoomableImageView

struct ZoomableImageView: View {
    let image: NSImage
    @Bindable var zoomState: ZoomState
    var brightnessAdjustment: Double = 0

    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .brightness(brightnessAdjustment)
                .scaleEffect(zoomState.scale)
                .offset(zoomState.offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onTapGesture(count: 2) {
                    dragStart = .zero
                    zoomState.toggleFitActualPixels(
                        imagePixelWidth: image.size.width,
                        viewWidth: geo.size.width
                    )
                }
                .background(
                    ScrollWheelView { delta in
                        let factor: CGFloat = delta > 0 ? 1.05 : (1.0 / 1.05)
                        zoomState.zoom(by: factor)
                    }
                )
                .onChange(of: zoomState.scale) { _, newScale in
                    // Sync dragStart when zoom changes (Z key, scroll wheel)
                    dragStart = zoomState.offset
                    if newScale <= 1.0 { dragStart = .zero }
                }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomState.scale > 1.0 else { return }
                zoomState.offset = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = zoomState.offset
            }
    }
}

// MARK: - ScrollWheelView (NSViewRepresentable for scroll wheel events)

struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        onScroll?(delta)
    }
}
