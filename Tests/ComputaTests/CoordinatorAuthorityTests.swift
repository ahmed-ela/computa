import Foundation
import XCTest
@testable import Computa

/// Pure coordinator authority tests. No socket, Chrome, Keychain, preferences,
/// browser permission, or user profile is touched.
final class CoordinatorAuthorityTests: XCTestCase {
    func testExactPairingProposalCanCompleteOnlyInOriginalGeneration() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let id = UUID(), proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let peers = [id: proposal]
        let attempt = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: peers)
        XCTAssertNoThrow(try guardState.validate(attempt, hellos: peers))
        guardState.revoke() // Same synchronous fence used by Forget and stop.
        XCTAssertThrowsError(try guardState.validate(attempt, hellos: peers))
        // Explicit later approval is a new generation, not a revived response.
        let fresh = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: peers)
        XCTAssertNoThrow(try guardState.validate(fresh, hellos: peers))
    }

    func testMatchingSuccessHelloMayArriveBeforePairingReply() throws {
        let guardState = ChromeExtensionAuthorityGuard(), id = UUID()
        let proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: [id: proposal])
        let success = hello(paired: true, token: token)
        XCTAssertNoThrow(try guardState.validate(attempt, hellos: [id: success]))
    }

    func testForgetFenceRejectsBothProposalAndEarlySuccessAfterResponse() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let id = UUID(), proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: [id: proposal])
        guardState.revoke()
        for latest in [proposal, hello(paired: true, token: token)] {
            XCTAssertThrowsError(try guardState.validate(attempt, hellos: [id: latest]))
        }
    }

    func testChangedNonceEpochTokenSuspensionOrLinkCannotPublishPairing() throws {
        let guardState = ChromeExtensionAuthorityGuard(), id = UUID()
        let proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: [id: proposal])
        let changed: [ChromeExtensionHello] = [
            hello(event: "pairRequested", nonce: UUID().uuidString),
            hello(event: "pairRequested", epoch: UUID().uuidString, nonce: proposal.pairingNonce),
            hello(paired: true, token: "different-token"),
            hello(paired: true, suspended: true, token: token),
            hello(),
            hello(event: "pairRequested", installation: UUID().uuidString, nonce: proposal.pairingNonce)
        ]
        for value in changed { XCTAssertThrowsError(try guardState.validate(attempt, hellos: [id: value])) }
        XCTAssertThrowsError(try guardState.validate(attempt, hellos: [UUID(): proposal]))
        XCTAssertThrowsError(try guardState.validate(attempt, hellos: [:]))
    }

    func testDuplicateInstallationRejectsAutomaticAndExplicitAdmission() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let first = UUID(), second = UUID(), original = hello(paired: true, token: token)
        let clone = hello(epoch: UUID().uuidString, paired: true, token: token)
        let peers = [first: original, second: clone]
        XCTAssertEqual(guardState.quarantineConflicts(peers), Set([first, second]))
        XCTAssertThrowsError(try guardState.requireUnique(id: first, hello: original, hellos: peers))
        XCTAssertThrowsError(try guardState.requireUnique(id: second, hello: clone, hellos: peers))
        let proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        XCTAssertThrowsError(try guardState.beginPairing(id: first, hello: proposal, token: token,
                                                       hellos: [first: proposal, second: clone]))
    }

    func testClosingOneConflictingPeerDoesNotChooseSurvivorAutomatically() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let first = UUID(), second = UUID(), original = hello(paired: true, token: token)
        _ = guardState.quarantineConflicts([first: original, second: original])
        XCTAssertEqual(guardState.quarantineConflicts([first: original]), [first])
        XCTAssertThrowsError(try guardState.requireUnique(id: first, hello: original, hellos: [first: original]))
        guardState.revoke() // Forget does not silently clear an identity conflict.
        XCTAssertThrowsError(try guardState.requireUnique(id: first, hello: original, hellos: [first: original]))
    }

    func testDuplicateArrivingDuringPairingInvalidatesAlreadyCapturedAttempt() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let first = UUID(), second = UUID(), proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: first, hello: proposal, token: token, hellos: [first: proposal])
        _ = guardState.quarantineConflicts([first: proposal, second: hello(epoch: UUID().uuidString)])
        XCTAssertThrowsError(try guardState.validate(attempt, hellos: [first: hello(paired: true, token: token)]))
    }

    func testDifferentInstallationDoesNotConflictOrChangePairingGeneration() throws {
        var guardState = ChromeExtensionAuthorityGuard()
        let first = UUID(), second = UUID(), proposal = hello(event: "pairRequested", nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: first, hello: proposal, token: token, hellos: [first: proposal])
        let peers = [first: proposal, second: hello(installation: UUID().uuidString)]
        XCTAssertTrue(guardState.quarantineConflicts(peers).isEmpty)
        XCTAssertNoThrow(try guardState.validate(attempt, hellos: peers))
    }

    func testSuspendedUnpairedProposalStillRequiresFreshExplicitApproval() throws {
        let guardState = ChromeExtensionAuthorityGuard(), id = UUID()
        // After Forget the extension is intentionally suspended. The user can
        // start fresh pairing, but only its matching success may authorize it.
        let proposal = hello(event: "pairRequested", suspended: true, nonce: UUID().uuidString)
        let attempt = try guardState.beginPairing(id: id, hello: proposal, token: token, hellos: [id: proposal])
        XCTAssertNoThrow(try guardState.validate(attempt, hellos: [id: hello(paired: true, token: token)]))
    }

    private let token = String(repeating: "t", count: 44)
    private let installation = "77777777-7777-4777-8777-777777777777"
    private let epoch = "88888888-8888-4888-8888-888888888888"

    private func hello(event: String = "hello", installation: String? = nil, epoch: String? = nil,
                       paired: Bool = false, suspended: Bool = false,
                       token: String? = nil, nonce: String? = nil) -> ChromeExtensionHello {
        ChromeExtensionHello(version: 1, event: event, installationId: installation ?? self.installation,
            extensionId: ChromeBridgeIdentity.extensionID, bridgeEpoch: epoch ?? self.epoch,
            paired: paired, suspended: suspended, pairingToken: token, pairingNonce: nonce)
    }
}
