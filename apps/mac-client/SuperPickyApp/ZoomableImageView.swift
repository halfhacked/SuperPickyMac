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

    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
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
