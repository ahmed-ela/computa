import Foundation

/// Ephemeral mention evidence only; this state never grants action authority.
struct ExplicitApplicationRequest: Equatable, Sendable {
    struct Scope: Equatable, Sendable {
        let generation: UUID
        let turnID: String
        let sessionEpoch: UUID
    }
    struct SteerTicket: Equatable, Sendable {
        let id: UUID
        let scope: Scope
    }

    let submissionID: UUID
    private(set) var text: String?
    private var awaitingStart = true
    private var pendingSteer: SteerTicket?

    init(prompt: String, submissionID: UUID) {
        self.submissionID = submissionID
        text = Self.bounded(prompt)
    }

    func started(isUserTurn: Bool) -> Self? {
        guard isUserTurn, awaitingStart else { return nil }
        var bound = self
        bound.awaitingStart = false
        return bound
    }

    mutating func beginSteer(scope: Scope) -> SteerTicket {
        text = nil
        let ticket = SteerTicket(id: UUID(), scope: scope)
        pendingSteer = ticket
        return ticket
    }

    mutating func acknowledgeSteer(prompt: String, ticket: SteerTicket, currentScope: Scope) {
        guard ticket == pendingSteer, ticket.scope == currentScope else { return }
        pendingSteer = nil
        text = Self.bounded(prompt)
    }

    mutating func invalidate() {
        text = nil
        awaitingStart = false
        pendingSteer = nil
    }

    private static func bounded(_ prompt: String) -> String? {
        !prompt.isEmpty && prompt.utf16.count <= 8_192 ? prompt : nil
    }
}
