import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ScreenPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public enum KeyboardModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case command
    case control
    case option
    case shift
    case function
}

public struct KeyboardChord: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: Set<KeyboardModifier>

    public init(keyCode: UInt16, modifiers: Set<KeyboardModifier> = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct ActivatedApplication: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let localizedName: String?

    public init(processIdentifier: Int32, bundleIdentifier: String, localizedName: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public enum ComputerInputError: Error, Equatable, LocalizedError, Sendable {
    case invalidBundleIdentifier
    case applicationNotFound(bundleIdentifier: String)
    case applicationProcessNotFound(processIdentifier: Int32)
    case applicationActivationFailed(processIdentifier: Int32)
    case invalidPoint(ScreenPoint)
    case invalidDragDuration(Double)
    case invalidKeyCode(UInt16)
    case eventCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier:
            return "The application bundle identifier must not be empty."
        case let .applicationNotFound(bundleIdentifier):
            return "No installed application has bundle identifier '\(bundleIdentifier)'."
        case let .applicationProcessNotFound(processIdentifier):
            return "No running application has process identifier \(processIdentifier)."
        case let .applicationActivationFailed(processIdentifier):
            return "The application with process identifier \(processIdentifier) could not be activated."
        case let .invalidPoint(point):
            return "Screen coordinates must be finite; received (\(point.x), \(point.y))."
        case let .invalidDragDuration(duration):
            return "Drag duration must be finite and between 0 and 30 seconds; received \(duration)."
        case let .invalidKeyCode(keyCode):
            return "Keyboard virtual key code must be between 0 and 127; received \(keyCode)."
        case let .eventCreationFailed(eventType):
            return "CoreGraphics could not create the \(eventType) input event."
        }
    }
}

@MainActor
protocol ComputerInputRuntime: AnyObject {
    func launchOrActivateApplication(
        bundleIdentifier: String,
        opening url: URL?
    ) async throws -> ActivatedApplication
    func activateApplication(processIdentifier: Int32) async throws -> ActivatedApplication
    func moveMouse(to point: ScreenPoint) throws
    func click(at point: ScreenPoint, count: Int, rightButton: Bool) throws
    func scrollBy(deltaX: Int32, deltaY: Int32) throws
    func drag(from start: ScreenPoint, to end: ScreenPoint, duration: Double) async throws
    func pressKeyChord(_ chord: KeyboardChord) throws
    func enterText(_ text: String) throws
}

@MainActor
enum ApplicationActivationHandoff {
    static func request(
        sourceProcessIdentifier: Int32,
        targetProcessIdentifier: Int32,
        sourceIsActive: Bool,
        yieldToTarget: () -> Void,
        activateFromSource: () -> Bool,
        activateDirectly: () -> Bool
    ) -> Bool {
        if sourceIsActive, sourceProcessIdentifier != targetProcessIdentifier {
            yieldToTarget()
            return activateFromSource()
        }
        return activateDirectly()
    }
}

@MainActor
final class SystemComputerInputRuntime: ComputerInputRuntime {
    private static let unicodeChunkSize = 20

    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func launchOrActivateApplication(
        bundleIdentifier: String,
        opening url: URL?
    ) async throws -> ActivatedApplication {
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw ComputerInputError.applicationNotFound(bundleIdentifier: bundleIdentifier)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        let application: NSRunningApplication
        if let url {
            application = try await workspace.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        } else {
            application = try await workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            )
        }

        // `NSWorkspace.OpenConfiguration.activates` is advisory for an
        // already-running browser. Confirm that the selected process really is
        // frontmost before returning so an immediate Accessibility snapshot
        // resolves its focused/main window instead of the application menu.
        return try await activateApplication(
            processIdentifier: application.processIdentifier
        )
    }

    func activateApplication(processIdentifier: Int32) async throws -> ActivatedApplication {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else {
            throw ComputerInputError.applicationProcessNotFound(
                processIdentifier: processIdentifier
            )
        }

        if !application.isActive {
            let source = NSRunningApplication.current
            let accepted = ApplicationActivationHandoff.request(
                sourceProcessIdentifier: source.processIdentifier,
                targetProcessIdentifier: application.processIdentifier,
                sourceIsActive: NSApplication.shared.isActive,
                yieldToTarget: {
                    NSApplication.shared.yieldActivation(to: application)
                },
                activateFromSource: {
                    application.activate(from: source, options: [.activateAllWindows])
                },
                activateDirectly: {
                    application.activate(options: [.activateAllWindows])
                }
            )
            guard accepted else {
                throw ComputerInputError.applicationActivationFailed(
                    processIdentifier: processIdentifier
                )
            }
        }

        for _ in 0 ..< 80 where !application.isActive {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard application.isActive else {
            throw ComputerInputError.applicationActivationFailed(
                processIdentifier: processIdentifier
            )
        }
        return ActivatedApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            localizedName: application.localizedName
        )
    }

    func moveMouse(to point: ScreenPoint) throws {
        try postMouseEvent(type: .mouseMoved, point: point, button: .left)
    }

    func click(at point: ScreenPoint, count: Int, rightButton: Bool) throws {
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp

        for clickIndex in 1 ... count {
            try postMouseEvent(
                type: downType,
                point: point,
                button: button,
                clickState: Int64(clickIndex)
            )
            try postMouseEvent(
                type: upType,
                point: point,
                button: button,
                clickState: Int64(clickIndex)
            )
        }
    }

    func scrollBy(deltaX: Int32, deltaY: Int32) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource(),
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else {
            throw ComputerInputError.eventCreationFailed("pixel scroll")
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    func drag(from start: ScreenPoint, to end: ScreenPoint, duration: Double) async throws {
        try postMouseEvent(type: .mouseMoved, point: start, button: .left)
        try postMouseEvent(type: .leftMouseDown, point: start, button: .left)

        let stepCount = min(600, max(1, Int((duration * 60).rounded(.up))))
        let nanosecondsPerStep = duration == 0
            ? UInt64(0)
            : UInt64((duration * 1_000_000_000 / Double(stepCount)).rounded())

        do {
            for step in 1 ... stepCount {
                if nanosecondsPerStep > 0 {
                    try await Task.sleep(nanoseconds: nanosecondsPerStep)
                }
                let progress = Double(step) / Double(stepCount)
                let point = ScreenPoint(
                    x: start.x + ((end.x - start.x) * progress),
                    y: start.y + ((end.y - start.y) * progress)
                )
                try postMouseEvent(type: .leftMouseDragged, point: point, button: .left)
            }
            try postMouseEvent(type: .leftMouseUp, point: end, button: .left)
        } catch {
            try? postMouseEvent(type: .leftMouseUp, point: end, button: .left)
            throw error
        }
    }

    func pressKeyChord(_ chord: KeyboardChord) throws {
        let flags = chord.modifiers.reduce(into: CGEventFlags()) { result, modifier in
            switch modifier {
            case .command:
                result.insert(.maskCommand)
            case .control:
                result.insert(.maskControl)
            case .option:
                result.insert(.maskAlternate)
            case .shift:
                result.insert(.maskShift)
            case .function:
                result.insert(.maskSecondaryFn)
            }
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: eventSource(),
            virtualKey: CGKeyCode(chord.keyCode),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: eventSource(),
            virtualKey: CGKeyCode(chord.keyCode),
            keyDown: false
        ) else {
            throw ComputerInputError.eventCreationFailed("keyboard chord")
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func enterText(_ text: String) throws {
        for chunk in UnicodeInputChunks.make(from: text, maximumUTF16Count: Self.unicodeChunkSize) {
            guard let keyDown = CGEvent(
                keyboardEventSource: eventSource(),
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: eventSource(),
                virtualKey: 0,
                keyDown: false
            ) else {
                throw ComputerInputError.eventCreationFailed("Unicode keyboard")
            }

            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return
                }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func postMouseEvent(
        type: CGEventType,
        point: ScreenPoint,
        button: CGMouseButton,
        clickState: Int64? = nil
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: eventSource(),
            mouseType: type,
            mouseCursorPosition: point.cgPoint,
            mouseButton: button
        ) else {
            throw ComputerInputError.eventCreationFailed("mouse")
        }
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    private func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .combinedSessionState)
    }
}

enum UnicodeInputChunks {
    static func make(from text: String, maximumUTF16Count: Int) -> [[UniChar]] {
        precondition(maximumUTF16Count > 1)
        let codeUnits = Array(text.utf16)
        var result = [[UniChar]]()
        var startIndex = 0

        while startIndex < codeUnits.count {
            var endIndex = min(startIndex + maximumUTF16Count, codeUnits.count)
            if endIndex < codeUnits.count, isHighSurrogate(codeUnits[endIndex - 1]) {
                endIndex -= 1
            }
            result.append(Array(codeUnits[startIndex ..< endIndex]))
            startIndex = endIndex
        }
        return result
    }

    private static func isHighSurrogate(_ codeUnit: UInt16) -> Bool {
        (0xD800 ... 0xDBFF).contains(codeUnit)
    }
}

/// Permission-gated, native macOS computer-input primitives.
///
/// Every public operation checks Accessibility without prompting before doing
/// any validation, application lookup, or input event generation.
@MainActor
public final class ComputerInputController {
    private static let maximumDragDuration = 30.0

    private let runtime: any ComputerInputRuntime
    private let accessibilityCheck: () -> Bool

    public init() {
        runtime = SystemComputerInputRuntime()
        accessibilityCheck = { AXIsProcessTrusted() }
    }

    init(
        runtime: any ComputerInputRuntime,
        accessibilityCheck: @escaping () -> Bool
    ) {
        self.runtime = runtime
        self.accessibilityCheck = accessibilityCheck
    }

    public func launchOrActivateApplication(
        bundleIdentifier: String,
        opening url: URL? = nil
    ) async throws -> ActivatedApplication {
        try requirePermission()
        guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerInputError.invalidBundleIdentifier
        }
        return try await runtime.launchOrActivateApplication(
            bundleIdentifier: bundleIdentifier,
            opening: url
        )
    }

    /// Restores the intended input target after Computa's native approval UI
    /// has taken focus. Raw keyboard events are otherwise delivered to Computa.
    @discardableResult
    public func activateApplication(
        processIdentifier: Int32
    ) async throws -> ActivatedApplication {
        try requirePermission()
        guard processIdentifier > 0 else {
            throw ComputerInputError.applicationProcessNotFound(
                processIdentifier: processIdentifier
            )
        }
        return try await runtime.activateApplication(processIdentifier: processIdentifier)
    }

    public func moveMouse(to point: ScreenPoint) throws {
        try requirePermission()
        try validate(point)
        try runtime.moveMouse(to: point)
    }

    public func click(at point: ScreenPoint) throws {
        try requirePermission()
        try validate(point)
        try runtime.click(at: point, count: 1, rightButton: false)
    }

    public func doubleClick(at point: ScreenPoint) throws {
        try requirePermission()
        try validate(point)
        try runtime.click(at: point, count: 2, rightButton: false)
    }

    public func rightClick(at point: ScreenPoint) throws {
        try requirePermission()
        try validate(point)
        try runtime.click(at: point, count: 1, rightButton: true)
    }

    /// Posts a continuous, pixel-unit scroll event. Positive `deltaY` scrolls
    /// up and positive `deltaX` scrolls left, matching CoreGraphics semantics.
    public func scrollBy(deltaX: Int32 = 0, deltaY: Int32) throws {
        try requirePermission()
        try runtime.scrollBy(deltaX: deltaX, deltaY: deltaY)
    }

    /// Moves the pointer to the intended scroll target before posting the
    /// continuous scroll event. This avoids scrolling Computa's approval UI.
    public func scroll(
        at point: ScreenPoint,
        deltaX: Int32 = 0,
        deltaY: Int32
    ) throws {
        try requirePermission()
        try validate(point)
        try runtime.moveMouse(to: point)
        try runtime.scrollBy(deltaX: deltaX, deltaY: deltaY)
    }

    public func drag(
        from start: ScreenPoint,
        to end: ScreenPoint,
        duration: Double = 0.25
    ) async throws {
        try requirePermission()
        try validate(start)
        try validate(end)
        guard duration.isFinite, (0 ... Self.maximumDragDuration).contains(duration) else {
            throw ComputerInputError.invalidDragDuration(duration)
        }
        try await runtime.drag(from: start, to: end, duration: duration)
    }

    public func pressKeyChord(_ chord: KeyboardChord) throws {
        try requirePermission()
        guard chord.keyCode <= 127 else {
            throw ComputerInputError.invalidKeyCode(chord.keyCode)
        }
        try runtime.pressKeyChord(chord)
    }

    public func enterText(_ text: String) throws {
        try requirePermission()
        try runtime.enterText(text)
    }

    private func validate(_ point: ScreenPoint) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw ComputerInputError.invalidPoint(point)
        }
    }

    private func requirePermission() throws {
        guard accessibilityCheck() else {
            throw AutomationError.permissionNotGranted(.accessibility)
        }
    }
}
