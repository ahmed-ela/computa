import Foundation
import XCTest
@testable import AutomationCore

@MainActor
private final class RecordingComputerInputRuntime: ComputerInputRuntime {
    enum Invocation: Equatable {
        case launch(bundleIdentifier: String, url: URL?)
        case activate(processIdentifier: Int32)
        case move(ScreenPoint)
        case click(point: ScreenPoint, count: Int, rightButton: Bool)
        case scroll(deltaX: Int32, deltaY: Int32)
        case drag(start: ScreenPoint, end: ScreenPoint, duration: Double)
        case chord(KeyboardChord)
        case text(String)
    }

    var invocations = [Invocation]()
    var activatedApplication = ActivatedApplication(
        processIdentifier: 42,
        bundleIdentifier: "com.example.default",
        localizedName: "Default"
    )

    func launchOrActivateApplication(
        bundleIdentifier: String,
        opening url: URL?
    ) async throws -> ActivatedApplication {
        invocations.append(.launch(bundleIdentifier: bundleIdentifier, url: url))
        return activatedApplication
    }

    func activateApplication(processIdentifier: Int32) async throws -> ActivatedApplication {
        invocations.append(.activate(processIdentifier: processIdentifier))
        return activatedApplication
    }

    func moveMouse(to point: ScreenPoint) throws {
        invocations.append(.move(point))
    }

    func click(at point: ScreenPoint, count: Int, rightButton: Bool) throws {
        invocations.append(.click(point: point, count: count, rightButton: rightButton))
    }

    func scrollBy(deltaX: Int32, deltaY: Int32) throws {
        invocations.append(.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    func drag(from start: ScreenPoint, to end: ScreenPoint, duration: Double) async throws {
        invocations.append(.drag(start: start, end: end, duration: duration))
    }

    func pressKeyChord(_ chord: KeyboardChord) throws {
        invocations.append(.chord(chord))
    }

    func enterText(_ text: String) throws {
        invocations.append(.text(text))
    }
}

final class ComputerInputControllerTests: XCTestCase {
    @MainActor
    func testEveryOperationFailsClosedBeforeRuntimeUse() async {
        var permissionChecks = 0
        let runtime = RecordingComputerInputRuntime()
        let controller = ComputerInputController(
            runtime: runtime,
            accessibilityCheck: {
                permissionChecks += 1
                return false
            }
        )
        let point = ScreenPoint(x: 10, y: 20)

        do {
            _ = try await controller.launchOrActivateApplication(bundleIdentifier: "com.apple.TextEdit")
            XCTFail("Expected Accessibility permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        do {
            _ = try await controller.activateApplication(processIdentifier: 42)
            XCTFail("Expected Accessibility permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        assertAccessibilityFailure { try controller.moveMouse(to: point) }
        assertAccessibilityFailure { try controller.click(at: point) }
        assertAccessibilityFailure { try controller.doubleClick(at: point) }
        assertAccessibilityFailure { try controller.rightClick(at: point) }
        assertAccessibilityFailure { try controller.scrollBy(deltaX: 3, deltaY: -7) }
        assertAccessibilityFailure { try controller.scroll(at: point, deltaX: 3, deltaY: -7) }
        do {
            try await controller.drag(from: point, to: point)
            XCTFail("Expected Accessibility permission failure")
        } catch {
            XCTAssertEqual(error as? AutomationError, .permissionNotGranted(.accessibility))
        }
        assertAccessibilityFailure {
            try controller.pressKeyChord(
                KeyboardChord(keyCode: 37, modifiers: [.command])
            )
        }
        assertAccessibilityFailure { try controller.enterText("hello") }

        XCTAssertEqual(permissionChecks, 11)
        XCTAssertEqual(runtime.invocations, [])
    }

    @MainActor
    func testRoutesValidatedOperationsToInjectedRuntimeExactly() async throws {
        let runtime = RecordingComputerInputRuntime()
        runtime.activatedApplication = ActivatedApplication(
            processIdentifier: 123,
            bundleIdentifier: "com.google.Chrome",
            localizedName: "Google Chrome"
        )
        let controller = ComputerInputController(runtime: runtime, accessibilityCheck: { true })
        let start = ScreenPoint(x: -30.5, y: 40.25)
        let end = ScreenPoint(x: 800, y: 600)
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        let chord = KeyboardChord(keyCode: 37, modifiers: [.command, .shift])

        let application = try await controller.launchOrActivateApplication(
            bundleIdentifier: "com.google.Chrome",
            opening: url
        )
        let reactivated = try await controller.activateApplication(processIdentifier: 123)
        try controller.moveMouse(to: start)
        try controller.click(at: start)
        try controller.doubleClick(at: end)
        try controller.rightClick(at: end)
        try controller.scroll(at: start, deltaX: -12, deltaY: 240)
        try await controller.drag(from: start, to: end, duration: 0.75)
        try controller.pressKeyChord(chord)
        try controller.enterText("Hello, 世界 👋")

        XCTAssertEqual(application, runtime.activatedApplication)
        XCTAssertEqual(reactivated, runtime.activatedApplication)
        XCTAssertEqual(
            runtime.invocations,
            [
                .launch(bundleIdentifier: "com.google.Chrome", url: url),
                .activate(processIdentifier: 123),
                .move(start),
                .click(point: start, count: 1, rightButton: false),
                .click(point: end, count: 2, rightButton: false),
                .click(point: end, count: 1, rightButton: true),
                .move(start),
                .scroll(deltaX: -12, deltaY: 240),
                .drag(start: start, end: end, duration: 0.75),
                .chord(chord),
                .text("Hello, 世界 👋"),
            ]
        )
    }

    @MainActor
    func testRejectsInvalidArgumentsAfterPermissionCheckAndBeforeRuntime() async {
        var permissionChecks = 0
        let runtime = RecordingComputerInputRuntime()
        let controller = ComputerInputController(
            runtime: runtime,
            accessibilityCheck: {
                permissionChecks += 1
                return true
            }
        )

        do {
            _ = try await controller.launchOrActivateApplication(bundleIdentifier: "  \n")
            XCTFail("Expected invalid bundle identifier")
        } catch {
            XCTAssertEqual(error as? ComputerInputError, .invalidBundleIdentifier)
        }

        let invalidPoint = ScreenPoint(x: .infinity, y: 1)
        XCTAssertThrowsError(try controller.click(at: invalidPoint)) { error in
            XCTAssertEqual(error as? ComputerInputError, .invalidPoint(invalidPoint))
        }

        do {
            try await controller.drag(
                from: ScreenPoint(x: 0, y: 0),
                to: ScreenPoint(x: 1, y: 1),
                duration: 30.01
            )
            XCTFail("Expected invalid drag duration")
        } catch {
            XCTAssertEqual(error as? ComputerInputError, .invalidDragDuration(30.01))
        }

        XCTAssertThrowsError(
            try controller.pressKeyChord(KeyboardChord(keyCode: 128))
        ) { error in
            XCTAssertEqual(error as? ComputerInputError, .invalidKeyCode(128))
        }

        XCTAssertEqual(permissionChecks, 4)
        XCTAssertEqual(runtime.invocations, [])
    }

    func testUnicodeChunksNeverSplitASurrogatePairAndRoundTrip() {
        let input = String(repeating: "a", count: 19) + "👋" + "b"
        let chunks = UnicodeInputChunks.make(from: input, maximumUTF16Count: 20)

        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), input)
    }

    func testEmptyUnicodeInputProducesNoSyntheticKeyEvents() {
        XCTAssertEqual(UnicodeInputChunks.make(from: "", maximumUTF16Count: 20), [])
    }

    private func assertAccessibilityFailure(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? AutomationError,
                .permissionNotGranted(.accessibility),
                file: file,
                line: line
            )
        }
    }
}
