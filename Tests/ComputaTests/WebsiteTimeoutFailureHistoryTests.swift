import Foundation
import XCTest
@testable import Computa

final class WebsiteTimeoutFailureHistoryTests: XCTestCase {
    private var failures: [any Error] {
        [WebModelServer.Failure.deadline, WebModelServer.Failure.preparationDeadline,
         EmbeddedWebModelTransport.Failure.deadline, EmbeddedWebModelTransport.Failure.preparationDeadline]
    }

    private var model: String {
        WebsiteModelChoice(provider: "groq", key: "qwen/qwen3.8-27b", label: "Qwen/Qwen3.8-27B").modelID
    }

    func testAllFourNativeTimeoutVariantsPersistAndReloadWithoutRetryMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaTimeoutHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID().uuidString, thread = UUID().uuidString
        var records: [WebsiteTurnFailureStore.Record] = []
        for failure in failures {
            let presentation = WebModelServer.errorPresentation(for: failure)
            XCTAssertEqual(presentation.status, "504 Gateway Timeout")
            let envelope = try envelope(for: failure)
            let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
            XCTAssertEqual(Set(envelope.keys), ["error"])
            XCTAssertEqual(Set(fields.keys), ["type", "message", "code", "param"])
            XCTAssertEqual(fields["code"] as? String, "provider_timeout")
            XCTAssertEqual(fields["type"] as? String, "server_error")
            XCTAssertEqual(fields["message"] as? String, failure.localizedDescription)
            XCTAssertTrue(fields["param"] is NSNull)
            XCTAssertNil(fields["retryable"])
            XCTAssertNil(fields["required_action"])
            XCTAssertNil(fields["reason"])
            let turn = UUID().uuidString
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turn, modelID: model, diagnosticText: try text(envelope)))
            records.append(record)
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record))
            XCTAssertTrue(WebsiteTurnFailureStore(directory: root).append(record), "The same saved turn remains idempotent")
            let restored = try WebsiteTurnFailureStore(directory: root).load(threadID: thread)
            XCTAssertEqual(restored, records)
            let saved = try XCTUnwrap(restored.last)
            XCTAssertEqual(saved.taskID, task.lowercased())
            XCTAssertEqual(saved.threadID, thread.lowercased())
            XCTAssertEqual(saved.turnID, turn.lowercased())
            XCTAssertEqual(saved.modelID, model)
            XCTAssertEqual(saved.entry.id, "agent-error:" + turn.lowercased())
            XCTAssertEqual(saved.entry.title, "Agent error")
            let savedEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.entry.body.utf8)) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: savedEnvelope).isEqual(to: envelope))
        }
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.diagnosticText)).count, 3,
            "The server and transport response deadlines intentionally have the same native body")
    }

    func testTimeoutHistoryRejectsAlteredMessagesMetadataAndEnvelopeFields() throws {
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        for failure in failures {
            let original = try envelope(for: failure)
            for changed in try mutations(of: original) {
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: turn, modelID: model, diagnosticText: try text(changed)))
            }
            for foreignModel in ["browser/unknown-provider", "api/groq/model/fixture", "not-a-model"] {
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: turn, modelID: foreignModel, diagnosticText: try text(original)))
            }
            for identities in [("not-a-uuid", thread, turn), (task, "not-a-uuid", turn), (task, thread, "not-a-uuid")] {
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: identities.0, threadID: identities.1,
                    turnID: identities.2, modelID: model, diagnosticText: try text(original)))
            }
        }
        for prose in ["provider_timeout", "The website timed out: PRIVATE_PAGE_CANARY", "{}", "{\"error\":\"provider_timeout\"}"] {
            XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turn, modelID: model, diagnosticText: prose))
        }
    }

    func testReloadRejectsChangedTimeoutDiagnosticsAndDoesNotOverwriteCorruptEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputaTimeoutReload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in failures {
            let envelope = try envelope(for: failure)
            let record = try XCTUnwrap(WebsiteTurnFailureStore.Record.make(taskID: UUID().uuidString,
                threadID: UUID().uuidString, turnID: UUID().uuidString, modelID: model, diagnosticText: try text(envelope)))
            let store = WebsiteTurnFailureStore(directory: root)
            XCTAssertTrue(store.append(record))
            let file = root.appendingPathComponent(record.threadID + ".json")
            let originalBytes = try Data(contentsOf: file)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
            for changed in try mutations(of: envelope) {
                var saved = original
                var savedRecords = try XCTUnwrap(saved["records"] as? [[String: Any]])
                savedRecords[0]["diagnosticText"] = try text(changed)
                saved["records"] = savedRecords
                let corrupt = try JSONSerialization.data(withJSONObject: saved)
                try corrupt.write(to: file)
                XCTAssertThrowsError(try WebsiteTurnFailureStore(directory: root).load(threadID: record.threadID))
                XCTAssertFalse(store.append(record))
                XCTAssertEqual(try Data(contentsOf: file), corrupt, "Rejected saved evidence must be retained unchanged")
            }
            try originalBytes.write(to: file)
            XCTAssertEqual(try WebsiteTurnFailureStore(directory: root).load(threadID: record.threadID), [record])
        }
    }

    func testTimeoutAdmissionKeepsOtherCodesRetryMetadataAndFixedBodyChecks() throws {
        let task = UUID().uuidString, thread = UUID().uuidString, turn = UUID().uuidString
        let finite: [any Error] = [EmbeddedWebModelTransport.Failure.signInRequired,
                                  EmbeddedWebModelTransport.Failure.usageLimited(.groq)]
        for failure in finite {
            let original = try envelope(for: failure)
            let fields = try XCTUnwrap(original["error"] as? [String: Any])
            XCTAssertEqual(fields["retryable"] as? Bool, false)
            XCTAssertNotNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                turnID: turn, modelID: model, diagnosticText: try text(original)))
            for retryable in [nil, true, 0] as [Any?] {
                var changed = original, changedFields = fields
                changedFields["retryable"] = retryable
                changed["error"] = changedFields
                XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
                    turnID: turn, modelID: model, diagnosticText: try text(changed)))
            }
        }
        let legacy = try envelope(for: EmbeddedWebModelTransport.Failure.pageUnavailable)
        XCTAssertNotNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
            turnID: turn, modelID: model, diagnosticText: try text(legacy)))
        var alteredLegacy = legacy, fields = try XCTUnwrap(legacy["error"] as? [String: Any])
        fields["message"] = "PRIVATE_PAGE_CANARY"
        alteredLegacy["error"] = fields
        XCTAssertNil(WebsiteTurnFailureStore.Record.make(taskID: task, threadID: thread,
            turnID: turn, modelID: model, diagnosticText: try text(alteredLegacy)))
    }

    private func envelope(for failure: any Error) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: WebModelServer.errorBody(for: failure)) as? [String: Any])
    }

    private func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func mutations(of envelope: [String: Any]) throws -> [[String: Any]] {
        let fields = try XCTUnwrap(envelope["error"] as? [String: Any])
        var results: [[String: Any]] = []
        let changes: [[String: Any]] = [["message": "PRIVATE_PAGE_CANARY"], ["message": NSNull()],
            ["type": "model_error"], ["code": "browser_model_error"], ["param": "input"],
            ["retryable": false], ["retryable": true], ["retryable": 0], ["reason": "deadline"],
            ["required_action": "retry_send"], ["required_action": "inspect_website"], ["raw_text": "PRIVATE_PAGE_CANARY"]]
        for change in changes {
            var changed = envelope, changedFields = fields
            change.forEach { changedFields[$0.key] = $0.value }
            changed["error"] = changedFields
            results.append(changed)
        }
        for key in fields.keys {
            var changed = envelope, changedFields = fields
            changedFields.removeValue(forKey: key)
            changed["error"] = changedFields
            results.append(changed)
        }
        var extra = envelope
        extra["raw_text"] = "PRIVATE_PAGE_CANARY"
        results.append(extra)
        return results
    }
}
