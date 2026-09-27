import Foundation

/// A resolved notification names a request, not the decision that was delivered.
/// Only a successful return from resolveApproval confirms our requested decision.
struct ApprovalResolutionResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case delivered
        case notAttempted = "not_attempted"
        case failed
    }

    let requestID: String
    let status: Status
    let reason: String
    var approved: Bool? = nil
    var dispatchStartedAt: UInt64? = nil
    var returnedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    var requestRestored = false
    var resolvedEventObserved = false

    var delivered: Bool { status == .delivered }
}
