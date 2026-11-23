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
        WorkspaceCommandPanel(width: 360) {
            WorkspaceCommandField(text: $text, placeholder: "Search Google or start a chat", label: "New tab",
                                  identifier: "workspace-tab-launcher", move: { selection = $0 > 0 ? .chat : .browser },
                                  submit: { launch(selection, $0) }, cancel: cancel)
        } choices: {
            Divider()
            ForEach(NewTabDestination.allCases, id: \.self) { destination in
                WorkspaceCommandRow(title: destination.label, symbol: destination.symbol, selected: selection == destination) {
                    launch(destination, text)
                }
            }
        }
    }
}

struct WorkspaceCommandPanel<Field: View, Choices: View>: View {
    let width: CGFloat
    @ViewBuilder let field: () -> Field
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                field().frame(height: 32)
            }
            .padding(.horizontal, 8)
            choices()
        }
        .padding(10)
        .frame(width: width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

struct WorkspaceCommandRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol).frame(width: 22)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected { Image(systemName: "return").foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// Handle the field editor's actual commands, including Return before SwiftUI
// publishes a text change. Leave marked text and IME candidate selection alone.
struct WorkspaceCommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let identifier: String
    var focusRequest: Int = 0
    let move: (Int) -> Void
    let submit: (String) -> Void
    let cancel: () -> Void

    final class Field: NSTextField {
        var lastFocusRequest = 0

        func focusAndSelect() {
            guard let window else { return }
            if let editor = currentEditor() as? NSTextView {
                if !editor.hasMarkedText() { editor.selectAll(nil) }
            } else {
                window.makeFirstResponder(self)
                selectText(nil)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusAndSelect()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: WorkspaceCommandField
        init(_ field: WorkspaceCommandField) { self.field = field }

        func controlTextDidChange(_ notification: Notification) {
            if let sender = notification.object as? NSTextField { field.text = sender.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): field.move(1)
            case #selector(NSResponder.moveUp(_:)): field.move(-1)
            case #selector(NSResponder.insertNewline(_:)): field.submit(textView.string)
            case #selector(NSResponder.cancelOperation(_:)): field.cancel()
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        field.identifier = .init(identifier)
        field.stringValue = text
        field.lastFocusRequest = focusRequest
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.field = self
        if field.lastFocusRequest != focusRequest {
            field.lastFocusRequest = focusRequest
            field.focusAndSelect()
        }
    }
}
