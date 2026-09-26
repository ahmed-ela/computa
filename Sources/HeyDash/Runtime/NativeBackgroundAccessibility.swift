import AutomationCore
import Foundation

/// Revoked synchronously by the runtime actor, including while a background
/// operation is waiting for MainActor. No lock spans AX work or an actor hop.
final class NativeBackgroundLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func revoke() { lock.withLock { valid = false } }
    func check() throws {
        try lock.withLock {
            guard valid else { throw CancellationError() }
        }
    }
}

/// A target-scoped AX lane. It never activates an application, raises a window,
/// posts global input, or converts semantic targets to guessed coordinates.
@MainActor
final class NativeBackgroundAccessibility {
    enum Failure: LocalizedError {
        case targetChanged
        case staleObservation
        case foregroundAction

        var errorDescription: String? {
            switch self {
            case .targetChanged: "The exact background application/window changed. Observe again; no fallback input was sent."
            case .staleObservation: "The background Accessibility observation is stale. Capture a fresh snapshot."
            case .foregroundAction: "AXRaise changes foreground window ordering and is not supported by the background lane. No action was sent."
            }
        }
    }

    struct Observation: Sendable {
        let snapshotID: UUID
        let text: String
    }

    private let backend: any NativeBackgroundAccessibilityBackend
    nonisolated let lifetime: NativeBackgroundLifetime
    private var snapshot: AccessibilityTreeSnapshot?
    private var scope: NativeAccessibilityActionScope?

    init(backend: any NativeBackgroundAccessibilityBackend, lifetime: NativeBackgroundLifetime = .init()) {
        self.backend = backend
        self.lifetime = lifetime
    }

    convenience init(application: ActivatedApplication, windowIdentity: ApplicationWindowIdentity? = nil,
                     lifetime: NativeBackgroundLifetime) throws {
        let identity = try windowIdentity ?? ApplicationWindowReader().selectedWindowObservation(
            processIdentifier: application.processIdentifier, expectedBundleIdentifier: application.bundleIdentifier
        ).identity
        guard identity.processIdentifier == application.processIdentifier,
              identity.bundleIdentifier == application.bundleIdentifier,
              try identity.isStillSelected() else { throw Failure.targetChanged }
        self.init(backend: try SystemBackgroundAccessibilityBackend(
            application: application, identity: identity
        ), lifetime: lifetime)
    }

    func read(query: String? = nil, outputCharacterLimit: Int? = nil) throws -> Observation {
        invalidate()
        try requireTarget()
        let limits = try AccessibilityTreeLimits(
            maxDepth: AccessibilityTreeLimits.agentDefault.maxDepth,
            maxElements: query == nil ? 240 : 1_000,
            maxChildrenPerElement: AccessibilityTreeLimits.agentDefault.maxChildrenPerElement,
            maxActionsPerElement: 12,
            maxTextLength: ComputerToolContract.maximumSemanticTextLength
        )
        let captured = try backend.snapshot(limits: limits)
        try requireTarget()
        let formatted = AccessibilitySnapshotTextFormatter(
            elementLimit: limits.maxElements, fieldCharacterLimit: 72, actionLimit: 6,
            outputCharacterLimit: outputCharacterLimit ?? (query == nil ? 3_000 : 1_000),
            prioritizesRelevantElements: true, preferredText: query,
            usesCompactElementLines: true
        ).formatObservation(captured)
        snapshot = captured
        scope = NativeAccessibilityActionScope(observation: formatted)
        return Observation(snapshotID: captured.id, text:
            "NATIVE_AX scope=bound_window activation=none. Semantic AX/set_value only; "
                + "global key/pointer tools still require a fresh foreground observation. "
                + "Dispatch is not outcome verification.\n" + formatted.text)
    }

    func elementName(snapshotID: UUID, index: Int) throws -> String {
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        let element = current.element(at: index)
        return element?.title ?? element?.elementDescription ?? element?.role ?? "element \(index)"
    }

    func perform(snapshotID: UUID, index: Int, action: SemanticAXAction) throws {
        guard action != .raise else { throw Failure.foregroundAction }
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        invalidate()
        try requireTarget()
        try backend.perform(action: action, index: index, snapshot: current) { try self.requireTarget() }
    }

    func setValue(snapshotID: UUID, index: Int, text: String) throws {
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        invalidate()
        try requireTarget()
        try backend.setValue(text: text, index: index, snapshot: current) { try self.requireTarget() }
    }

    func invalidate() { snapshot = nil; scope = nil }

    private func validatedSnapshot(snapshotID: UUID, index: Int) throws -> AccessibilityTreeSnapshot {
        try requireTarget()
        guard let snapshot, snapshot.id == snapshotID, let scope else {
            throw Failure.staleObservation
        }
        try scope.requireExposedElement(index, snapshotID: snapshotID)
        return snapshot
    }

    private func requireTarget() throws {
        try Task.checkCancellation()
        try lifetime.check()
        guard try backend.isStillSelected() else { throw Failure.targetChanged }
        // AX identity reads can block while the runtime actor revokes this
        // capability. Check again after those reads, immediately before use.
        try Task.checkCancellation()
        try lifetime.check()
    }
}

@MainActor
protocol NativeBackgroundAccessibilityBackend {
    func isStillSelected() throws -> Bool
    func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot
    func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws
    func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws
}

@MainActor
private final class SystemBackgroundAccessibilityBackend: NativeBackgroundAccessibilityBackend {
    private let identity: ApplicationWindowIdentity
    private let session: AccessibilitySession

    init(application: ActivatedApplication, identity: ApplicationWindowIdentity) throws {
        self.identity = identity
        session = try AccessibilitySession(target: AccessibilityApplicationTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        ), windowIdentity: identity)
    }

    func isStillSelected() throws -> Bool { try identity.isStillSelected() }
    func snapshot(limits: AccessibilityTreeLimits) throws -> AccessibilityTreeSnapshot {
        try session.snapshot(limits: limits)
    }
    func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
        try session.refreshAndPerform(action, at: index, in: snapshot, beforeDispatch: beforeDispatch)
    }
    func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
        try session.refreshAndSetValue(.text(text), at: index, in: snapshot, beforeDispatch: beforeDispatch)
    }
}
