import AppKit
import SwiftUI

enum NewTabDestination: CaseIterable {
    case browser, chat

    var label: String { self == .browser ? "Browser" : "Chat" }
    var symbol: String { self == .browser ? "globe" : "square.and.pencil" }
}

/// Window-level input also works when a website currently owns the keyboard.
struct WorkspaceTabLauncher: View {
    static let requestNotification = Notification.Name("Kolmogor.OpenWorkspaceTabLauncher")

    static func request(in window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.post(name: requestNotification, object: window)
    }

    let launch: (NewTabDestination, String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var selection = NewTabDestination.browser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                LauncherField(text: $text, selection: $selection, launch: launch, cancel: cancel)
                    .frame(height: 32)
            }
            .padding(.horizontal, 8)
            Divider()
            ForEach(NewTabDestination.allCases, id: \.self) { destination in
                Button { launch(destination, text) } label: {
                    HStack {
                        Image(systemName: destination.symbol).frame(width: 22)
                        Text(destination.label)
                        Spacer()
                        if selection == destination {
                            Image(systemName: "return").foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(selection == destination ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == destination ? .isSelected : [])
            }
        }
        .padding(10)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

// Handle the field editor's actual commands, including Return before SwiftUI
// publishes a text change. Leave marked text and IME candidate selection alone.
private struct LauncherField: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NewTabDestination
    let launch: (NewTabDestination, String) -> Void
    let cancel: () -> Void

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: LauncherField
        init(_ field: LauncherField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            if let sender = notification.object as? NSTextField { field.text = sender.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): field.selection = .chat
            case #selector(NSResponder.moveUp(_:)): field.selection = .browser
            case #selector(NSResponder.insertNewline(_:)): field.launch(field.selection, textView.string)
            case #selector(NSResponder.cancelOperation(_:)): field.cancel()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.placeholderString = "Search Google or start a chat"
        field.setAccessibilityLabel("New tab")
        field.identifier = .init("workspace-tab-launcher")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) { context.coordinator.field = self }
}
