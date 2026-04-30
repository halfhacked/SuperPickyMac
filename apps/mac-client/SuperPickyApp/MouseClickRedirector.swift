import AppKit
import SwiftUI

/// A zero-size SwiftUI background view that installs an NSEvent local
/// monitor for `.leftMouseDown` and reports `(point-in-window, modifier-
/// flags)` to its callback. Intended to back the filmstrip so multi-
/// select clicks can carry shift / cmd modifiers — `.onTapGesture`
/// silently drops modifier flags. Pattern mirrors `ScrollWheelRedirector`.
struct MouseClickRedirector: NSViewRepresentable {
    typealias OnClick = (_ pointInWindow: NSPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool

    let onClick: OnClick

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onClick = onClick
    }

    private final class MonitorView: NSView {
        var onClick: OnClick?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      let cb = self.onClick else { return event }
                let pointInWindow = event.locationInWindow
                if cb(pointInWindow, event.modifierFlags) {
                    return nil
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
