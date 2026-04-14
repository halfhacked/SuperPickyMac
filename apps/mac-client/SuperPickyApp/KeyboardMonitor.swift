import SwiftUI
import AppKit

/// App-level keyboard monitor using NSEvent.addLocalMonitorForEvents.
/// Works regardless of which SwiftUI view has focus.
struct KeyboardMonitor: NSViewRepresentable {
    let onKey: (KeyEvent) -> Bool

    struct KeyEvent {
        let characters: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let isEscape: Bool
        let isReturn: Bool
        let isLeftArrow: Bool
        let isRightArrow: Bool
        let mouseLocationInWindow: CGPoint
    }

    func makeNSView(context: Context) -> KeyboardMonitorView {
        let view = KeyboardMonitorView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyboardMonitorView, context: Context) {
        nsView.onKey = onKey
    }
}

class KeyboardMonitorView: NSView {
    var onKey: ((KeyboardMonitor.KeyEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let onKey = self.onKey else { return event }

                // Don't intercept if a text field is focused
                if let firstResponder = event.window?.firstResponder,
                   firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }

                let keyEvent = KeyboardMonitor.KeyEvent(
                    characters: event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    isEscape: event.keyCode == 53,
                    isReturn: event.keyCode == 36,
                    isLeftArrow: event.keyCode == 123,
                    isRightArrow: event.keyCode == 124,
                    mouseLocationInWindow: event.window?.mouseLocationOutsideOfEventStream ?? .zero
                )

                let handled = onKey(keyEvent)
                return handled ? nil : event
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
}
