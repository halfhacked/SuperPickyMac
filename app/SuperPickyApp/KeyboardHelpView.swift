import SwiftUI

struct KeyboardHelpView: View {
    @Environment(CullingConfig.self) private var config
    @Binding var isPresented: Bool

    private let shortcuts: [(key: String, action: String)] = [
        ("← →", "Navigate photos"),
        ("⇧← →", "Extend selection"),
        ("⌘A", "Select all"),
        ("esc", "Collapse selection"),
        ("F", "Fullscreen viewer"),
        ("C", "Compare mode"),
        ("I", "Toggle info"),
        ("Z", "Toggle zoom (100% ↔ fit)"),
        ("= / -", "Adjust brightness"),
        ("0–5", "Rate selection"),
        ("P", "Pick / unpick selection"),
        ("X", "Reject selection"),
        ("⌫", "Delete photo to Trash"),
        ("⌘⌫", "Delete all rejected photos to Trash"),
        ("⌘Z", "Undo last action"),
        ("⌘0–5", "Set minimum star filter"),
        ("⌘E", "Export picks"),
        ("?", "Show this help"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 0) {
                Text(config.localized("Keyboard Shortcuts"))
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shortcuts, id: \.key) { shortcut in
                            HStack {
                                Text(shortcut.key)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 80, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                Text(config.localized(shortcut.action))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.vertical, 4)

                Divider()
                Text(config.localized("Press any key to dismiss"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(12)
            }
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 16)
        }
        .accessibilityIdentifier("KeyboardHelpOverlay")
    }
}
