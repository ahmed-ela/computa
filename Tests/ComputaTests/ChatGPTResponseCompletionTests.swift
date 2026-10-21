import Foundation
import XCTest
@testable import Computa

@MainActor
final class ChatGPTResponseCompletionTests: XCTestCase {
    func testNativeBindingBoundsAndCurrentLookupCannotCrossViewsOwnersGenerationsOrRounds() throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.isCurrent(view: fixture.viewID, ownerToken: fixture.owner,
                                             generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.receipt())
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let receipt = try XCTUnwrap(fixture.receipt())
        XCTAssertNil(fixture.lease.receipt(view: ObjectIdentifier(NSObject()), ownerToken: fixture.owner,
                                           generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: UUID().uuidString,
                                           generation: fixture.generation, sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: fixture.owner,
                                           generation: UUID(), sequence: fixture.sequence))
        XCTAssertNil(fixture.lease.receipt(view: fixture.viewID, ownerToken: fixture.owner,
                                           generation: fixture.generation, sequence: fixture.sequence + 1))
        XCTAssertEqual(fixture.receipt(), receipt, "A foreign lookup cannot consume or alter the current receipt")
        let cases: [(owner: String, sequence: Int, sha: String, bytes: Int)] = [
            ("not-a-native-owner", 1, fixture.sha, 10),
            (fixture.owner, 0, fixture.sha, 10), (fixture.owner, 17, fixture.sha, 10),
            (fixture.owner, 1, String(repeating: "A", count: 64), 10),
            (fixture.owner, 1, String(repeating: "a", count: 63), 10),
            (fixture.owner, 1, fixture.sha, 0), (fixture.owner, 1, fixture.sha, 180_001),
        ]
        for item in cases {
            XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: item.owner,
                generation: fixture.generation, sequence: item.sequence, inputSHA256: item.sha,
                inputUTF8Bytes: item.bytes, deadline: .now + .seconds(10)))
        }
    }

    func testOneValidTerminalHasExactNativeDigestAndDuplicateDoesNotRenewItsIdentity() throws {
        let fixture = try LeaseFixture()
        let packet = fixture.packet(text: "Exact café 🌍\nsecond line")
        XCTAssertTrue(fixture.lease.receive(packet))
        let first = try XCTUnwrap(fixture.receipt())
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.correlationID, fixture.correlation)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.inputSHA256, fixture.sha)
        XCTAssertEqual(first.inputMessageID, fixture.inputMessage.uuidString.lowercased())
        XCTAssertEqual(first.conversationID, fixture.conversation.uuidString.lowercased())
        XCTAssertEqual(first.assistantMessageID, fixture.answer.uuidString.lowercased())
        XCTAssertEqual(first.text, "Exact café 🌍\nsecond line")
        XCTAssertEqual(first.textSHA256, EmbeddedWebModelTransport.promptFingerprint(first.text))
        XCTAssertFalse(fixture.lease.receive(packet), "An identical duplicate is not another native wake or new terminal")
        XCTAssertEqual(fixture.receipt(), first)
        XCTAssertEqual(fixture.lease.revision, 1)
        XCTAssertFalse(fixture.lease.invalidated)
    }

    func testForeignCorrelationSequenceAndInputHashCannotPoisonOrReplaceCurrentTerminal() throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        let original = try XCTUnwrap(fixture.receipt())
        let identities: [(String, Any)] = [
            ("correlationID", UUID().uuidString.lowercased()),
            ("correlationID", fixture.correlation.uuidString.uppercased()),
            ("sequence", 2), ("sequence", true),
            ("inputSHA256", String(repeating: "b", count: 64)),
        ]
        for (key, value) in identities {
            var packet = fixture.packet(text: "Foreign content must never replace the owned receipt")
            packet[key] = value
            packet["kind"] = "invalidated"
            XCTAssertFalse(fixture.lease.receive(packet), key)
            XCTAssertFalse(fixture.lease.invalidated, key)
            XCTAssertEqual(fixture.receipt(), original, key)
        }
    }

    func testMalformedMatchingPacketsInvalidatePermanentlyInsteadOfFallingThroughToLaterTerminal() throws {
        let mutations: [(String, (inout [String: Any], LeaseFixture) -> Void)] = [
            ("boolean_version", { packet, _ in packet["version"] = true }),
            ("unknown_version", { packet, _ in packet["version"] = 2 }),
            ("fractional_version", { packet, _ in packet["version"] = 1.5 }),
            ("unknown_kind", { packet, _ in packet["kind"] = "finished_successfully" }),
            ("unknown_key", { packet, _ in packet["unexpected"] = "not retained" }),
            ("missing_message", { packet, _ in packet.removeValue(forKey: "messageID") }),
            ("uppercase_message", { $0["messageID"] = $1.answer.uuidString.uppercased() }),
            ("invalid_conversation", { packet, _ in packet["conversationID"] = "not-a-conversation" }),
            ("same_input_answer", { $0["messageID"] = $1.inputMessage.uuidString.lowercased() }),
            ("nontext", { packet, _ in packet["text"] = ["HI"] }),
            ("empty_text", { packet, _ in packet["text"] = "" }),
            ("extra_on_invalidation", { packet, _ in packet["kind"] = "invalidated" }),
        ]
        for (name, mutation) in mutations {
            let fixture = try LeaseFixture()
            var packet = fixture.packet()
            mutation(&packet, fixture)
            XCTAssertTrue(fixture.lease.receive(packet), name)
            XCTAssertTrue(fixture.lease.invalidated, name)
            XCTAssertNil(fixture.receipt(), name)
            XCTAssertFalse(fixture.lease.receive(fixture.packet()), name)
            XCTAssertNil(fixture.receipt(), "A later valid terminal cannot resurrect \(name)")
        }
    }

    func testConflictingTerminalIdentityOrExactUTF8RevokesAnAlreadyPublishedCandidate() throws {
        let conflicts: [(String, (inout [String: Any], LeaseFixture) -> Void)] = [
            ("message", { packet, _ in packet["messageID"] = UUID().uuidString.lowercased() }),
            ("input_message", { packet, _ in packet["inputMessageID"] = UUID().uuidString.lowercased() }),
            ("conversation", { packet, _ in packet["conversationID"] = UUID().uuidString.lowercased() }),
            ("text", { packet, _ in packet["text"] = "Changed final content" }),
            ("canonical_equivalent_utf8", { packet, _ in packet["text"] = "e\u{301}" }),
        ]
        for (name, mutation) in conflicts {
            let fixture = try LeaseFixture()
            var packet = fixture.packet(text: "é")
            XCTAssertTrue(fixture.lease.receive(packet))
            let first = try XCTUnwrap(fixture.receipt())
            mutation(&packet, fixture)
            XCTAssertTrue(fixture.lease.receive(packet), name)
            XCTAssertTrue(fixture.lease.invalidated, name)
            XCTAssertGreaterThan(fixture.lease.revision, first.revision, name)
            XCTAssertNil(fixture.receipt(), name)
        }
        XCTAssertEqual("é", "e\u{301}", "The UTF8 conflict must remain stricter than Swift canonical String equality")
    }

    func testExplicitInvalidationAndRevocationAreFinalAndClearTheCandidate() throws {
        for revokeDirectly in [false, true] {
            let fixture = try LeaseFixture()
            XCTAssertTrue(fixture.lease.receive(fixture.packet()))
            let original = try XCTUnwrap(fixture.receipt())
            if revokeDirectly { fixture.lease.revoke() }
            else {
                var invalidated = fixture.identity()
                invalidated["kind"] = "invalidated"
                XCTAssertTrue(fixture.lease.receive(invalidated))
            }
            XCTAssertTrue(fixture.lease.invalidated)
            XCTAssertNil(fixture.receipt())
            XCTAssertFalse(fixture.lease.receive(fixture.packet()))
            let finalRevision = fixture.lease.revision
            XCTAssertGreaterThan(finalRevision, original.revision)
            fixture.lease.revoke()
            XCTAssertEqual(fixture.lease.revision, finalRevision, "Repeated revocation cannot renew state or a deadline")
        }
    }

    func testDeadlineAndCancellationDoNotYieldOrAcceptAReceipt() async throws {
        let fixture = try LeaseFixture()
        XCTAssertTrue(fixture.lease.receive(fixture.packet()))
        XCTAssertNil(fixture.receipt(now: fixture.deadline))
        XCTAssertFalse(fixture.lease.receive(fixture.packet(), now: fixture.deadline))
        XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: fixture.owner,
            generation: fixture.generation, sequence: 1, inputSHA256: fixture.sha,
            inputUTF8Bytes: 10, deadline: .now - .milliseconds(1)))
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertNil(fixture.receipt())
            XCTAssertFalse(fixture.lease.receive(fixture.packet()))
            XCTAssertNil(ChatGPTResponseCompletion(view: fixture.viewID, ownerToken: fixture.owner,
                generation: fixture.generation, sequence: 1, inputSHA256: fixture.sha,
                inputUTF8Bytes: 10, deadline: .now + .seconds(10)))
        }
        await cancelled.value
    }

    func testTextBudgetCountsUTF8AndOverBudgetCannotLeaveAStaleCandidate() throws {
        let maximum = ChatGPTResponseCompletion.maximumTextUTF8Bytes
        let valid = try LeaseFixture()
        XCTAssertTrue(valid.lease.receive(valid.packet(text: String(repeating: "x", count: maximum))))
        XCTAssertEqual(try XCTUnwrap(valid.receipt()).text.utf8.count, maximum)
        for text in [String(repeating: "x", count: maximum + 1),
                     String(repeating: "é", count: maximum / 2 + 1)] {
            let fixture = try LeaseFixture()
            XCTAssertTrue(fixture.lease.receive(fixture.packet(text: "Prior terminal")))
            XCTAssertTrue(fixture.lease.receive(fixture.packet(text: text)))
            XCTAssertTrue(fixture.lease.invalidated)
            XCTAssertNil(fixture.receipt())
        }
    }

    @MainActor
    private struct LeaseFixture {
        let view = NSObject()
        let owner = UUID().uuidString
        let generation = UUID()
        let correlation = UUID()
        let inputMessage = UUID()
        let conversation = UUID()
        let answer = UUID()
        let sequence = 1
        let sha = EmbeddedWebModelTransport.promptFingerprint("Exact owned outbound payload")
        let deadline = ContinuousClock.now + .seconds(10)
        let lease: ChatGPTResponseCompletion
        var viewID: ObjectIdentifier { ObjectIdentifier(view) }

        init() throws {
            lease = try XCTUnwrap(ChatGPTResponseCompletion(view: ObjectIdentifier(view), ownerToken: owner,
                generation: generation, sequence: sequence, inputSHA256: sha,
                inputUTF8Bytes: "Exact owned outbound payload".utf8.count, deadline: deadline,
                correlationID: correlation))
        }
        func identity() -> [String: Any] {
            ["version": 1, "kind": "terminal", "correlationID": correlation.uuidString.lowercased(),
             "sequence": sequence, "inputSHA256": sha]
        }
        func packet(text: String = "HI") -> [String: Any] {
            identity().merging(["inputMessageID": inputMessage.uuidString.lowercased(),
                "conversationID": conversation.uuidString.lowercased(),
                "messageID": answer.uuidString.lowercased(), "text": text]) { _, right in right }
        }
        func receipt(now: ContinuousClock.Instant = .now) -> ChatGPTResponseCompletion.Receipt? {
            lease.receipt(view: viewID, ownerToken: owner, generation: generation, sequence: sequence, now: now)
        }
    }
}
