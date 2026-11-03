import Foundation
import XCTest
@testable import Computa

@MainActor
final class QwenFirstUserDiagnosticTests: XCTestCase {
    func testUserCountFieldsDistinguishBothGuardsAndRejectUntrustedOrInconsistentCounts() {
        func fields(_ site: String, _ users: Any, _ answers: Any, _ expected: [Int],
                    _ confirmed: Int, _ pending: Bool, _ extra: [String: Any] = [:]) -> String? {
            var packet: [String: Any] = ["site": site, "users": users, "answers": answers, "adapterFirstBound": !pending]
            for (key, value) in extra { packet[key] = value }
            return EmbeddedWebModelTransport.qwenCountFailureFields(packet, expected: expected, confirmed: confirmed, pending: pending)
        }
        XCTAssertEqual(fields("expected", 0, 0, [1], 1, false),
            "countSite=expected users=0 answers=0 expectedUsers=1 nativeConfirmed=1 nativePending=false adapterFirstBound=true")
        XCTAssertEqual(fields("transcript", 2, 1, [0, 1], 0, true),
            "countSite=transcript users=2 answers=1 expectedUsers=0,1 nativeConfirmed=0 nativePending=true adapterFirstBound=false")
        XCTAssertNil(fields("expected", 1, 1, [1], 1, false))
        XCTAssertNil(fields("expected", 2, 1, [1], 1, false))
        XCTAssertNil(fields("transcript", 1, 1, [1], 1, false))
        XCTAssertNil(fields("transcript", 3, 1, [1], 1, false))
        XCTAssertNil(fields("transcript", true, 2, [1], 1, false))
        XCTAssertNil(fields("unknown", 0, 0, [1], 1, false))
        XCTAssertNil(fields("transcript", 2, 0, [0, 1], 1, false))
        XCTAssertNil(fields("transcript", 2, 0, [0, 1], 0, true, ["raw": "SYNTHETIC_PRIVATE"]))
    }

    private let predicates = [("root_hidden", "rootVisible"), ("message_id_invalid", "messageIDValid"),
        ("chat_id_mismatch", "chatIDMatches"), ("turn_class_missing", "turnClassMatches"), ("outer_class_missing", "outerClassMatches")]

    private func observation(_ index: Int = 0) -> [String: Any] {
        var packet: [String: Any] = ["version": 1, "reason": predicates[index].0,
            "rootVisible": true, "messageIDValid": true, "chatIDMatches": true,
            "turnClassMatches": true, "outerClassMatches": true, "messageIDPresent": true,
            "messageIDEmpty": false, "chatIDPresent": true, "chatIDEmpty": false]
        packet[predicates[index].1] = false
        return ["error": "conversation_changed", "detail": "first_user_message", "qwenFirstUserDiagnostic": packet]
    }

    func testEveryFinitePredicatePreservesOriginalOwnershipFailureAndOmitsPrivateValues() throws {
        for index in predicates.indices {
            var observed = observation(index)
            observed["text"] = "PRIVATE_BODY"; observed["url"] = "https://private.invalid/PRIVATE_ID"
            let safe = try XCTUnwrap(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen))
            let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
            XCTAssertEqual(packet["reason"] as? String, predicates[index].0)
            XCTAssertFalse(safe.contains("PRIVATE")); XCTAssertLessThanOrEqual(safe.utf8.count, 512)
            XCTAssertEqual(EmbeddedWebModelTransport.savedAdapterFailureDiagnostic(observed, provider: .qwen, action: "inspect"),
                "action=inspect error=conversation_changed detail=first_user_message")
            for provider in EmbeddedWebModelTransport.Provider.allCases where provider != .qwen {
                XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: provider))
            }
        }
    }

    func testMalformedUnknownMissingAndAdditionalFieldsAreRejected() throws {
        let original = observation(), packet = try XCTUnwrap(original["qwenFirstUserDiagnostic"] as? [String: Any])
        let changes: [(String, Any)] = [("version", true), ("version", 2), ("reason", "PRIVATE_REASON"),
            ("reason", "message_id_invalid"), ("rootVisible", true), ("rootVisible", 0), ("messageIDValid", "true"),
            ("chatIDMatches", NSNull()), ("turnClassMatches", 1), ("outerClassMatches", []),
            ("messageIDPresent", 1), ("messageIDEmpty", "false"), ("chatIDPresent", NSNull()), ("chatIDEmpty", 0),
            ("id", "PRIVATE_ID"), ("url", "https://private.invalid"), ("text", "PRIVATE_BODY")]
        for (key, value) in changes {
            var changed = packet; changed[key] = value; var observed = original; observed["qwenFirstUserDiagnostic"] = changed
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen), key)
        }
        for key in packet.keys {
            var changed = packet; changed.removeValue(forKey: key); var observed = original; observed["qwenFirstUserDiagnostic"] = changed
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen), key)
        }
        for (key, value) in [("error", "document_changed" as Any), ("error", NSNull() as Any),
            ("detail", "response_scope" as Any), ("detail", "PRIVATE_DETAIL" as Any)] {
            var observed = original; observed[key] = value
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen))
        }
    }

    func testPriorityAndIDPredicateConsistencyCannotBeRewrittenByMetadata() throws {
        for index in predicates.indices {
            var observed = observation(index), packet = try XCTUnwrap(observed["qwenFirstUserDiagnostic"] as? [String: Any])
            if index == 0 { packet["rootVisible"] = true } else { packet["rootVisible"] = false }
            observed["qwenFirstUserDiagnostic"] = packet
            XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen))
        }
        for prefix in ["messageID", "chatID"] {
            for contradiction in [[prefix + "Present": false], [prefix + "Empty": true], [prefix + "Present": false, prefix + "Empty": true]] {
                var observed = observation(), packet = try XCTUnwrap(observed["qwenFirstUserDiagnostic"] as? [String: Any])
                contradiction.forEach { packet[$0.key] = $0.value }; observed["qwenFirstUserDiagnostic"] = packet
                XCTAssertNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen))
            }
        }
        for (index, prefix) in [(1, "messageID"), (2, "chatID")] {
            for (present, empty) in [(false, false), (true, true), (true, false)] {
                var observed = observation(index), packet = try XCTUnwrap(observed["qwenFirstUserDiagnostic"] as? [String: Any])
                packet[prefix + "Present"] = present; packet[prefix + "Empty"] = empty; observed["qwenFirstUserDiagnostic"] = packet
                XCTAssertNotNil(EmbeddedWebModelTransport.qwenFirstUserDiagnostic(observed, provider: .qwen))
            }
        }
    }
}
