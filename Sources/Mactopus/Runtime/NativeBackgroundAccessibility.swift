import AppKit
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
    struct MutationFailure: Error {
        let underlying: any Error
        let dispatchBegan: Bool
    }
    enum Failure: LocalizedError, Equatable {
        case targetChanged
        case staleObservation
        case foregroundAction
        case focusChangedDuringAction

        var errorDescription: String? {
            switch self {
            case .targetChanged: "The exact background application/window changed. Observe again; no fallback input was sent."
            case .staleObservation: "The background Accessibility observation is stale. Capture a fresh snapshot."
            case .foregroundAction: "AXRaise changes foreground window ordering and is not supported by the background lane. No action was sent."
            case .focusChangedDuringAction:
                "Foreground changed during the background action. The action may have been dispatched; its effects are uncertain. "
                    + "The app or the user may have caused this change. This background binding was revoked; no focus was restored. "
                    + "Do not repeat the action. Observe the current state before deciding how to continue."
            }
        }
    }

    struct Observation: Sendable {
        let snapshotID: UUID
        let text: String
    }

    private let backend: any NativeBackgroundAccessibilityBackend
    private let foregroundProcessIdentifier: () -> Int32?
    nonisolated let lifetime: NativeBackgroundLifetime
    private var snapshot: AccessibilityTreeSnapshot?
    private var snapshotIsLive = false
    private var scope: NativeAccessibilityActionScope?

    /// Dependency-injected backend/probe for deterministic tests. The system
    /// initializer below always supplies the live foreground process probe.
    init(backend: any NativeBackgroundAccessibilityBackend, lifetime: NativeBackgroundLifetime = .init(),
         foregroundProcessIdentifier: @escaping () -> Int32? = { nil }) {
        self.backend = backend
        self.lifetime = lifetime
        self.foregroundProcessIdentifier = foregroundProcessIdentifier
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
        ), lifetime: lifetime, foregroundProcessIdentifier: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        })
    }

    func read(query: String? = nil, outputCharacterLimit: Int? = nil) throws -> Observation {
        try read(read: SemanticReadRequest(query: query), outputCharacterLimit: outputCharacterLimit)
    }

    func read(read: SemanticReadRequest, outputCharacterLimit: Int? = nil) throws -> Observation {
        do {
            // Clear action scope before any potentially blocking OS read. The
            // backend retains its own bounded, window-scoped read frontier.
            snapshot = nil; snapshotIsLive = false; scope = nil
            try requireTarget()
            let result = try backend.semanticRead(read, outputCharacterLimit: outputCharacterLimit ?? 6_000)
            try requireTarget()
            snapshot = result.snapshot
            snapshotIsLive = read.cursor == nil && read.snapshotID == nil
            scope = NativeAccessibilityActionScope(observation: result.observation)
            return Observation(snapshotID: result.snapshot.id, text:
                "NATIVE_AX scope=bound_window activation=none. Semantic AX/set_value only; "
                    + "global key/pointer tools are unavailable in this background binding. "
                    + "Read-only images grant no input authority. "
                    + "Dispatch is not outcome verification.\n" + result.observation.text)
        } catch {
            invalidate()
            throw error
        }
    }

    func elementName(snapshotID: UUID, index: Int) throws -> String {
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        let element = current.element(at: index)
        return element?.title ?? element?.elementDescription ?? element?.role ?? "element \(index)"
    }

    /// Properties from the exact retained model-visible observation. This does
    /// not reread the UI or promote a successful AX dispatch into outcome
    /// evidence: callers must first obtain a fresh post-action snapshot.
    /// Unexposed elements and absent values are never fabricated or surfaced.
    func observedProperties(snapshotID: UUID) throws -> [String: String] {
        try requireTarget()
        guard let snapshot, snapshot.id == snapshotID, let scope else {
            throw Failure.staleObservation
        }
        let exposed = Set(snapshot.elements.compactMap { element in
            (try? scope.requireExposedElement(element.index, snapshotID: snapshotID)) != nil ? element.index : nil
        })
        let properties = NativeObservationEvidence.properties(snapshot: snapshot, exposedIndices: exposed)
        try requireTarget()
        return properties
    }

    func currentObservedProperties() throws -> (id: UUID, properties: [String: String], isLive: Bool)? {
        try requireTarget()
        guard let snapshot, scope != nil else { return nil }
        return (snapshot.id, try observedProperties(snapshotID: snapshot.id), snapshotIsLive)
    }

    /// A host-only bounded source observation, independent of the much smaller
    /// model-facing page. It grants no authority to act on hidden elements.
    func verificationObservation(snapshotID: UUID? = nil) throws -> NativeActionVerification.Observation {
        try requireTarget()
        guard let snapshot, snapshotID == nil || snapshot.id == snapshotID, let scope else {
            throw Failure.staleObservation
        }
        let exposed = Set(snapshot.elements.compactMap { element in
            (try? scope.requireExposedElement(element.index, snapshotID: snapshot.id)) != nil ? element.index : nil
        })
        return .init(snapshot: snapshot, exposedIndices: exposed, isLive: snapshotIsLive)
    }

    func validateTarget() throws { try requireTarget() }

    /// Runtime-owned settling reads use a full bounded tree, not the first
    /// 1,600 output characters. The visible result remains compact and actions
    /// are still limited to the elements actually presented to the model.
    func readForVerification(preferredText: String? = nil) throws -> Observation {
        do {
            snapshot = nil; snapshotIsLive = false; scope = nil
            try requireTarget()
            let captured = try backend.snapshot(limits: AccessibilityTreeLimits(
                maxDepth: 24, maxElements: 2_000, maxChildrenPerElement: 256,
                maxActionsPerElement: 32, maxTextLength: 1_024))
            try requireTarget()
            let formatted = AccessibilitySnapshotTextFormatter(elementLimit: 160,
                fieldCharacterLimit: 512, outputCharacterLimit: 4_000,
                prioritizesRelevantElements: true, preferredText: preferredText,
                usesCompactElementLines: true, allowsRaise: false).formatObservation(captured)
            snapshot = captured
            snapshotIsLive = true
            scope = NativeAccessibilityActionScope(observation: formatted)
            return Observation(snapshotID: captured.id, text:
                "NATIVE_AX scope=bound_window activation=none verification_read=true. "
                + "Fresh references only; hidden elements are not action targets. This read never dispatches input.\n"
                + formatted.text)
        } catch { invalidate(); throw error }
    }

    /// The action target is fixed by the pre-action plan, never by an index
    /// carried over into a new tree. Revalidate after approval, and instrument
    /// the final AX boundary so a validation failure is not uncertain input.
    func performVerified(plan: NativeActionVerification.Plan, action: SemanticAXAction?, text: String?) throws {
        var dispatchBegan = false
        do {
            guard !plan.alreadySatisfied else { throw NativeActionVerification.Failure.invalidPlan }
            guard (action != nil) != (text != nil), action != .raise else { throw Failure.foregroundAction }
            _ = try readForVerification(preferredText: plan.presentationQuery)
            let current = try verificationObservation()
            try plan.revalidateBaseline(observation: current)
            let index = try plan.actionElementIndex(in: current)
            snapshot = nil; snapshotIsLive = false; scope = nil
            defer { backend.invalidateObservation() }
            try requireTarget()
            try withoutForegroundChange { checkBoundary in
                if let action {
                    try backend.perform(action: action, index: index, snapshot: current.snapshot, beforeDispatch: {
                        try checkBoundary()
                        dispatchBegan = true
                    })
                } else if let text {
                    try backend.setValue(text: text, index: index, snapshot: current.snapshot, beforeDispatch: {
                        try checkBoundary()
                        dispatchBegan = true
                    })
                }
            }
        } catch { throw MutationFailure(underlying: error, dispatchBegan: dispatchBegan) }
    }

    func canonicalEvidenceProperty(snapshotID: UUID, index: Int, field: String) throws -> String {
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        let result = try NativeObservationEvidence.canonicalProperty(snapshot: current, exposedIndices: [index],
            index: index, field: field)
        try requireTarget()
        return result
    }

    func perform(snapshotID: UUID, index: Int, action: SemanticAXAction,
                 beforeDispatch: () throws -> Void = {}) throws {
        guard action != .raise else { throw Failure.foregroundAction }
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        snapshot = nil; snapshotIsLive = false; scope = nil
        defer { backend.invalidateObservation() }
        try requireTarget()
        try withoutForegroundChange { checkBoundary in
            try backend.perform(action: action, index: index, snapshot: current, beforeDispatch: {
                try checkBoundary()
                try beforeDispatch()
            })
        }
    }

    func setValue(snapshotID: UUID, index: Int, text: String,
                  beforeDispatch: () throws -> Void = {}) throws {
        let current = try validatedSnapshot(snapshotID: snapshotID, index: index)
        snapshot = nil; snapshotIsLive = false; scope = nil
        defer { backend.invalidateObservation() }
        try requireTarget()
        try withoutForegroundChange { checkBoundary in
            try backend.setValue(text: text, index: index, snapshot: current, beforeDispatch: {
                try checkBoundary()
                try beforeDispatch()
            })
        }
    }

    func invalidate() { snapshot = nil; snapshotIsLive = false; scope = nil; backend.invalidateObservation() }

    /// AX is target-scoped, but an application can still activate itself while
    /// handling an action. A changed PID is interference evidence, not proof of
    /// who caused it: a human can also switch apps during the synchronous AX
    /// call. Stop conservatively without replaying input or restoring focus.
    /// This boundary probe cannot detect a change away and back between reads.
    private func withoutForegroundChange(
        _ dispatch: (_ beforeDispatch: () throws -> Void) throws -> Void
    ) throws {
        let original = foregroundProcessIdentifier()
        do {
            try dispatch {
                try self.requireTarget()
                try self.requireUnchangedForeground(original)
            }
        } catch {
            // An AX call can have effects before throwing. Check this path too
            // and retain uncertainty rather than treating it as safe to retry.
            try requireUnchangedForeground(original)
            throw error
        }
        try requireUnchangedForeground(original)
    }

    private func requireUnchangedForeground(_ original: Int32?) throws {
        guard foregroundProcessIdentifier() == original else {
            lifetime.revoke()
            invalidate()
            throw Failure.focusChangedDuringAction
        }
    }

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
    func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult
    func invalidateObservation()
    func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws
    func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws
}

extension NativeBackgroundAccessibilityBackend {
    func invalidateObservation() {}
    // Preserve lightweight backend/mocks. A backend cannot silently accept a
    // cursor or pretend a query can discover nodes beyond its captured source.
    func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult {
        guard request.cursor == nil, request.snapshotID == nil, request.elementIndex == nil,
              request.view == .all else { throw SemanticReadError.unsupportedProgressiveRead }
        let captured = try snapshot(limits: .agentDefault)
        let observation = AccessibilitySnapshotTextFormatter(elementLimit: 240, fieldCharacterLimit: 256,
            outputCharacterLimit: outputCharacterLimit, prioritizesRelevantElements: true,
            preferredText: request.query, usesCompactElementLines: true, allowsRaise: false).formatObservation(captured)
        return AccessibilitySemanticReadResult(snapshot: captured, observation: observation)
    }
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
    func semanticRead(_ request: SemanticReadRequest, outputCharacterLimit: Int) throws -> AccessibilitySemanticReadResult {
        try session.read(read: request, outputCharacterLimit: outputCharacterLimit, allowsRaise: false)
    }
    func invalidateObservation() { session.invalidateSnapshot() }
    func perform(action: SemanticAXAction, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
        try session.refreshAndPerform(action, at: index, in: snapshot, beforeDispatch: beforeDispatch)
    }
    func setValue(text: String, index: Int, snapshot: AccessibilityTreeSnapshot, beforeDispatch: () throws -> Void) throws {
        try session.refreshAndSetValue(.text(text), at: index, in: snapshot, beforeDispatch: beforeDispatch)
    }
}
