import AutomationCore
import CoreGraphics
import Foundation

/// Read-only pixels from one retained application/window. This type deliberately
/// has no display capture, activation, input, or image-to-screen mapper API.
@MainActor
final class NativeBackgroundCapture {
    enum Failure: Error, Equatable, LocalizedError {
        case targetChanged
        case ambiguousWindow
        case windowChanged

        var errorDescription: String? {
            switch self {
            case .targetChanged:
                "The bound background application/window changed. No image was published."
            case .ambiguousWindow:
                "The bound window could not be mapped uniquely to a capturable window. No image was published."
            case .windowChanged:
                "The background window changed during capture. Observe again. No input was sent."
            }
        }
    }

    struct Observation: Sendable {
        let observationID: UUID
        let image: CGImage
        let capturedAt: Date
        let text: String
    }

    private let application: ActivatedApplication
    private let lifetime: NativeBackgroundLifetime
    private let backend: any NativeBackgroundCaptureBackend

    init(
        application: ActivatedApplication,
        identity: ApplicationWindowIdentity,
        lifetime: NativeBackgroundLifetime
    ) {
        self.application = application
        self.lifetime = lifetime
        backend = SystemBackgroundCaptureBackend(application: application, identity: identity)
    }

    init(
        application: ActivatedApplication,
        lifetime: NativeBackgroundLifetime,
        backend: any NativeBackgroundCaptureBackend
    ) {
        self.application = application
        self.lifetime = lifetime
        self.backend = backend
    }

    func capture() async throws -> Observation {
        let selected = try currentSelection()
        let windows = try await backend.windows()
        try requireUnchangedSelection(selected)
        guard let window = ComputerV2TargetContract.matchingWindow(for: selected, in: windows) else {
            throw Failure.ambiguousWindow
        }

        let image = try await backend.capture(windowID: window.windowID)
        let capturedAt = Date()
        try requireUnchangedSelection(selected)
        let windowsAfter = try await backend.windows()
        try requireUnchangedSelection(selected)
        // Re-resolve the unique correspondence as well as the original SC ID:
        // a new overlapping candidate is ambiguity, not permission to guess.
        guard let matched = ComputerV2TargetContract.matchingWindow(for: selected, in: windowsAfter),
              matched.windowID == window.windowID,
              ComputerV2TargetContract.isSameWindow(matched, as: window),
              matched.frame == window.frame else {
            throw Failure.windowChanged
        }
        try requireAlive()
        let id = UUID()
        return Observation(
            observationID: id, image: image, capturedAt: capturedAt,
            text: "IMAGE_OBSERVATION observation_id=\(id.uuidString) "
                + "width=\(image.width) height=\(image.height) "
                + "captured_at=\(capturedAt.ISO8601Format()) "
                + "scope=bound_window activation=none input_authority=none. "
                + "Read-only background image; this observation does not authorize pointer or keyboard input. "
                + "Pixels describe the capture instant, not a guarantee that the remote or local UI is unchanged."
        )
    }

    private func currentSelection() throws -> FocusedWindowInfo {
        try requireAlive()
        let selected = try backend.selectedWindow()
        try requireAlive()
        guard selected.processIdentifier == application.processIdentifier,
              selected.bundleIdentifier == application.bundleIdentifier,
              let frame = selected.frame,
              frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              (frame.x + frame.width).isFinite, (frame.y + frame.height).isFinite else {
            throw Failure.targetChanged
        }
        return selected
    }

    private func requireUnchangedSelection(_ original: FocusedWindowInfo) throws {
        let current = try currentSelection()
        guard current.frame == original.frame else { throw Failure.windowChanged }
    }

    private func requireAlive() throws {
        try Task.checkCancellation()
        try lifetime.check()
    }
}

@MainActor
protocol NativeBackgroundCaptureBackend {
    /// Must verify the originally retained AX window, including app launch
    /// generation. Returning a different currently selected window is invalid.
    func selectedWindow() throws -> FocusedWindowInfo
    func windows() async throws -> [CapturableWindowInfo]
    func capture(windowID: UInt32) async throws -> CGImage
}

@MainActor
private final class SystemBackgroundCaptureBackend: NativeBackgroundCaptureBackend {
    private let application: ActivatedApplication
    private let identity: ApplicationWindowIdentity
    private let reader = ApplicationWindowReader()
    private let screenshotter = WindowScreenshotter()

    init(application: ActivatedApplication, identity: ApplicationWindowIdentity) {
        self.application = application
        self.identity = identity
    }

    func selectedWindow() throws -> FocusedWindowInfo {
        guard identity.processIdentifier == application.processIdentifier,
              identity.bundleIdentifier == application.bundleIdentifier,
              try identity.isStillSelected() else { throw NativeBackgroundCapture.Failure.targetChanged }
        let observed = try reader.selectedWindowObservation(
            processIdentifier: application.processIdentifier,
            expectedBundleIdentifier: application.bundleIdentifier
        )
        guard identity.isSameWindow(as: observed.identity),
              try identity.isStillSelected() else { throw NativeBackgroundCapture.Failure.targetChanged }
        return observed.info
    }

    func windows() async throws -> [CapturableWindowInfo] {
        try await screenshotter.availableWindows()
    }

    func capture(windowID: UInt32) async throws -> CGImage {
        try await screenshotter.captureWindow(windowID: windowID, scaleFactor: 1, showsCursor: false)
    }
}
