import AppKit
import SwiftUI

enum NewTabDestination: CaseIterable {
    case browser, agent

    var label: String { self == .browser ? "Browser" : "Agent" }
    @MainActor private static let agentIcon = tabIconAsset("agent", fallback: "person.crop.square").renderingMode(.template)
    @MainActor var icon: Image { self == .browser ? Image(systemName: "globe") : Self.agentIcon }
}

/// Window-level input also works when a website currently owns the keyboard.
struct WorkspaceTabLauncher: View {
    static let requestNotification = Notification.Name("Kolmogor.OpenWorkspaceTabLauncher")

    static func request(in window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.post(name: requestNotification, object: window)
    }

    var library: ChromeProfileLibrary? = nil
    var error: String?
    let launch: (NewTabDestination, String) -> Void
    let openPage: (URL) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var selection = 0
    @State private var imported = ChromeProfileLibrary.Results()
    private var places: [ChromeProfileLibrary.Suggestion] { imported.query == text ? imported.entries : [] }

    var body: some View {
        WorkspaceCommandPanel(width: 360) {
            WorkspaceCommandField(text: $text, placeholder: "Search Google or start an agent", label: "New tab",
                                  identifier: "workspace-tab-launcher", move: { selection = min(max(0, selection + $0), 1 + places.count) },
                                  submit: { value in
                                      if selection == 1 { launch(.agent, value) }
                                      else if value == text, places.indices.contains(selection - 2) { openPage(places[selection - 2].url) }
                                      else { launch(.browser, value) }
                                  }, cancel: cancel)
        } choices: {
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            Divider()
            ForEach(NewTabDestination.allCases, id: \.self) { destination in
                WorkspaceCommandRow(title: destination.label, icon: destination.icon, selected: selection == (destination == .browser ? 0 : 1)) {
                    launch(destination, text)
                }
            }
            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                WorkspaceCommandRow(title: place.label, icon: Image(systemName: place.bookmark ? "bookmark" : "clock"), selected: selection == index + 2) {
                    openPage(place.url)
                }
            }
        }
        .task(id: text) {
            let result = await ChromeProfileLibrary.Results.search(text, in: library)
            if !Task.isCancelled { imported = result }
        }
        .onChange(of: text) { _, _ in if selection > 1 { selection = 0 } }
    }
}

extension VerticalAlignment {
    private enum CommandFieldCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }
    static let commandFieldCenter = VerticalAlignment(CommandFieldCenter.self)
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
            .alignmentGuide(.commandFieldCenter) { $0[VerticalAlignment.center] }
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
    let icon: Image
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                icon.frame(width: 22).accessibilityHidden(true)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected { Image(systemName: "return").foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
