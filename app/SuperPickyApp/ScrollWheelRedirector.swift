import SwiftUI
import AppKit

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
        guard let _ = self.window else { return event }
        let locationInWindow = event.locationInWindow
        let locationInView = self.convert(locationInWindow, from: nil)

        if !self.bounds.contains(locationInView) { return event }

        // Find the NSScrollView in our superview hierarchy
        guard let scrollView = findScrollView() else {
            return event
        }

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
