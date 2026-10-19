import Foundation
import XCTest
@testable import Computa

@MainActor
final class ChatGPTObservationDiagnosticTests: XCTestCase {
    private let binding = WebsiteBenchmarkCaptureLease.ObservationBinding(
        nonce: UUID(uuidString: "5b0673ea-554c-4ec8-aee9-1f301f9a78c5")!,
        rawOutboundSHA: String(repeating: "a", count: 64),
        canonicalOutboundSHA: String(repeating: "b", count: 64), utf8Bytes: 7)

    private func value(text: Bool = false, terminal: Bool = false) -> [String: Any] {
        ["schemaVersion": 1, "revision": 1,
         "binding": ["schemaVersion": 1, "nonce": binding.nonce.uuidString.lowercased(),
                     "expectedSHA256": binding.rawOutboundSHA, "expectedCanonicalSHA256": binding.canonicalOutboundSHA,
                     "expectedUTF8Bytes": binding.utf8Bytes],
         "diagnosticOnly": true, "modelProofRequiredExternally": true,
         "installedUnixMs": 1_792_441_000_000, "sendUnixMs": 1_792_441_000_100, "ownClickAfterInstallMs": 100,
         "invalidReason": "none", "endedReason": terminal ? "explicit_stop" : "none", "stopped": terminal, "expired": false,
         "sourceProbeSendObserved": true, "payloadBindingVerified": false, "sourceProbeCurrentComplete": false,
         "clickIsTrusted": false, "userCount": 1, "assistantCount": 1,
         "firstModernBodyAfterSendMs": 120,
         "firstRawTextAfterSendMs": text ? 160 : NSNull(), "firstRawTextUTF16Length": text ? 3 : NSNull(),
         "firstRawTextCountClamped": false, "callbacks": 10, "mutationCallbacks": 2, "mutationRecords": 3,
         "timerIntervals": [[1, 1], [5, 4]], "rafEarlyIntervals": [[16.5, 16.5]], "rafBodyIntervals": [],
         "visibilityFocus": [["install", 0, "visible", true], ["send", 100, "visible", false]],
         "resourceSummary": NSNull()]
    }

    private func remove(_ raw: Any, binding: WebsiteBenchmarkCaptureLease.ObservationBinding? = nil) -> ChatGPTObservationDiagnostic.Snapshot? {
        var observation: [String: Any] = ["state": "running", "busy": true, "answerComplete": false,
            ChatGPTObservationDiagnostic.resultKey: raw]
        let result = ChatGPTObservationDiagnostic.remove(from: &observation, binding: binding ?? self.binding)
        XCTAssertNil(observation[ChatGPTObservationDiagnostic.resultKey])
        XCTAssertEqual(observation["state"] as? String, "running")
        XCTAssertEqual(observation["busy"] as? Bool, true)
        XCTAssertEqual(observation["answerComplete"] as? Bool, false)
        XCTAssertNil(observation["completionEvidence"])
        return result
    }

    func testUnknownMissingForeignOrOversizedDiagnosticsAreStrippedWithoutAuthority() throws {
        var noLease: [String: Any] = ["busy": true, ChatGPTObservationDiagnostic.resultKey: value()]
        XCTAssertNil(ChatGPTObservationDiagnostic.remove(from: &noLease, binding: nil))
        XCTAssertEqual(Set(noLease.keys), ["busy"])
        XCTAssertNil(remove(NSNull()))
        for name in ["state", "modelEvidence", "ownerToken", "url", "responseText", "nativeClock"] {
            var unknown = value(); unknown[name] = "PRIVATE_CANARY"
            XCTAssertNil(remove(unknown), name)
        }
        var foreign = value()
        var foreignBinding = try XCTUnwrap(foreign["binding"] as? [String: Any])
        for key in ["nonce", "expectedSHA256", "expectedCanonicalSHA256", "expectedUTF8Bytes"] {
            var changed = foreignBinding
            changed[key] = key == "expectedUTF8Bytes" ? 8 : "PRIVATE_CANARY"
            foreign["binding"] = changed
            XCTAssertNil(remove(foreign), key)
        }
        foreignBinding["unknown"] = "PRIVATE_CANARY"; foreign["binding"] = foreignBinding
        XCTAssertNil(remove(foreign))
        var oversized = value(); oversized["timerIntervals"] = Array(repeating: [1, 1], count: 13)
        XCTAssertNil(remove(oversized))
        oversized = value(); oversized["invalidReason"] = String(repeating: "PRIVATE", count: 1_000)
        XCTAssertNil(remove(oversized))
    }

    func testFiniteDiagnosticRetainsUnknownAndRejectsNonfiniteTypeAndCounterConfusion() throws {
        let early = try XCTUnwrap(remove(value()))
        XCTAssertEqual(early.phase, .early)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: early.data) as? [String: Any])
        XCTAssertEqual(decoded["payloadBindingVerified"] as? Bool, false, "Unknown payload proof must never be promoted")
        XCTAssertTrue(decoded["firstRawTextAfterSendMs"] is NSNull)
        XCTAssertTrue(decoded["resourceSummary"] is NSNull)
        let badValues: [(String, Any)] = [("schemaVersion", true), ("revision", 2), ("diagnosticOnly", 1),
            ("payloadBindingVerified", 1), ("callbacks", 257), ("mutationCallbacks", 129), ("mutationRecords", 1_026),
            ("userCount", 2), ("assistantCount", false), ("firstModernBodyAfterSendMs", Double.nan),
            ("firstModernBodyAfterSendMs", Double.infinity), ("ownClickAfterInstallMs", 15_001),
            ("installedUnixMs", -1), ("stopped", true), ("visibilityFocus", [["PRIVATE", 0, "visible", true]])]
        for (key, badValue) in badValues {
            var bad = value(); bad[key] = badValue
            XCTAssertNil(remove(bad), key)
        }
    }

    func testBoundedResourceAndFocusTuplesCannotExportIdentifiersOrUnboundedSamples() throws {
        var valid = value(text: true, terminal: true)
        valid["resourceSummary"] = ["scannedCount": 2, "scanTruncated": false, "selectedCount": 2,
            "selectedTruncated": false, "available": true,
            "entries": [[-20, 5, 25, 100, 150, 200], [NSNull(), 10, NSNull(), NSNull(), NSNull(), NSNull()]]]
        XCTAssertNotNil(remove(valid))
        var bad = valid
        var resource = try XCTUnwrap(valid["resourceSummary"] as? [String: Any])
        resource["url"] = "PRIVATE_URL"; bad["resourceSummary"] = resource
        XCTAssertNil(remove(bad))
        resource.removeValue(forKey: "url")
        resource["entries"] = Array(repeating: [1, 2, 1, 1, 1, 1], count: 9); bad["resourceSummary"] = resource
        XCTAssertNil(remove(bad))
        resource["entries"] = [[1, 2, 1, true, 1, 1], [1, 2, 1, 1, 1, 1]]; bad["resourceSummary"] = resource
        XCTAssertNil(remove(bad))
        for invalidEntry in [[-20, -1, 25, 100, 150, 200], [-20, 5, -1, 100, 150, 200]] {
            resource["entries"] = [invalidEntry, [1, 2, 1, 1, 1, 1]]; bad["resourceSummary"] = resource
            XCTAssertNil(remove(bad), "Only a resource start offset may precede Send; end and duration cannot be negative")
        }
        bad = valid; bad["rafBodyIntervals"] = [[1, 1, "PRIVATE_TEXT"]]
        XCTAssertNil(remove(bad))
        bad = valid; bad["visibilityFocus"] = [["install", 0, "PRIVATE_VISIBILITY", true]]
        XCTAssertNil(remove(bad))
    }

    func testThreeCheckpointBudgetPreservesTerminalAndBoundsEveryChunk() throws {
        var budget = ChatGPTObservationDiagnostic.LogBudget()
        let token = UUID().uuidString
        let early = try XCTUnwrap(remove(value()))
        let first = try XCTUnwrap(remove(value(text: true)))
        let terminal = try XCTUnwrap(remove(value(text: true, terminal: true)))
        var logs: [ChatGPTObservationDiagnostic.Log] = []
        logs.append(try XCTUnwrap(budget.consume(early, binding: binding, sessionToken: token, sequence: 1)))
        for _ in 0..<20 { XCTAssertNil(budget.consume(early, binding: binding, sessionToken: token, sequence: 1)) }
        logs.append(try XCTUnwrap(budget.consume(first, binding: binding, sessionToken: token, sequence: 1)))
        XCTAssertNil(budget.consume(first, binding: binding, sessionToken: token, sequence: 1))
        logs.append(try XCTUnwrap(budget.consume(terminal, binding: binding, sessionToken: token, sequence: 1)))
        XCTAssertNil(budget.consume(terminal, binding: binding, sessionToken: token, sequence: 1))
        for (index, log) in logs.enumerated() {
            XCTAssertTrue((1...8).contains(log.records.count))
            XCTAssertTrue(log.records.allSatisfy { $0.utf8.count <= 960 && $0.contains("snapshot=\(index + 1) ") })
            let chunks = try log.records.map { record in
                let delimiter = try XCTUnwrap(record.range(of: " base64="))
                return try XCTUnwrap(Data(base64Encoded: String(record[delimiter.upperBound...])))
            }
            XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, [early, first, terminal][index].data)
        }
        var fresh = ChatGPTObservationDiagnostic.LogBudget()
        XCTAssertNil(fresh.consume(early, binding: binding, sessionToken: token, sequence: 2))
        XCTAssertNil(fresh.consume(early, binding: binding, sessionToken: "PRIVATE_TOKEN", sequence: 1))
        XCTAssertNil(fresh.consume(.init(data: Data(repeating: 65, count: 4_097), phase: .terminal),
                                  binding: binding, sessionToken: token, sequence: 1))
        XCTAssertNotNil(fresh.consume(terminal, binding: binding, sessionToken: token, sequence: 1))
    }
}
