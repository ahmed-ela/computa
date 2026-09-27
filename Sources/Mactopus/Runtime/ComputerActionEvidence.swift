import CryptoKit
import Foundation

/// Runtime receipts for one turn. Tool transport success, dispatched input and
/// a verified rendered property are deliberately different facts. This ledger
/// never interprets assistant prose or treats a completed model turn as proof.
struct ComputerActionEvidence: Codable, Equatable, Sendable {
    enum DispatchState: String, Codable, Sendable {
        case notDispatched = "not_dispatched"
        case dispatched
        case unknown
    }

    /// Separate from click/key dispatch: activation can happen before an input
    /// precondition fails. Missing means older/uninstrumented evidence.
    enum ForegroundEffect: String, Codable, Sendable {
        case activationRequested = "activation_requested"
        case activationCompleted = "activation_completed"
        case changedDuringAX = "focus_changed_during_ax_attribution_unknown"
    }

    /// Assigned only by a known host-side validation boundary, never inferred
    /// merely from missing dispatch instrumentation or a model's error prose.
    enum PreflightRejection: String, Codable, Sendable {
        case invalidArguments
        case bindingRequired
        case freshObservationRequired
        case pendingAction
    }

    enum PreflightCorrection: Sendable {
        case validatedArguments
        case freshBoundObservation(observationID: String, targetID: String)
    }

    struct PreflightCorrectionReceipt: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case validatedArguments, freshBoundObservation }
        let successorOperationID: String
        let kind: Kind
        let observationID: String?
        let observationTargetID: String?
        let observationSequence: UInt64?
    }

    struct Verification: Codable, Equatable, Sendable {
        let operationID: String
        let observationID: String
        let property: String
        let expectedValue: String
    }

    /// The condition held before any input. This is intentionally not a
    /// Verification: it proves no action happened and no changed effect.
    struct AlreadySatisfiedReceipt: Codable, Equatable, Sendable {
        let operationID: String
        let observationID: String
        let property: String
        let expectedValue: String
        let observationSequence: UInt64
    }

    struct PendingActionRejectionReceipt: Codable, Equatable, Sendable {
        enum Resolution: String, Codable, Sendable { case verified, alreadySatisfied }
        let pendingOperationID: String
        let rejectionSequence: UInt64
        var resolution: Resolution?
        var resolutionObservationID: String?
    }

    /// A read-only obligation, separate from the model transcript and input
    /// retry budgets. A compacted model response cannot reset these attempts.
    struct PlannedVerificationProgress: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case pending
            case observing
            case observationUnavailable = "observation_unavailable"
            case postconditionMismatch = "postcondition_mismatch"
            case verified
            case alreadySatisfied = "already_satisfied_not_dispatched"
        }

        var attempts = 0
        var attemptAfterSequence: UInt64?
        var outcome: Outcome = .pending
        var remainingAttempts: Int { max(0, ComputerActionEvidence.maximumPlannedVerificationAttempts - attempts) }
    }

    struct Operation: Codable, Equatable, Sendable {
        let id: String
        let tool: String
        var targetID: String
        let recoveryKey: String?
        let requiresVerification: Bool
        /// Hashes avoid retaining a second copy of private pre-action content.
        let baselineProperties: [String: String]?
        var dispatch: DispatchState = .notDispatched
        var foregroundEffect: ForegroundEffect?
        var failureCode: String?
        var failureMessage: String?
        var observationAfter: UInt64
        var verification: Verification?
        var recoveredBy: String?
        var preflightRejection: PreflightRejection?
        /// Host-classified schema rejection occurred before any application
        /// was bound. Optional for compatibility with earlier saved receipts.
        var preflightTargetWasUnbound: Bool?
        var preflightCorrection: PreflightCorrectionReceipt?
        /// Armed from a fresh observation before dispatch. It owns its bounded
        /// baseline independently of the progressive 128-property cache above.
        var verificationPlan: BrowserActionVerification.Plan?
        var nativeVerificationPlan: NativeActionVerification.Plan?
        var plannedVerificationProgress: PlannedVerificationProgress?
        var alreadySatisfied: AlreadySatisfiedReceipt?
        var pendingActionRejection: PendingActionRejectionReceipt?

        var hasVerificationPlan: Bool { verificationPlan != nil || nativeVerificationPlan != nil }

        var isResolved: Bool {
            recoveredBy != nil || verification != nil || preflightCorrection != nil || alreadySatisfied != nil
                || pendingActionRejection?.resolution != nil
                || (!requiresVerification && dispatch == .dispatched && failureCode == nil)
        }
    }

    private struct Observation: Codable, Equatable, Sendable {
        let id: String
        let targetID: String
        let sequence: UInt64
        let properties: [String: String]
        let isLive: Bool
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidIdentity
        case capacityExceeded
        case duplicateOperation
        case missingOperation
        case invalidTransition
        case missingObservation
        case staleObservation
        case wrongTarget
        case propertyMismatch
        case unchangedProperty
        case missingBaseline
        case invalidRecovery
        case invalidCheckpoint
        case missingVerificationPlan
        case plannedVerificationRequired
        case verificationAttemptsExhausted

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: "Action evidence requires a bounded nonempty identity."
            case .capacityExceeded: "Action evidence capacity was reached; the outcome remains unverified."
            case .duplicateOperation: "This operation already has an evidence receipt."
            case .missingOperation: "The operation has no runtime evidence receipt."
            case .invalidTransition: "This action receipt cannot be changed after resolution."
            case .missingObservation: "The referenced observation is not retained by this turn."
            case .staleObservation: "Verification requires a fresh observation after the action."
            case .wrongTarget: "The observation belongs to another target."
            case .propertyMismatch: "The expected property was not observed; the outcome remains unverified."
            case .unchangedProperty: "That property was already present before the action; it does not verify a changed outcome."
            case .missingBaseline: "The action has no pre-action observation for comparison."
            case .invalidRecovery: "Only a verified later execution of the same operation on the same target can resolve its failure."
            case .invalidCheckpoint: "The saved action evidence is invalid."
            case .missingVerificationPlan: "This operation has no pre-dispatch verification plan."
            case .plannedVerificationRequired: "This operation has an armed verification plan; later arguments cannot replace its expected outcome."
            case .verificationAttemptsExhausted: "Read-only outcome verification exhausted its bounded attempts. The action must not be repeated."
            }
        }
    }

    static let maximumOperations = 64
    static let maximumObservations = 8
    static let maximumPlannedVerificationAttempts = 3
    static let maximumCheckpointBytes = 1024 * 1024
    private static let maximumPropertyBytes = 32 * 1024
    private static let maximumProperties = 128

    let turnID: String
    private(set) var operations: [Operation] = []
    private var observations: [Observation] = []
    private var sequence: UInt64 = 0

    init(turnID: String) { self.turnID = turnID }

    mutating func begin(operationID: String, tool: String, targetID: String,
                        recoveryKey: String? = nil, requiresVerification: Bool = true,
                        baselineProperties: [String: String]? = nil) throws {
        try Self.identity(turnID)
        for value in [operationID, tool, targetID] { try Self.identity(value) }
        if let recoveryKey { try Self.identity(recoveryKey) }
        guard !operations.contains(where: { $0.id == operationID }) else { throw Failure.duplicateOperation }
        if operations.count == Self.maximumOperations {
            let referenced = Set(operations.compactMap(\.recoveredBy)
                + operations.compactMap { $0.preflightCorrection?.successorOperationID }
                + operations.compactMap { $0.pendingActionRejection?.pendingOperationID })
            guard let removable = operations.firstIndex(where: { $0.isResolved && !referenced.contains($0.id) }) else {
                throw Failure.capacityExceeded
            }
            operations.remove(at: removable)
        }
        let baseline = baselineProperties
            ?? observations.last(where: { $0.targetID == targetID && $0.isLive })?.properties
        let fingerprints = baseline.map { properties in
            Dictionary<String, String>(uniqueKeysWithValues: properties.keys.sorted().prefix(Self.maximumProperties).compactMap { key in
                guard !key.isEmpty, key.utf8.count <= 256, let value = properties[key] else { return nil }
                return (key, Self.fingerprint(value))
            })
        }
        operations.append(Operation(id: operationID, tool: tool, targetID: targetID,
                                    recoveryKey: recoveryKey, requiresVerification: requiresVerification,
                                    baselineProperties: fingerprints,
                                    observationAfter: try nextSequence()))
    }

    /// Establish intent while input is still known not to have been sent.
    /// Re-arming after seeing a result would turn unrelated page changes into
    /// apparent proof, so even a second identical plan is rejected.
    mutating func armVerification(operationID: String, plan: BrowserActionVerification.Plan) throws {
        let index = try unresolvedIndex(operationID)
        let operation = operations[index]
        guard operation.requiresVerification,
              ["computer_v2_ax", "computer_v2_set_text"].contains(operation.tool),
              operation.dispatch == .notDispatched, operation.foregroundEffect == nil,
              operation.failureCode == nil, operation.preflightRejection == nil,
              !operation.hasVerificationPlan else { throw Failure.invalidTransition }
        try plan.validate()
        guard plan.scope.evidenceTargetID == operation.targetID else { throw Failure.wrongTarget }
        operations[index].verificationPlan = plan
        operations[index].plannedVerificationProgress = PlannedVerificationProgress()
    }

    mutating func armNativeVerification(operationID: String, plan: NativeActionVerification.Plan) throws {
        let index = try unresolvedIndex(operationID)
        let operation = operations[index]
        guard operation.requiresVerification,
              ["computer_v2_ax", "computer_v2_set_text"].contains(operation.tool),
              operation.dispatch == .notDispatched, operation.foregroundEffect == nil,
              operation.failureCode == nil, operation.preflightRejection == nil,
              !operation.hasVerificationPlan else { throw Failure.invalidTransition }
        try plan.validate()
        guard plan.scope.evidenceTargetID == operation.targetID else { throw Failure.wrongTarget }
        operations[index].nativeVerificationPlan = plan
        operations[index].plannedVerificationProgress = PlannedVerificationProgress()
    }

    /// Call before starting the observation I/O, including the first automatic
    /// post-action read. A retained snapshot cannot spend a new attempt or pass
    /// as that attempt's observation merely because its UUID is still known.
    @discardableResult
    mutating func beginPlannedVerificationAttempt(operationID: String) throws -> Int {
        let index = try unresolvedIndex(operationID)
        guard operations[index].hasVerificationPlan,
              var progress = operations[index].plannedVerificationProgress else { throw Failure.missingVerificationPlan }
        guard operations[index].dispatch != .notDispatched,
              operations[index].preflightRejection == nil,
              progress.outcome != .observing else { throw Failure.invalidTransition }
        guard progress.attempts < Self.maximumPlannedVerificationAttempts else { throw Failure.verificationAttemptsExhausted }
        progress.attempts += 1
        progress.attemptAfterSequence = try nextSequence()
        progress.outcome = .observing
        operations[index].plannedVerificationProgress = progress
        return progress.attempts
    }

    /// I/O absence is not a failed mutation and never causes another dispatch.
    mutating func recordPlannedVerificationReadFailure(operationID: String) throws {
        let index = try unresolvedIndex(operationID)
        guard var progress = operations[index].plannedVerificationProgress else { throw Failure.missingVerificationPlan }
        guard progress.outcome == .observing else { throw Failure.invalidTransition }
        progress.outcome = .observationUnavailable
        operations[index].plannedVerificationProgress = progress
    }

    /// Only host-owned browser observations can satisfy an armed plan. The
    /// bounded baseline/selector is stored in the plan, not supplied after the
    /// action by a model or inferred from an arbitrary changed property.
    @discardableResult
    mutating func verifyPlanned(operationID: String, observationID: String,
                               binding: BrowserTabBinding, snapshot: BrowserTabSnapshot) throws -> Verification {
        let index = try unresolvedIndex(operationID)
        guard let plan = operations[index].verificationPlan,
              var progress = operations[index].plannedVerificationProgress else { throw Failure.missingVerificationPlan }
        guard progress.outcome == .observing, let attemptAfter = progress.attemptAfterSequence else {
            throw Failure.invalidTransition
        }
        do {
            guard let observation = observations.first(where: { $0.id == observationID }) else { throw Failure.missingObservation }
            guard observationID == snapshot.id.uuidString,
                  observation.isLive, snapshot.isLiveObservation,
                  observation.sequence > operations[index].observationAfter,
                  observation.sequence > attemptAfter else { throw Failure.staleObservation }
            guard observation.targetID == operations[index].targetID,
                  plan.scope.evidenceTargetID == operations[index].targetID else { throw Failure.wrongTarget }
            guard operations[index].dispatch != .notDispatched,
                  operations[index].preflightRejection == nil else { throw Failure.invalidTransition }
            let proof = try plan.evaluate(binding: binding, snapshot: snapshot)
            guard proof.observationID == snapshot.id,
                  proof.property == plan.property, proof.expectedValue == plan.expected else { throw Failure.propertyMismatch }
            let receipt = Verification(operationID: operationID, observationID: observationID,
                                       property: proof.property, expectedValue: proof.expectedValue)
            operations[index].verification = receipt
            progress.outcome = .verified
            operations[index].plannedVerificationProgress = progress
            resolvePendingActionRejections(originalOperationID: operationID)
            return receipt
        } catch {
            progress.outcome = .postconditionMismatch
            operations[index].plannedVerificationProgress = progress
            throw error
        }
    }

    @discardableResult
    mutating func verifyNativePlanned(operationID: String, observationID: String,
                                     scope: NativeActionVerification.Scope,
                                     observation: NativeActionVerification.Observation) throws -> Verification {
        let index = try unresolvedIndex(operationID)
        guard let plan = operations[index].nativeVerificationPlan,
              var progress = operations[index].plannedVerificationProgress else { throw Failure.missingVerificationPlan }
        guard progress.outcome == .observing, let attemptAfter = progress.attemptAfterSequence else {
            throw Failure.invalidTransition
        }
        do {
            guard let retained = observations.first(where: { $0.id == observationID }) else { throw Failure.missingObservation }
            guard observationID == observation.snapshot.id.uuidString, retained.isLive, observation.isLive,
                  retained.sequence > operations[index].observationAfter,
                  retained.sequence > attemptAfter else { throw Failure.staleObservation }
            guard retained.targetID == operations[index].targetID,
                  plan.scope.evidenceTargetID == operations[index].targetID else { throw Failure.wrongTarget }
            guard operations[index].dispatch != .notDispatched, operations[index].preflightRejection == nil,
                  !plan.baselineSatisfied else { throw Failure.invalidTransition }
            let proof = try plan.evaluate(scope: scope, observation: observation)
            guard proof.observationID == observation.snapshot.id,
                  proof.property == plan.property, proof.expectedValue == plan.expected else { throw Failure.propertyMismatch }
            let receipt = Verification(operationID: operationID, observationID: observationID,
                                       property: proof.property, expectedValue: proof.expectedValue)
            operations[index].verification = receipt
            progress.outcome = .verified
            operations[index].plannedVerificationProgress = progress
            resolvePendingActionRejections(originalOperationID: operationID)
            return receipt
        } catch {
            progress.outcome = .postconditionMismatch
            operations[index].plannedVerificationProgress = progress
            throw error
        }
    }

    @discardableResult
    mutating func recordNativeAlreadySatisfied(operationID: String, scope: NativeActionVerification.Scope,
                                              observation: NativeActionVerification.Observation) throws -> AlreadySatisfiedReceipt {
        let index = try unresolvedIndex(operationID)
        guard let plan = operations[index].nativeVerificationPlan,
              var progress = operations[index].plannedVerificationProgress else { throw Failure.missingVerificationPlan }
        guard operations[index].dispatch == .notDispatched, operations[index].foregroundEffect == nil,
              operations[index].failureCode == nil, operations[index].preflightRejection == nil,
              plan.baselineSatisfied, progress.attempts == 0, progress.outcome == .pending,
              observation.snapshot.id != plan.baselineSnapshotID else { throw Failure.invalidTransition }
        guard let retained = observations.first(where: { $0.id == observation.snapshot.id.uuidString }) else {
            throw Failure.missingObservation
        }
        guard retained.isLive, observation.isLive, retained.sequence > operations[index].observationAfter else {
            throw Failure.staleObservation
        }
        guard observations.last(where: { $0.targetID == retained.targetID && $0.isLive })?.id == retained.id else {
            throw Failure.staleObservation
        }
        guard retained.targetID == operations[index].targetID,
              plan.scope.evidenceTargetID == operations[index].targetID else { throw Failure.wrongTarget }
        let proof = try plan.evaluate(scope: scope, observation: observation)
        guard proof.observationID == observation.snapshot.id,
              proof.property == plan.property, proof.expectedValue == plan.expected else { throw Failure.propertyMismatch }
        let receipt = AlreadySatisfiedReceipt(operationID: operationID, observationID: retained.id,
            property: proof.property, expectedValue: proof.expectedValue, observationSequence: retained.sequence)
        operations[index].alreadySatisfied = receipt
        progress.outcome = .alreadySatisfied
        operations[index].plannedVerificationProgress = progress
        resolvePendingActionRejections(originalOperationID: operationID)
        return receipt
    }

    /// The host input barrier invokes this before approval or dispatch. The
    /// rejected request is not a second uncertain action; it remains linked to
    /// the one earlier operation whose outcome is still pending.
    mutating func recordPendingActionRejection(operationID: String, pendingOperationID: String) throws {
        let index = try unresolvedIndex(operationID)
        guard let pendingIndex = operations.firstIndex(where: { $0.id == pendingOperationID }), pendingIndex < index else {
            throw Failure.invalidRecovery
        }
        let rejected = operations[index], pending = operations[pendingIndex]
        guard rejected.requiresVerification, rejected.dispatch == .notDispatched,
              rejected.foregroundEffect == nil, rejected.failureCode == nil,
              rejected.preflightRejection == nil, !rejected.hasVerificationPlan,
              rejected.pendingActionRejection == nil,
              pending.requiresVerification, !pending.isResolved,
              pending.preflightRejection == nil, pending.pendingActionRejection == nil,
              pending.dispatch != .notDispatched || pending.nativeVerificationPlan?.baselineSatisfied == true,
              rejected.targetID == pending.targetID else { throw Failure.invalidRecovery }
        let rejectionSequence = try nextSequence()
        operations[index].preflightRejection = .pendingAction
        operations[index].failureCode = "pending_action_rejected"
        operations[index].failureMessage = "Input was not dispatched because operation \(pendingOperationID) awaits verification."
        operations[index].observationAfter = rejectionSequence
        operations[index].pendingActionRejection = PendingActionRejectionReceipt(
            pendingOperationID: pendingOperationID, rejectionSequence: rejectionSequence)
    }

    private mutating func resolvePendingActionRejections(originalOperationID: String) {
        guard let original = operations.first(where: { $0.id == originalOperationID }) else { return }
        let resolution: PendingActionRejectionReceipt.Resolution
        let observationID: String
        if let proof = original.verification { resolution = .verified; observationID = proof.observationID }
        else if let proof = original.alreadySatisfied { resolution = .alreadySatisfied; observationID = proof.observationID }
        else { return }
        for index in operations.indices where operations[index].pendingActionRejection?.pendingOperationID == originalOperationID {
            operations[index].pendingActionRejection?.resolution = resolution
            operations[index].pendingActionRejection?.resolutionObservationID = observationID
        }
    }

    /// A read may lazily restore its exact authorized target during execution.
    /// Publish that runtime-owned identity before its success receipt, never
    /// retarget input or rewrite a failed/dispatched operation after the fact.
    mutating func retargetUndispatchedRead(operationID: String, targetID: String) throws {
        try Self.identity(targetID)
        let index = try unresolvedIndex(operationID)
        guard operations[index].tool == "computer_v2_snapshot", !operations[index].requiresVerification,
              operations[index].dispatch == .notDispatched, operations[index].failureCode == nil,
              operations[index].preflightRejection == nil else { throw Failure.invalidTransition }
        operations[index].targetID = targetID
    }

    mutating func recordDispatch(operationID: String, state: DispatchState) throws {
        let index = try unresolvedIndex(operationID)
        guard operations[index].preflightRejection == nil,
              operations[index].nativeVerificationPlan?.baselineSatisfied != true || state == .notDispatched else {
            throw Failure.invalidTransition
        }
        operations[index].dispatch = state
        operations[index].observationAfter = try nextSequence()
    }

    mutating func recordForegroundEffect(operationID: String, effect: ForegroundEffect) throws {
        let index = try unresolvedIndex(operationID)
        guard operations[index].preflightRejection == nil else { throw Failure.invalidTransition }
        operations[index].foregroundEffect = effect
        operations[index].observationAfter = try nextSequence()
    }

    mutating func recordFailure(operationID: String, code: String, message: String,
                               dispatch: DispatchState = .unknown) throws {
        try Self.identity(code)
        let index = try unresolvedIndex(operationID)
        guard operations[index].preflightRejection == nil else { throw Failure.invalidTransition }
        operations[index].dispatch = dispatch
        operations[index].failureCode = code
        operations[index].failureMessage = String(message.prefix(512))
        operations[index].observationAfter = try nextSequence()
    }

    /// Keeps the rejected request visible without representing it as uncertain
    /// delivered input. It remains completion debt until a typed correction is
    /// established; approval refusal, connection loss and unclassified failures
    /// must use recordFailure instead.
    mutating func recordPreflightRejection(operationID: String, kind: PreflightRejection,
                                          code: String, message: String, targetWasUnbound: Bool = false) throws {
        try Self.identity(code)
        let index = try unresolvedIndex(operationID)
        guard operations[index].dispatch == .notDispatched,
              operations[index].foregroundEffect == nil,
              operations[index].preflightRejection == nil,
              kind != .pendingAction,
              !targetWasUnbound || kind == .invalidArguments else { throw Failure.invalidTransition }
        operations[index].preflightRejection = kind
        operations[index].preflightTargetWasUnbound = targetWasUnbound ? true : nil
        operations[index].failureCode = code
        operations[index].failureMessage = String(message.prefix(512))
        operations[index].observationAfter = try nextSequence()
    }

    /// A correction proves only that the validation prerequisite was repaired,
    /// not that the rejected action ran. Ordinary failed/uncertain operations
    /// are ineligible and keep their existing outcome-verification obligations.
    @discardableResult
    mutating func recoverPreflightRejections(afterSuccessfulOperationID successorID: String,
                                            correction: PreflightCorrection) throws -> Int {
        guard let successorIndex = operations.firstIndex(where: { $0.id == successorID }) else {
            throw Failure.missingOperation
        }
        let successor = operations[successorIndex]
        guard Self.isDirectSuccessfulOperation(successor) else { throw Failure.invalidRecovery }
        let receipt: PreflightCorrectionReceipt
        switch correction {
        case .validatedArguments:
            let observed = observations.last { $0.targetID == successor.targetID && $0.isLive
                && $0.sequence > successor.observationAfter }
            receipt = .init(successorOperationID: successorID, kind: .validatedArguments,
                            observationID: observed?.id, observationTargetID: observed?.targetID,
                            observationSequence: observed?.sequence)
        case .freshBoundObservation(let observationID, let targetID):
            guard successor.tool == "computer_v2_snapshot", !successor.requiresVerification else {
                throw Failure.invalidRecovery
            }
            guard let observation = observations.first(where: { $0.id == observationID }) else {
                throw Failure.missingObservation
            }
            guard observation.isLive, observation.sequence > successor.observationAfter else {
                throw Failure.staleObservation
            }
            guard targetID == successor.targetID, observation.targetID == targetID else {
                throw Failure.wrongTarget
            }
            receipt = .init(successorOperationID: successorID, kind: .freshBoundObservation,
                            observationID: observationID, observationTargetID: targetID,
                            observationSequence: observation.sequence)
        }
        var corrected = 0
        for index in operations.indices where index < successorIndex && !operations[index].isResolved {
            guard Self.isValidPreflightCorrection(failed: operations[index], successor: successor, receipt: receipt) else { continue }
            operations[index].preflightCorrection = receipt
            corrected += 1
        }
        return corrected
    }

    /// Values must come from the runtime's immutable snapshot, never from the
    /// model's assertion. Bounding the retained properties can prevent a proof
    /// from being available; it cannot turn an absent property into a match.
    mutating func recordObservation(id: String, targetID: String, properties: [String: String],
                                    isLive: Bool = true) throws {
        try Self.identity(id)
        try Self.identity(targetID)
        // Reusing an ID must not make an old snapshot appear freshly captured.
        guard !observations.contains(where: { $0.id == id }) else { throw Failure.staleObservation }
        var retained: [String: String] = [:]
        var bytes = 0
        for key in properties.keys.sorted() {
            guard retained.count < Self.maximumProperties, let value = properties[key],
                  !key.isEmpty, key.utf8.count <= 256, value.utf8.count <= 8_192 else { continue }
            let additional = key.utf8.count + value.utf8.count
            guard bytes + additional <= Self.maximumPropertyBytes else { continue }
            retained[key] = value
            bytes += additional
        }
        observations.append(Observation(id: id, targetID: targetID, sequence: try nextSequence(),
                                        properties: retained, isLive: isLive))
        if observations.count > Self.maximumObservations {
            observations.removeFirst(observations.count - Self.maximumObservations)
        }
    }

    /// Confirms exactly one rendered property, not a whole task or absence of
    /// unseen content. A search query value alone never proves search results.
    @discardableResult
    mutating func verify(operationID: String, observationID: String,
                         property: String, expectedValue: String) throws -> Verification {
        let index = try unresolvedIndex(operationID)
        guard !operations[index].hasVerificationPlan else { throw Failure.plannedVerificationRequired }
        guard let observation = observations.first(where: { $0.id == observationID }) else {
            throw Failure.missingObservation
        }
        guard observation.isLive, observation.sequence > operations[index].observationAfter else {
            throw Failure.staleObservation
        }
        guard observation.targetID == operations[index].targetID else { throw Failure.wrongTarget }
        // A failed pre-dispatch action cannot be rescued merely by observing an
        // already-existing value. Unknown delivery may be reconciled by a read.
        guard operations[index].dispatch != .notDispatched else { throw Failure.invalidTransition }
        guard !expectedValue.isEmpty, expectedValue.utf8.count <= 8_192,
              observation.properties[property] == expectedValue else { throw Failure.propertyMismatch }
        // A property omitted by a progressive/bounded pre-action read may have
        // existed all along. Absence from that read is not proof it is new.
        guard let baseline = operations[index].baselineProperties,
              let previousValue = baseline[property] else { throw Failure.missingBaseline }
        guard previousValue != Self.fingerprint(expectedValue) else { throw Failure.unchangedProperty }
        let receipt = Verification(operationID: operationID, observationID: observationID,
                                   property: property, expectedValue: expectedValue)
        operations[index].verification = receipt
        resolvePendingActionRejections(originalOperationID: operationID)
        return receipt
    }

    mutating func recover(failedOperationID: String, with verifiedOperationID: String) throws {
        let failed = try unresolvedIndex(failedOperationID)
        guard operations[failed].preflightRejection == nil,
              let verified = operations.firstIndex(where: { $0.id == verifiedOperationID }),
              verified > failed,
              (operations[verified].verification != nil
               || (!operations[failed].requiresVerification && !operations[verified].requiresVerification
                   && operations[verified].isResolved && operations[verified].recoveredBy == nil)),
              operations[failed].targetID == operations[verified].targetID,
              let key = operations[failed].recoveryKey, key == operations[verified].recoveryKey,
              Self.plansHaveMatchingIntent(failed: operations[failed], successor: operations[verified]) else {
            throw Failure.invalidRecovery
        }
        operations[failed].recoveredBy = verifiedOperationID
    }

    /// An unsupported, undispatched focus press on an editable field is no
    /// longer needed once direct text entry on that exact field is verified.
    /// This finite alternative never excuses a dispatched press, another field
    /// or an unrelated mutation. The runtime alone assigns the focus key from
    /// the pre-action observation's editable-field identity.
    mutating func recoverUndispatchedFocus(failedOperationID: String, with verifiedOperationID: String) throws {
        let failed = try unresolvedIndex(failedOperationID)
        guard let verified = operations.firstIndex(where: { $0.id == verifiedOperationID }),
              verified > failed,
              Self.isVerifiedAlternativeToUndispatchedFocus(failed: operations[failed], successor: operations[verified]) else {
            throw Failure.invalidRecovery
        }
        operations[failed].recoveredBy = verifiedOperationID
    }

    var unresolvedOperations: [Operation] { operations.filter { !$0.isResolved } }

    /// Keep rejected calls in the audit ledger, but do not count one blocked
    /// retry as another action with uncertain effects. Each linked rejection
    /// refers to its original outcome obligation until that proof is resolved.
    /// Include that original even if some unrelated recovery marked it resolved;
    /// a linked rejection is released only by its actual verification/no-op.
    var unresolvedOutcomeOperations: [Operation] {
        let linkedOriginals = Set(unresolvedOperations.compactMap { $0.pendingActionRejection?.pendingOperationID })
        return operations.filter {
            (!$0.isResolved && $0.pendingActionRejection == nil) || linkedOriginals.contains($0.id)
        }
    }

    var unresolvedBlockedInputCount: Int {
        unresolvedOperations.filter { $0.pendingActionRejection != nil }.count
    }

    func latestLiveObservationIdentity(targetID: String) -> (id: String, targetID: String)? {
        guard let observation = observations.last(where: { $0.targetID == targetID && $0.isLive }) else { return nil }
        return (observation.id, observation.targetID)
    }

    /// A fresh inspection may permit a distinct next step without proving the
    /// earlier outcome. Callers must supply runtime-owned stable intent keys;
    /// new snapshot/capture IDs or model assertions are not distinct intent.
    /// Unknown or matching intent remains conservative even after inspection.
    func blocksFurtherInput(operationID: String, nextRecoveryKey: String?, nextTargetID: String?) -> Bool {
        guard let operation = operations.first(where: { $0.id == operationID }) else { return true }
        guard !operation.isResolved, operation.requiresVerification,
              operation.dispatch != .notDispatched || operation.foregroundEffect != nil else { return false }
        // Runtime-planned input is an action/observe/verify unit. Even another
        // intent must wait so it cannot overwrite the outcome being checked.
        if operation.hasVerificationPlan { return true }
        guard let previousKey = operation.recoveryKey, let nextRecoveryKey,
              !nextRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nextRecoveryKey != previousKey,
              let nextTargetID, nextTargetID == operation.targetID else { return true }
        return !observations.contains {
            $0.isLive && $0.targetID == operation.targetID && $0.sequence > operation.observationAfter
        }
    }

    var completionDiagnostic: String? {
        guard !unresolvedOperations.isEmpty else { return nil }
        let unresolved = unresolvedOutcomeOperations
        let failures = unresolved.filter { $0.failureCode != nil }.count
        let blocked = unresolvedBlockedInputCount
        return "Computer-use outcome not verified: \(unresolved.count) operation(s) remain unresolved"
            + (failures == 0 ? "." : ", including \(failures) failed operation(s).")
            + (blocked == 0 ? "" : " \(blocked) subsequent input request(s) were blocked before dispatch; they are not additional uncertain actions.")
            + " This attempt does not establish that the requested action completed or that a search found no results."
    }

    /// A compact, app-authored reminder suitable for compaction. It deliberately
    /// omits page contents and cannot be interpreted as a new observation.
    func checkpointText() throws -> String {
        try validate()
        let entries = unresolvedOutcomeOperations.prefix(8).map {
            "operation=\($0.id) tool=\($0.tool) dispatch=\($0.dispatch.rawValue)"
                + ($0.foregroundEffect.map { " foreground_effect=\($0.rawValue)" } ?? "")
                + " status=\($0.failureCode == nil ? "unverified" : "failed")"
                + ($0.preflightRejection.map { " preflight_rejection=\($0.rawValue)" } ?? "")
                + ($0.plannedVerificationProgress.map {
                    " verification=\($0.outcome.rawValue) verification_reads=\($0.attempts)/\(Self.maximumPlannedVerificationAttempts)"
                } ?? "")
        }
        let corrected = operations.filter { $0.preflightCorrection != nil }.suffix(8).map {
            "operation=\($0.id) tool=\($0.tool) dispatch=not_dispatched status=preflight_corrected_not_performed"
        }
        let satisfied = operations.filter { $0.alreadySatisfied != nil }.suffix(8).map {
            "operation=\($0.id) tool=\($0.tool) dispatch=not_dispatched status=already_satisfied_not_performed"
        }
        let linked = operations.compactMap { operation -> String? in
            guard let receipt = operation.pendingActionRejection else { return nil }
            return "operation=\(operation.id) tool=\(operation.tool) dispatch=not_dispatched"
                + " status=\(receipt.resolution == nil ? "blocked_by_pending_action" : "pending_action_resolved_not_performed")"
                + " pending_operation=\(receipt.pendingOperationID)"
        }.suffix(8)
        return (["RUNTIME_ACTION_EVIDENCE turn=\(turnID)",
                 completionDiagnostic ?? "No unresolved action receipts. This does not verify arbitrary task claims."]
                + entries + corrected + satisfied + Array(linked)).joined(separator: "\n")
    }

    func checkpointData() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumCheckpointBytes else { throw Failure.capacityExceeded }
        return data
    }

    static func restore(_ data: Data, turnID: String) throws -> Self {
        guard data.count <= maximumCheckpointBytes else { throw Failure.capacityExceeded }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.turnID == turnID else { throw Failure.invalidCheckpoint }
        try value.validate()
        return value
    }

    private func unresolvedIndex(_ id: String) throws -> Int {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { throw Failure.missingOperation }
        guard !operations[index].isResolved else { throw Failure.invalidTransition }
        return index
    }

    private mutating func nextSequence() throws -> UInt64 {
        guard sequence < UInt64.max else { throw Failure.capacityExceeded }
        sequence += 1
        return sequence
    }

    private static func identity(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidIdentity
        }
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDirectSuccessfulOperation(_ operation: Operation) -> Bool {
        operation.dispatch == .dispatched && operation.failureCode == nil
            && operation.preflightRejection == nil && operation.preflightCorrection == nil
            && operation.recoveredBy == nil && operation.isResolved
    }

    private static func plansHaveMatchingIntent(failed: Operation, successor: Operation) -> Bool {
        if let original = failed.nativeVerificationPlan {
            guard let replacement = successor.nativeVerificationPlan else { return false }
            return original.scope.evidenceTargetID == replacement.scope.evidenceTargetID
                && original.property == replacement.property && original.expected == replacement.expected
        }
        guard let original = failed.verificationPlan else { return true }
        guard let replacement = successor.verificationPlan else { return false }
        return original.scope.evidenceTargetID == replacement.scope.evidenceTargetID
            && original.kind == replacement.kind && original.property == replacement.property
            && original.expected == replacement.expected
    }

    private static func isValidPreflightCorrection(failed: Operation, successor: Operation,
                                                   receipt: PreflightCorrectionReceipt) -> Bool {
        guard failed.dispatch == .notDispatched, failed.failureCode != nil,
              failed.verification == nil, failed.recoveredBy == nil,
              let rejection = failed.preflightRejection,
              rejection != .pendingAction,
              receipt.successorOperationID == successor.id,
              isDirectSuccessfulOperation(successor) else { return false }
        switch receipt.kind {
        case .validatedArguments:
            guard failed.tool == successor.tool else { return false }
            let hasObservedTarget = receipt.observationID?.isEmpty == false
                && receipt.observationTargetID == successor.targetID
                && (receipt.observationSequence ?? 0) > successor.observationAfter
            let hasNoObservation = receipt.observationID == nil && receipt.observationTargetID == nil
                && receipt.observationSequence == nil
            guard hasObservedTarget || hasNoObservation else { return false }
            if failed.targetID != successor.targetID {
                // Schema validation can happen before lazy target restoration.
                // It is not evidence that an action targeted the old placeholder.
                // Require an explicit host fact and fresh observation of the
                // successor target; never infer this from a target string.
                guard rejection == .invalidArguments, failed.preflightTargetWasUnbound == true,
                      hasObservedTarget else { return false }
            }
            if rejection == .invalidArguments { return true }
            // The model may already hold a newer observation when it first
            // supplies a stale ID. A verified replacement of that exact intent
            // proves its reference was corrected without requiring another read.
            return rejection == .freshObservationRequired && successor.verification != nil
                && failed.recoveryKey != nil && failed.recoveryKey == successor.recoveryKey
        case .freshBoundObservation:
            guard successor.tool == "computer_v2_snapshot", !successor.requiresVerification,
                  receipt.observationID?.isEmpty == false,
                  receipt.observationTargetID == successor.targetID,
                  let sequence = receipt.observationSequence, sequence > successor.observationAfter else { return false }
            return rejection == .bindingRequired
                || (rejection == .freshObservationRequired && failed.targetID == successor.targetID)
        }
    }

    private static func isVerifiedAlternativeToUndispatchedFocus(failed: Operation, successor: Operation) -> Bool {
        guard failed.preflightRejection == nil,
              failed.tool == "computer_v2_ax", failed.dispatch == .notDispatched,
              failed.failureCode != nil, let key = failed.recoveryKey,
              key.hasPrefix("focus:"), key.count > "focus:".count,
              successor.tool == "computer_v2_set_text", successor.targetID == failed.targetID,
              let verification = successor.verification else { return false }
        return verification.operationID == successor.id
            && verification.property == String(key.dropFirst("focus:".count)) + ":value"
    }

    private func validate() throws {
        try Self.identity(turnID)
        guard operations.count <= Self.maximumOperations, observations.count <= Self.maximumObservations,
              Set(operations.map(\.id)).count == operations.count,
              Set(observations.map(\.id)).count == observations.count else { throw Failure.invalidCheckpoint }
        for operation in operations {
            for id in [operation.id, operation.tool, operation.targetID] { try Self.identity(id) }
            if let key = operation.recoveryKey { try Self.identity(key) }
            if let baseline = operation.baselineProperties {
                guard baseline.count <= Self.maximumProperties,
                      baseline.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256
                          && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
                    throw Failure.invalidCheckpoint
                }
            }
            guard operation.observationAfter <= sequence else { throw Failure.invalidCheckpoint }
            if let code = operation.failureCode { try Self.identity(code) }
            guard (operation.failureMessage?.count ?? 0) <= 512 else { throw Failure.invalidCheckpoint }
            guard operation.verificationPlan == nil || operation.nativeVerificationPlan == nil else { throw Failure.invalidCheckpoint }
            if let plan = operation.verificationPlan { try plan.validate() }
            if let plan = operation.nativeVerificationPlan { try plan.validate() }
            let plannedTarget = operation.verificationPlan?.scope.evidenceTargetID ?? operation.nativeVerificationPlan?.scope.evidenceTargetID
            let plannedProperty = operation.verificationPlan?.property ?? operation.nativeVerificationPlan?.property
            let plannedExpected = operation.verificationPlan?.expected ?? operation.nativeVerificationPlan?.expected
            if let plannedTarget {
                guard operation.requiresVerification,
                      ["computer_v2_ax", "computer_v2_set_text"].contains(operation.tool),
                      plannedTarget == operation.targetID,
                      let progress = operation.plannedVerificationProgress,
                      (0 ... Self.maximumPlannedVerificationAttempts).contains(progress.attempts) else {
                    throw Failure.invalidCheckpoint
                }
                if progress.attempts == 0 {
                    guard progress.outcome == .pending || progress.outcome == .alreadySatisfied,
                          progress.attemptAfterSequence == nil,
                          operation.verification == nil else { throw Failure.invalidCheckpoint }
                } else {
                    guard operation.dispatch != .notDispatched, operation.preflightRejection == nil,
                          progress.outcome != .pending, progress.outcome != .alreadySatisfied,
                          let attemptAfter = progress.attemptAfterSequence,
                          attemptAfter <= sequence else {
                        throw Failure.invalidCheckpoint
                    }
                }
                guard (progress.outcome == .verified) == (operation.verification != nil) else {
                    throw Failure.invalidCheckpoint
                }
                guard (progress.outcome == .alreadySatisfied) == (operation.alreadySatisfied != nil) else {
                    throw Failure.invalidCheckpoint
                }
                if let receipt = operation.verification {
                    guard receipt.property == plannedProperty, receipt.expectedValue == plannedExpected,
                          operation.nativeVerificationPlan?.baselineSatisfied != true,
                          (progress.attemptAfterSequence ?? 0) > operation.observationAfter else {
                        throw Failure.invalidCheckpoint
                    }
                    if let retained = observations.first(where: { $0.id == receipt.observationID }) {
                        guard retained.isLive, retained.targetID == operation.targetID,
                              retained.sequence > (progress.attemptAfterSequence ?? sequence) else {
                            throw Failure.invalidCheckpoint
                        }
                    }
                }
            } else if operation.plannedVerificationProgress != nil {
                throw Failure.invalidCheckpoint
            }
            if let verification = operation.verification {
                guard verification.operationID == operation.id,
                      !verification.expectedValue.isEmpty || operation.hasVerificationPlan,
                      verification.expectedValue.utf8.count <= 8_192 else { throw Failure.invalidCheckpoint }
                try Self.identity(verification.observationID)
            }
            if let receipt = operation.alreadySatisfied {
                guard let plan = operation.nativeVerificationPlan, plan.baselineSatisfied,
                      operation.verificationPlan == nil, operation.requiresVerification,
                      operation.dispatch == .notDispatched, operation.foregroundEffect == nil,
                      operation.failureCode == nil, operation.failureMessage == nil,
                      operation.verification == nil, operation.recoveredBy == nil,
                      operation.preflightRejection == nil, operation.preflightCorrection == nil,
                      operation.pendingActionRejection == nil,
                      receipt.operationID == operation.id, receipt.observationID != plan.baselineSnapshotID.uuidString,
                      receipt.property == plan.property, receipt.expectedValue == plan.expected,
                      receipt.observationSequence > operation.observationAfter,
                      receipt.observationSequence <= sequence else { throw Failure.invalidCheckpoint }
                try Self.identity(receipt.observationID)
                if let retained = observations.first(where: { $0.id == receipt.observationID }) {
                    guard retained.isLive, retained.targetID == operation.targetID,
                          retained.sequence == receipt.observationSequence else { throw Failure.invalidCheckpoint }
                }
            }
            if operation.preflightRejection != nil {
                guard operation.dispatch == .notDispatched, operation.failureCode != nil,
                      operation.foregroundEffect == nil,
                      operation.verification == nil, operation.recoveredBy == nil,
                      operation.alreadySatisfied == nil else { throw Failure.invalidCheckpoint }
            }
            if let receipt = operation.pendingActionRejection {
                guard let index = operations.firstIndex(where: { $0.id == operation.id }),
                      let original = operations.prefix(index).first(where: { $0.id == receipt.pendingOperationID }),
                      operation.requiresVerification, operation.preflightRejection == .pendingAction,
                      operation.failureCode == "pending_action_rejected", !operation.hasVerificationPlan,
                      operation.preflightCorrection == nil, operation.alreadySatisfied == nil,
                      operation.preflightTargetWasUnbound == nil,
                      receipt.rejectionSequence > 0, receipt.rejectionSequence == operation.observationAfter,
                      original.requiresVerification, original.targetID == operation.targetID,
                      original.preflightRejection == nil, original.pendingActionRejection == nil,
                      original.dispatch != .notDispatched || original.nativeVerificationPlan?.baselineSatisfied == true else {
                    throw Failure.invalidCheckpoint
                }
                switch receipt.resolution {
                case nil:
                    guard receipt.resolutionObservationID == nil, original.verification == nil,
                          original.alreadySatisfied == nil else { throw Failure.invalidCheckpoint }
                case .verified:
                    guard original.dispatch != .notDispatched,
                          let proof = original.verification, proof.observationID == receipt.resolutionObservationID else {
                        throw Failure.invalidCheckpoint
                    }
                case .alreadySatisfied:
                    guard let proof = original.alreadySatisfied, proof.observationID == receipt.resolutionObservationID else {
                        throw Failure.invalidCheckpoint
                    }
                }
            } else if operation.preflightRejection == .pendingAction {
                throw Failure.invalidCheckpoint
            }
            if operation.preflightTargetWasUnbound != nil {
                guard operation.preflightTargetWasUnbound == true,
                      operation.preflightRejection == .invalidArguments else { throw Failure.invalidCheckpoint }
            }
            if let correction = operation.preflightCorrection {
                guard let index = operations.firstIndex(where: { $0.id == operation.id }),
                      let later = operations.dropFirst(index + 1).first(where: { $0.id == correction.successorOperationID }),
                      Self.isValidPreflightCorrection(failed: operation, successor: later, receipt: correction) else {
                    throw Failure.invalidCheckpoint
                }
                if let id = correction.observationID {
                    try Self.identity(id)
                    guard let observationSequence = correction.observationSequence, observationSequence <= sequence,
                          let targetID = correction.observationTargetID else { throw Failure.invalidCheckpoint }
                    try Self.identity(targetID)
                    if let retained = observations.first(where: { $0.id == id }) {
                        guard retained.isLive, retained.sequence == observationSequence, retained.targetID == targetID else {
                            throw Failure.invalidCheckpoint
                        }
                    }
                }
            }
            if let successor = operation.recoveredBy {
                guard let index = operations.firstIndex(where: { $0.id == operation.id }),
                      let later = operations.dropFirst(index + 1).first(where: { $0.id == successor }),
                      (((later.verification != nil
                         || (!operation.requiresVerification && !later.requiresVerification
                             && later.isResolved && later.recoveredBy == nil))
                        && later.targetID == operation.targetID
                        && operation.recoveryKey != nil && later.recoveryKey == operation.recoveryKey
                        && Self.plansHaveMatchingIntent(failed: operation, successor: later))
                       || Self.isVerifiedAlternativeToUndispatchedFocus(failed: operation, successor: later)) else {
                    throw Failure.invalidCheckpoint
                }
            }
        }
        for observation in observations {
            try Self.identity(observation.id)
            try Self.identity(observation.targetID)
            guard observation.sequence <= sequence, observation.properties.count <= Self.maximumProperties,
                  observation.properties.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8_192 }),
                  observation.properties.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= Self.maximumPropertyBytes else {
                throw Failure.invalidCheckpoint
            }
        }
    }
}
